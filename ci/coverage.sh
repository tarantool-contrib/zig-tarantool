#!/bin/bash
# Line coverage of src/ under kcov: unit tests, every Tarantool server the
# luatest suite spawns (the loaded modules), and the client programs.
#
# Meant for a throwaway machine, a CI runner or a container: it replaces
# /usr/bin/tarantool with a kcov wrapper (with sudo when not root). Needs kcov,
# luatest (./deps.sh) and ptrace (docker: --cap-add=SYS_PTRACE).
#
# usage: ci/coverage.sh <out-dir>   -> <out-dir>/merged/index.html
set -euo pipefail

if [ ! -f /.dockerenv ] && [ -z "${CI:-}" ]; then
    echo "ci/coverage.sh replaces /usr/bin/tarantool; run it in a container (or set CI=1)" >&2
    exit 1
fi

OUT=$(realpath -m "${1:?usage: ci/coverage.sh <out-dir>}")
export KCOV_OUT=$OUT/parts
mkdir -p "$KCOV_OUT"
unset TT_APP_NAME TT_INSTANCE_NAME
as_root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }

# luatest starts each server with its own argv[0] (`arg[-1]`): keep that
# pointing at the wrapper so the servers run under kcov, the runner does not.
if [ ! -x /usr/bin/tarantool.real ]; then
    as_root mv /usr/bin/tarantool /usr/bin/tarantool.real
    as_root tee /usr/bin/tarantool >/dev/null <<'EOF'
#!/bin/bash
for a in "$@"; do
    case "$a" in */luatest/*/bin/luatest) exec -a /usr/bin/tarantool /usr/bin/tarantool.real "$@" ;; esac
done
exec kcov --include-pattern=/src/ "$KCOV_OUT/server-$$" /usr/bin/tarantool.real "$@"
EOF
    as_root chmod +x /usr/bin/tarantool
fi

# kcov cannot read the self-hosted x86_64 backend's debug info: force LLVM.
zig build test -Dllvm -Dcoverage="$KCOV_OUT"
zig build modules -Dllvm

for exe in zig-out/bin/*; do
    case "$exe" in *.real) continue ;; esac
    mv "$exe" "$exe.real"
    printf '#!/bin/sh\nexec kcov --include-pattern=/src/ "$KCOV_OUT/client-%s-$$" "%s.real" "$@"\n' \
        "$(basename "$exe")" "$PWD/$exe" > "$exe"
    chmod +x "$exe"
done

status=0
LUA_PATH="./test/luatest/?.lua;;${LUA_PATH:-}" ./.rocks/bin/luatest test/luatest/ || status=$?

kcov --merge "$OUT/merged" "$KCOV_OUT"/*

# Per-file summary (markdown), parsed with tarantool's own json module.
summary_lua=$(mktemp --suffix=.lua)
cat > "$summary_lua" <<'EOF'
local json = require('json')
local f = assert(io.open(arg[1]))
local d = json.decode(f:read('*a'))
f:close()
table.sort(d.files, function(a, b) return tonumber(a.percent_covered) < tonumber(b.percent_covered) end)
print(('**src/ line coverage: %s%% (%d/%d lines)**\n'):format(d.percent_covered, d.covered_lines, d.total_lines))
print('| file | coverage | lines |')
print('|---|---:|---:|')
for _, x in ipairs(d.files) do
    print(('| %s | %s%% | %d/%d |'):format(x.file:match('(src/.*)$') or x.file,
        x.percent_covered, x.covered_lines, x.total_lines))
end
EOF
/usr/bin/tarantool.real "$summary_lua" "$OUT/merged/kcov-merged/coverage.json" > "$OUT/summary.md"
cat "$OUT/summary.md"
exit $status
