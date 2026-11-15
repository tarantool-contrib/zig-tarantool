"""Build and run the examples of the documentation, and check their results.

A page shows a file as a line "`path`:" followed by a fenced block. Each page
with such files becomes a project in zig-out/doc-examples/<page>/ that depends
on this repository; its build.zig is the page's own, or one that builds every
.zig file: a module, or a program if it has `pub fn main`.

Then, against the `tarantool` on PATH:

* the unlabeled ```lua blocks of the page run as one script, and each line
  `expression -- result` is checked: the expression must give the result;
* a labeled .lua file that calls box.cfg with `listen` is a server: it is
  started before the programs run;
* a ```console block runs its `$ tarantool <file>.lua` and
  `$ ./zig-out/bin/<program>` commands and compares their output with the
  lines that follow them.

usage: python3 ci/doc_examples.py [page ...]   (pages as in zig-out/doc-examples)
"""

import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DOC = ROOT / "doc"
OUT = ROOT / "zig-out" / "doc-examples"
LABEL = re.compile(r"^`([\w./-]+\.(?:zig|lua))`:\s*$")
# A page that extends the project of another one takes its files too.
EXTENDS = {"get-started-first-client": "get-started/first-module.md"}

LUA_PRELUDE = r"""
local json = require('json')
local ext = require('tarantool').build.mod_format
package.cpath = 'zig-out/lib/?.' .. ext .. ';' .. package.cpath
require('fio').mktree('data')
box.cfg{ memtx_dir = 'data', wal_dir = 'data', log_level = 1 }
local function show(line, ok, ...)
    local out = {}
    if not ok then
        out[1] = 'error: ' .. tostring((...))
    else
        for i = 1, select('#', ...) do
            local v = select(i, ...)
            if v == nil then
                out[i] = 'nil'
            elseif type(v) == 'table' or box.tuple.is(v) then
                out[i] = json.encode(v)
            else
                out[i] = tostring(v)
            end
        end
    end
    io.stdout:write('@@', line, '\t', table.concat(out, ', '), '\n')
end
"""


def blocks(text):
    """Yield (label, lang, lines) for each fenced block of a page."""
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        if lines[i].startswith("```"):
            lang = lines[i][3:].strip()
            label = None
            j = i - 1
            while j >= 0 and lines[j].strip() == "":
                j -= 1
            if j >= 0 and LABEL.match(lines[j]):
                label = LABEL.match(lines[j]).group(1)
            k = i + 1
            while not lines[k].startswith("```"):
                k += 1
            yield label, lang, lines[i + 1 : k]
            i = k
        i += 1


def page_name(md):
    return str(md.relative_to(DOC).with_suffix("")).replace("/", "-")


def run(cmd, cwd, timeout=600, stderr=subprocess.PIPE):
    return subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=stderr, text=True, timeout=timeout)


def write_project(page, files):
    d = OUT / page
    shutil.rmtree(d, ignore_errors=True)
    d.mkdir(parents=True)
    for path, lines in files.items():
        (d / path).parent.mkdir(parents=True, exist_ok=True)
        (d / path).write_text("\n".join(lines) + "\n")
    own_build = (d / "build.zig").exists()
    if own_build:
        (d / "build.zig").rename(d / "build.zig.page")
    run(["zig", "init", "--minimal"], d).check_returncode()
    if own_build:
        (d / "build.zig.page").rename(d / "build.zig")
    rel = os.path.relpath(ROOT, d)
    zon = (d / "build.zig.zon").read_text()
    zon = zon.replace(
        ".paths = ",
        '.dependencies = .{ .tarantool = .{ .path = "%s" } },\n    .paths = ' % rel,
        1,
    )
    (d / "build.zig.zon").write_text(zon)
    if not own_build:
        out = [
            'const std = @import("std");',
            'const tarantool = @import("tarantool");',
            "pub fn build(b: *std.Build) void {",
            "    const target = b.standardTargetOptions(.{});",
            "    const optimize = b.standardOptimizeOption(.{});",
        ]
        for f in sorted(d.rglob("*.zig")):
            if f.name == "build.zig":
                continue
            rp, name = f.relative_to(d).as_posix(), f.stem
            opts = '.{ .name = "%s", .root_source_file = b.path("%s"), .target = target, .optimize = optimize }' % (name, rp)
            if "pub fn main" in f.read_text():
                out.append("    b.installArtifact(tarantool.addExecutable(b, %s));" % opts)
            else:
                out.append("    tarantool.installModule(b, tarantool.addModule(b, %s));" % opts)
        out.append("}")
        (d / "build.zig").write_text("\n".join(out) + "\n")
    return d


def normalize(s):
    s = re.sub(r"\s+", "", s).replace('"', "").replace("'", "").replace("=", ":")
    s = s.replace("[", "{").replace("]", "}")
    m = re.fullmatch(r"\{([^{}]*)\}", s)
    if m and ":" in m.group(1):  # a flat map: the order of its keys is not part of it
        s = "{" + ",".join(sorted(m.group(1).split(","))) + "}"
    return s


def results_match(got, doc):
    parts_got = [normalize(p) for p in re.split(r",\s*(?![^{\[]*[}\]])", got)]
    parts_doc = [normalize(p) for p in re.split(r",\s*(?![^{\[]*[}\]])", doc)]
    if parts_got == parts_doc:
        return True
    # "-- 70: the debit was rolled back": the result, then a remark.
    head = doc.split(": ", 1)[0] if not doc.startswith("error:") else None
    return head is not None and normalize(got) == normalize(head)


