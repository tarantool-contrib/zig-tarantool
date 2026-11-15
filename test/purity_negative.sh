#!/bin/sh
# purity_negative.sh — negative compile-gate proving the module boundary holds.
#
# WHY this exists, and why it poisons with *relative* imports:
#   The build.zig module graph alone cannot be trusted to reject cross-module
#   imports. Zig 0.16 diagnoses an *unreferenced named* `@import("<module>")`
#   only LAZILY, when the decl is referenced — so a stray
#   `@import("tarantool")` lurking in the pure msgpack module could go
#   uncaught. A *relative* `@import` of a file owned by another module is
#   instead diagnosed EAGERLY, at file discovery, with the error
#   string "file exists in modules ..." — even when the importing decl is never
#   referenced. This gate copies the real tree into a sandbox, appends such a
#   relative poison to a pure-module file, and asserts the build fails with that
#   exact error. It runs on every `zig build purity`, so the boundary is proven
#   on the actual tree, and it breaks the moment someone rewires msgpack_mod
#   with a host import.
set -eu

if [ -z "${ZIG:-}" ]; then
    echo "purity_negative.sh: ZIG env var is required (absolute path to the zig compiler)" >&2
    exit 1
fi

# The build.zig `purity` step runs this with cwd = repo root.
REPO="$(pwd)"

SANDBOX=""
cleanup() {
    [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"
}
trap cleanup EXIT

# Populate a fresh minimal sandbox copy of the build tree; sets $SANDBOX.
# The integration discovery loop in build.zig `catch return`s when
# test/integration/ is absent, so the copy set stays minimal (no .so builds).
make_sandbox() {
    [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"
    SANDBOX="$(mktemp -d)"
    cp "$REPO/build.zig" "$SANDBOX/build.zig"
    cp "$REPO/build.zig.zon" "$SANDBOX/build.zig.zon"
    cp -R "$REPO/src" "$SANDBOX/src"
    mkdir "$SANDBOX/test"
    cp "$REPO/test/msgpack_test.zig" "$SANDBOX/test/msgpack_test.zig"
    cp "$REPO/test/update_test.zig" "$SANDBOX/test/update_test.zig"
}

# run_probe <label> <target-file-under-sandbox>
# Append a relative import of ../c.zig (a `tarantool`-module file) to a pure
# module's file, build, and require: nonzero exit AND "file exists in modules"
# in the output. Any other outcome prints the captured build output and exits 1.
run_probe() {
    label="$1"
    target="$2"
    make_sandbox
    printf 'comptime { _ = @import("../c.zig"); }\n' >>"$SANDBOX/$target"

    set +e
    out="$(cd "$SANDBOX" && "$ZIG" build test 2>&1)"
    rc=$?
    set -e

    if [ "$rc" -eq 0 ]; then
        echo "purity FAIL ($label): '$target' compiled, but a cross-module import must NOT compile" >&2
        echo "--- captured build output ---" >&2
        echo "$out" >&2
        exit 1
    fi
    case "$out" in
        *"file exists in modules"*)
            echo "OK ($label): cross-module import in $target rejected (file exists in modules)"
            ;;
        *)
            echo "purity FAIL ($label): build failed, but not with the expected 'file exists in modules' error" >&2
            echo "--- captured build output ---" >&2
            echo "$out" >&2
            exit 1
            ;;
    esac
}

# Probe 1: msgpack (std-only) must not reach the host ABI.
run_probe "probe 1: msgpack -> ../c.zig" "src/msgpack/msgpack.zig"

# Probe 2: tarantool-proto (msgpack + std only) must not reach it either.
run_probe "probe 2: tarantool-proto -> ../c.zig" "src/proto/query.zig"

exit 0
