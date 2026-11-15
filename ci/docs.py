#!/usr/bin/env python3
"""Build, preview and publish the documentation site.

The site has the guides, built by mkdocs from doc/ in each language of
mkdocs.yml, and an API reference generated from the source. Published, on the
gh-pages branch, each version of each has a directory of its own:

    /                       -> /en/
    /<lang>/                -> /<lang>/<default version>/   (mike)
    /<lang>/<version>/      the guides of a version, in one language
    /<lang>/versions.json   the versions, for the version selector (mike)
    /api/                   -> /api/<default version>/
    /api/<version>/         the API reference of a version
    /api/versions.json      the same list
    /404.html

A version is `master`, or a release: the tag `v1.2.0` publishes `1.2.0`. A
release is aliased `latest`, the default, when it is the highest one
published; a tag on an older line does not take `latest` back.

To fix the documentation of a release, branch `doc/v1.2.0` off the tag
`v1.2.0` and push the fix there: a branch `doc/<tag>` publishes the version
of the tag again, keeping its aliases. mike
(https://github.com/jimporter/mike) publishes the guides of each language,
with --deploy-prefix <lang>; this script adds the API reference and the root
files in the same layout, and pushes.

    ci/docs.py serve [--lang ru]          preview the guides, with live reload
    ci/docs.py build [--version V]        build every part of one version into
                                          site/, in the published layout,
                                          failing on a broken link
    ci/docs.py deploy <ref> [--push]      publish a version to gh-pages: <ref>
                                          is master, a tag v1.2.0 or a branch
                                          doc/v1.2.0

Needs the tools of doc/requirements.txt, and what the API reference needs.
Only the block below is specific to this project.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
DOC = ROOT / "doc"

# ---- project-specific: the API reference ------------------------------------


def build_api(out: Path) -> None:
    """Generate the API reference into `out`, a static site."""
    prefix = ROOT / "zig-out" / "docs-site"
    run(["zig", "build", "docs", "-p", str(prefix)])
    shutil.rmtree(out, ignore_errors=True)
    shutil.copytree(prefix / "docs" / "api", out)


# Where the guides link the reference: doc/<API_LINK>/index.html. Locally it is
# the reference itself; a published build has a redirect to /api/<version>/.
API_LINK = "api"

# ------------------------------------------------------------------------------

BRANCH = "gh-pages"


def mike():
    """The mike executable next to the running Python (it has no __main__)."""
    exe = Path(sys.executable).with_name("mike")
    return str(exe) if exe.exists() else "mike"


def run(cmd, env=None, cwd=ROOT, check=True, capture=False):
    print("+ " + " ".join(cmd), file=sys.stderr)
    return subprocess.run(
        cmd, cwd=cwd, env=env, check=check, text=True,
        stdout=subprocess.PIPE if capture else None,
    )


def mkdocs_config():
    from mkdocs.utils.yaml import yaml_load

    env = {k: v for k, v in os.environ.items() if not k.startswith("DOCS_")}
    saved = os.environ.copy()
    os.environ.clear()
    os.environ.update(env)
    try:
        with open(ROOT / "mkdocs.yml") as f:
            return yaml_load(f)
    finally:
        os.environ.clear()
        os.environ.update(saved)


def languages(cfg):
    for plugin in cfg.get("plugins", []):
        if isinstance(plugin, dict) and "i18n" in plugin:
            return [lang["locale"] for lang in plugin["i18n"]["languages"]]
    return ["en"]


def root_url(cfg):
    url = cfg["site_url"]
    return url if url.endswith("/") else url + "/"


def version_of(ref):
    """`master` -> `master`; `v1.2.0`, `refs/tags/v1.2.0`, `doc/v1.2.0` -> `1.2.0`."""
    name = ref.rsplit("/", 1)[-1]
    return name[1:] if name[:1] == "v" and name[1:2].isdigit() else name


def release_key(version):
    """(1, 2, 0) for a release `1.2.0`; None for anything else: `master`, a
    pre-release `1.2.0-rc1`."""
    if not re.fullmatch(r"\d+(\.\d+)*", version):
        return None
    return tuple(int(x) for x in version.split("."))


def published_versions(lang):
    r = run(["git", "show", f"{BRANCH}:{lang}/versions.json"], check=False, capture=True)
    return json.loads(r.stdout) if r.returncode == 0 else []


def redirect_html(target, keep_hash=True):
    """A page that sends the browser to `target`, keeping the #fragment, which
    the API reference uses to name a declaration."""
    js = (
        f'location.replace({json.dumps(target)} + location.hash)'
        if keep_hash else f"location.replace({json.dumps(target)})"
    )
    return (
        "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\">\n"
        f"<title>Redirecting</title>\n<script>{js}</script>\n"
        f"<meta http-equiv=\"refresh\" content=\"0; url={target}\">\n"
        f"<link rel=\"canonical\" href=\"{target}\">\n"
        f"</head><body><a href=\"{target}\">{target}</a></body></html>\n"
    )


def lang_env(cfg, lang, version, for_mike=False):
    """The environment of a build of one language of one version. mike appends
    the version to site_url itself."""
    base = urlsplit(root_url(cfg)).path
    env = os.environ.copy()
    env.update(
        DOCS_LANG=lang,
        DOCS_VERSION=version,
        DOCS_ROOT_PATH=base,
        DOCS_SITE_URL=f"{root_url(cfg)}{lang}/" + ("" if for_mike else f"{version}/"),
        NO_MKDOCS_2_WARNING="1",
    )
    return env


def with_api_redirect(cfg, version):
    """Replace doc/<API_LINK>/ with a redirect to /api/<version>/."""
    link = DOC / API_LINK
    shutil.rmtree(link, ignore_errors=True)
    link.mkdir(parents=True)
    target = f"{urlsplit(root_url(cfg)).path}api/{version}/"
    (link / "index.html").write_text(redirect_html(target))


def cmd_serve(args):
    build_api(DOC / API_LINK)
    env = os.environ.copy()
    if args.lang:
        env["DOCS_LANG"] = args.lang
    env.setdefault("NO_MKDOCS_2_WARNING", "1")
    run([sys.executable, "-m", "mkdocs", "serve"], env=env)


def cmd_build(args):
    cfg = mkdocs_config()
    site = ROOT / "site"
    shutil.rmtree(site, ignore_errors=True)
    build_api(site / "api" / args.version)
    with_api_redirect(cfg, args.version)
    for lang in languages(cfg):
        out = site / lang / args.version
        run([sys.executable, "-m", "mkdocs", "build", "--strict", "--site-dir", str(out)],
            env=lang_env(cfg, lang, args.version))
    (site / "index.html").write_text(redirect_html(f"{languages(cfg)[0]}/{args.version}/", keep_hash=False))
    print(f"built {site}/: {', '.join(languages(cfg))} and api, version {args.version}")


def git(*args, capture=True, check=True, cwd=ROOT):
    r = run(["git", *args], capture=capture, check=check, cwd=cwd)
    return r.stdout.strip() if capture and r.stdout else ""


def cmd_deploy(args):
    cfg = mkdocs_config()
    langs = languages(cfg)
    version = version_of(args.ref)

    # Start from the published branch, if there is one.
    if run(["git", "ls-remote", "--exit-code", "--heads", "origin", BRANCH],
           check=False, capture=True).returncode == 0:
        git("fetch", "--depth=1", "origin", f"+{BRANCH}:{BRANCH}", capture=False)

    # `latest` goes to the highest release.
    key = release_key(version)
    others = [release_key(v["version"]) for v in published_versions(langs[0])]
    latest = key is not None and all(k is None or k <= key for k in others)
    aliases = ["latest"] if latest else []

    (ROOT / "zig-out").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(dir=ROOT / "zig-out", prefix="docs-deploy-") as tmp:
        api = Path(tmp) / "api"
        build_api(api)
        with_api_redirect(cfg, version)

        # The guides, one language at a time: mike commits each to gh-pages.
        for lang in langs:
            run([mike(), "deploy", "--deploy-prefix", lang,
                 "--branch", BRANCH, "--alias-type", "redirect", "--update-aliases",
                 "--message", f"docs: {lang} {version} from {git('rev-parse', '--short', 'HEAD')}",
                 version, *aliases], env=lang_env(cfg, lang, version, for_mike=True))

        # The default version of each language: `latest` once there is one.
        versions = json.loads(git("show", f"{BRANCH}:{langs[0]}/versions.json"))
        has_latest = any("latest" in v["aliases"] for v in versions)
        default = "latest" if has_latest else version
        for lang in langs:
            published = run(["git", "cat-file", "-e", f"{BRANCH}:{lang}/index.html"],
                            check=False, capture=True).returncode == 0
            if latest or not published:
                run([mike(), "set-default", "--deploy-prefix", lang,
                     "--branch", BRANCH, "--message", f"docs: {lang} default {default}", default],
                    env=lang_env(cfg, lang, version, for_mike=True))

        # The API reference and the root files, in a worktree of gh-pages.
        work = Path(tmp) / "pages"
        git("worktree", "add", "--force", str(work), BRANCH, capture=False)
        try:
            dest = work / "api" / version
            shutil.rmtree(dest, ignore_errors=True)
            shutil.copytree(api, dest)
            for v in versions:
                for alias in v["aliases"]:
                    a = work / "api" / alias
                    shutil.rmtree(a, ignore_errors=True)
                    a.mkdir(parents=True)
                    (a / "index.html").write_text(redirect_html(f"../{v['version']}/"))
            (work / "api" / "versions.json").write_text(json.dumps(versions, indent=2) + "\n")
            (work / "api" / "index.html").write_text(redirect_html(f"{default}/"))

            (work / "index.html").write_text(redirect_html(f"{langs[0]}/", keep_hash=False))
            target = next((v["version"] for v in versions if v["version"] == default or default in v["aliases"]), version)
            shutil.copyfile(work / langs[0] / target / "404.html", work / "404.html")
            (work / ".nojekyll").write_text("")

            git("add", "--all", cwd=work, capture=False)
            if git("status", "--porcelain", cwd=work):
                git("commit", "--quiet", "--message", f"docs: api {version}, root files", cwd=work, capture=False)
        finally:
            git("worktree", "remove", "--force", str(work), capture=False)
            shutil.rmtree(DOC / API_LINK, ignore_errors=True)

    if args.push:
        git("push", "origin", BRANCH, capture=False)
    print(f"published {version}{' (latest)' if latest else ''} to {BRANCH}"
          + ("" if args.push else "; not pushed: preview it with `mike serve --branch gh-pages`"))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve")
    s.add_argument("--lang", help="build this language only, at the root")
    b = sub.add_parser("build")
    b.add_argument("--version", default="master")
    d = sub.add_parser("deploy")
    d.add_argument("ref", help="master, a tag v1.2.0, or a branch doc/v1.2.0")
    d.add_argument("--push", action="store_true")
    args = p.parse_args()
    {"serve": cmd_serve, "build": cmd_build, "deploy": cmd_deploy}[args.cmd](args)


if __name__ == "__main__":
    main()