def lua_script(text):
    body, checks = [], {}
    for label, lang, lines in blocks(text):
        if lang != "lua" or label:
            continue
        if any("'app'" in line for line in lines):  # needs a user the examples do not create
            continue
        for line in lines:
            m = re.match(r"^(\S.*?\S)\s+--\s+(.*)$", line)
            if m and not line.startswith(("local ", "for ", "box.schema", "require")):
                n = len(checks) + 1
                checks[n] = (m.group(1), m.group(2))
                body.append("show(%d, pcall(function() return %s end))" % (n, m.group(1)))
            else:
                body.append(line)
    if not checks:
        return None, {}
    return LUA_PRELUDE + "\n".join(body) + "\nos.exit(0)\n", checks


def wait_port(port, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        with socket.socket() as s:
            if s.connect_ex(("127.0.0.1", port)) == 0:
                return True
        time.sleep(0.2)
    return False


def console_checks(text):
    """Yield (command, expected lines) of the ```console blocks."""
    for _label, lang, lines in blocks(text):
        if lang != "console":
            continue
        cmd, expected = None, []
        for line in lines + ["$ "]:
            if line.startswith("$ "):
                if cmd:
                    yield cmd, expected
                cmd, expected = line[2:].strip(), []
            else:
                expected.append(line)


def check_page(page, md):
    text = md.read_text()
    files = {label: lines for label, _lang, lines in blocks(text) if label}
    if page in EXTENDS:
        base = DOC / EXTENDS[page]
        for label, _lang, lines in blocks(base.read_text()):
            if label and label.endswith(".zig") and label != "build.zig":
                files.setdefault(label, lines)
    if not any(f.endswith(".zig") for f in files):
        return []
    failures = []
    d = write_project(page, files)
    r = run(["zig", "build"], d)
    if r.returncode != 0:
        return ["build failed:\n" + r.stderr[-4000:]]

    script, checks = lua_script(text)
    if script:
        shutil.rmtree(d / "data", ignore_errors=True)
        (d / "doc_examples.lua").write_text(script)
        r = run(["tarantool", "doc_examples.lua"], d, timeout=120)
        got = {}
        for line in r.stdout.splitlines():
            if line.startswith("@@"):
                n, _, value = line[2:].partition("\t")
                got[int(n)] = value
        for n, (expr, doc) in checks.items():
            if n not in got:
                failures.append("%s: did not run\n%s" % (expr, r.stdout[-2000:] + r.stderr[-2000:]))
            elif not results_match(got[n], doc):
                failures.append("%s\n    documented: %s\n    got:        %s" % (expr, doc, got[n]))

    servers = []
    try:
        for path in files:
            src = (d / path).read_text() if path.endswith(".lua") else ""
            m = re.search(r"listen = '127\.0\.0\.1:(\d+)'", src)
            if m and "box.cfg" in src:
                shutil.rmtree(d / "data", ignore_errors=True)
                log = open(d / (path + ".log"), "w")
                servers.append(subprocess.Popen(["tarantool", path], cwd=d, stdout=log, stderr=log))
                if not wait_port(int(m.group(1))):
                    failures.append("server %s did not listen" % path)
                # The script goes on after box.cfg{listen}: let it create its
                # functions and grants before a program calls them.
                time.sleep(2)
        programs = sorted(p.name for p in (d / "zig-out" / "bin").glob("*")) if (d / "zig-out" / "bin").exists() else []
        for cmd, expected in console_checks(text):
            m = re.search(r"\./zig-out/bin/(\S+)$", cmd)
            if m:
                name = m.group(1) if m.group(1) in programs else (programs[0] if len(programs) == 1 else None)
                if not name:
                    failures.append("%s: no such program" % cmd)
                    continue
                # std.debug.print writes to stderr: compare both streams.
                r = run(["./zig-out/bin/" + name], d, timeout=60, stderr=subprocess.STDOUT)
            elif re.fullmatch(r"tarantool \S+\.lua", cmd) and cmd.split()[1] in files and not any(
                cmd.split()[1] in " ".join(s.args) for s in servers
            ):
                shutil.rmtree(d / "data", ignore_errors=True)
                r = run(cmd.split(), d, timeout=60)
            else:
                continue
            want = [line for line in expected if line.strip()]
            have = [line for line in r.stdout.splitlines() if line.strip()]
            if have != want:
                failures.append("$ %s\n    documented:\n%s\n    got:\n%s%s" % (
                    cmd, "\n".join("      " + x for x in want), "\n".join("      " + x for x in have),
                    ("\n    stderr:\n" + (r.stderr or "")[-2000:]) if r.returncode and r.stderr else ""))
    finally:
        for s in servers:
            s.terminate()
            s.wait()
    return failures


def main():
    pages = {page_name(md): md for md in sorted(DOC.rglob("*.md")) if not re.search(r"\.[a-z]{2}\.md$", md.name)}
    wanted = sys.argv[1:] or list(pages)
    failed = 0
    for page in wanted:
        failures = check_page(page, pages[page])
        if failures is None:
            continue
        for f in failures:
            print("FAIL %s: %s" % (page, f))
        failed += bool(failures)
        if not failures and (OUT / page).exists():
            print("ok   %s" % page)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
