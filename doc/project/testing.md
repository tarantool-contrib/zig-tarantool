# Testing

This page describes how the package is tested: the unit tests, the luatest
suite that runs modules and programs against a live Tarantool, the check of the
C API, CI and coverage. It is for those who change the package.

## Layout

| Path | Holds | Run by |
|------|-------|--------|
| `src/**/*.zig`, `test/*.zig` | unit tests: the codec, the protocol, the client, the update operations | `zig build test` |
| `test/integration/<name>.zig` | test modules, built to `<name>.so` | `zig build integration` |
| `examples/<name>/<name>.zig` | the examples, built to `<name>.so` | `zig build integration` |
| `test/client/<name>.zig` | test programs of the network client, built to `bin/<name>` | `zig build integration` |
| `test/luatest/<name>_test.lua` | the luatest groups that load those modules and run those programs | `zig build integration` |
| `examples/consumer/` | a project that depends on this one | `zig build consumer` |

The build finds the files of `test/integration`, `examples` and `test/client`
by listing the directories, so a new file is built without a change to
`build.zig`.

## Run the tests

The unit tests need nothing but Zig:

```sh
zig build test
```

The luatest suite needs `tarantool` 3.5 or later on `PATH`, and luatest, which
`deps.sh` installs into `.rocks/` with `tt`:

```sh
./deps.sh                 # once; TT=/path/to/tt ./deps.sh if tt is not on PATH
zig build integration
```

Each group starts a Tarantool of its own with `luatest.Server`, with `zig-out/lib`
on its `package.cpath`. To run one group:

```sh
zig build modules
LUA_PATH="./test/luatest/?.lua;;$LUA_PATH" ./.rocks/bin/luatest test/luatest/kv_test.lua
```

In the `tarantool/tarantool` Docker images, unset `TT_APP_NAME` and
`TT_INSTANCE_NAME` first: the images set them, and they make every Tarantool the
tests start wait for a cluster configuration.

## Add a test

- **Box API:** a module in `test/integration/<name>.zig`, and a group in
  `test/luatest/<name>_test.lua` that creates its functions and calls them.
- **Network client:** a program in `test/client/<name>.zig` that prints TAP
  and exits with a non-zero code on failure, and a case in
  `test/luatest/client_test.lua` that runs it with `TT_URI`, `TT_USER` and
  `TT_PASS` set.
- **An example:** `examples/<name>/<name>.zig`, with its group in
  `test/luatest/<name>_test.lua`.

## Check the C API

`tarantool.c` declares the C API of Tarantool by hand. To check it against the
headers of an installed Tarantool:

```sh
zig build verify-cabi -Dverify-cabi=true
```

It translates `module.h` with `translate-c` and compares the type of every
declared function, and the value of every constant, with it at compile time. It
reads `/usr/include/tarantool`, `/opt/homebrew/include/tarantool` on macOS, or
the directory of `-Dtarantool-include=<dir>`.

## Check the module boundaries

```sh
zig build purity
```

compiles small programs in which `tarantool-client` or `tarantool-proto`
imports `tarantool`, and passes when each of them fails to compile. See
[Modules and layers](../concepts/layers.md#the-four-modules).

## CI

`.github/workflows/ci.yml` runs on every push and pull request, and weekly:

| Job | Does |
|-----|------|
| `build` | `zig fmt --check`, the unit tests, `purity`, `consumer`, a build of the modules for `aarch64-linux`, `aarch64-macos` and `x86_64-macos`, and a `ReleaseFast` build |
| `integration` | on Linux x86_64 with Tarantool 3.5 to 3.9, on Linux arm64 with 3.5 and 3.9, on macOS with the Tarantool of Homebrew: the unit tests, `verify-cabi` against the installed headers, then the luatest suite |
| `doc-examples` | the examples of this documentation, below, on 3.5 and 3.9 |
| `coverage` | the coverage report, below, on 3.9 |

The jobs run on the runners themselves, with no container:
`.github/actions/tarantool` installs Tarantool and its headers with
`tarantool/setup-tarantool` on Linux, which takes the latest release of a
series, and with Homebrew on macOS, and installs `tt`. The weekly run tests the
new releases. Dependabot keeps the actions, pinned by commit, up to date.

`.github/workflows/docs.yml` builds this documentation with `ci/docs.py
build`, which fails on a broken link or a page missing from the nav, and
publishes it, see [Versions and publishing](#versions-and-publishing).

## The examples of the documentation

```sh
python3 ci/doc_examples.py [page ...]
```

builds the examples of `doc/` and runs them against the `tarantool` on `PATH`.
A file a page shows, a line `` `src/name.zig`: `` and a block after it, goes
into a project of the page in `zig-out/doc-examples/<page>/`, which depends on
this repository. Then:

- the Lua blocks of the page run as one script, and every line
  `expression -- result` must give the result;
- a `.lua` file that listens on a port is started as a server;
- the `tarantool file.lua` and `./zig-out/bin/name` commands of a `console`
  block must print the lines that follow them.

So an example that stops building, or a result that changes, fails CI. Write
examples that way: label each file, end each call with the result it gives.

## Coverage

```sh
ci/coverage.sh <out-dir>
```

measures the line coverage of `src/` with kcov, over the unit tests, every
Tarantool the luatest suite starts, and the test programs. It replaces
`/usr/bin/tarantool` with a wrapper that runs it under kcov, so run it on a
throwaway machine: a CI runner, or a container of `tarantool/tarantool` with
kcov installed and `--cap-add=SYS_PTRACE`. It writes `<out-dir>/merged/index.html` and a summary by
file, `<out-dir>/summary.md`. The `coverage` job of CI uploads both.

`zig build test -Dllvm -Dcoverage=<dir>` covers the unit tests alone. kcov reads
the debug information that the LLVM backend emits; `-Dllvm` selects it.

## The documentation

```sh
python3 -m pip install -r doc/requirements.txt
python3 ci/docs.py serve            # or: ci/docs.py serve --lang ru
```

serves the guides with live reload on `http://127.0.0.1:8000/`, both languages,
the Russian pages under `/ru/`, and the API reference under `/api/`.

The site has two parts:

- the guides, `doc/**/*.md`, written by hand and built by mkdocs, in English
  and Russian;
- the API reference, which `zig build docs` generates from the doc comments of
  `src/` with the autodoc of Zig. A doc comment is the reference: change the
  comment, not a page.

### Versions and publishing

The published site keeps every version, on the `gh-pages` branch, which
GitHub Pages serves:

| Path | Is |
|------|----|
| `/` | a redirect to `/en/` |
| `/en/`, `/ru/` | a redirect to the default version of the language |
| `/en/<version>/`, `/ru/<version>/` | the guides of a version |
| `/api/`, `/api/<version>/` | the API reference, the same way |
| `/<lang>/versions.json`, `/api/versions.json` | the versions, which the version selector of the guides reads |

A version is `master`, published on every push to it, or a release: the tag
`v1.2.0` publishes `1.2.0`. The highest release is aliased `latest`, which is
the default; before the first release, the default is `master`. A release on
an older line, `v1.1.5` after `v1.2.0`, does not take `latest`.

The documentation of a release is fixed on a branch `doc/<tag>`, by
convention: branch `doc/v1.2.0` off the tag `v1.2.0`, commit the fix there and
push it. A push to `doc/v1.2.0` publishes `1.2.0` again, keeping its aliases.
Merge the fix to `master` too, so that the next release has it.

```sh
git switch -c doc/v1.2.0 v1.2.0
# fix doc/, commit
git push origin doc/v1.2.0
```

```sh
python3 ci/docs.py deploy master                # publish to the local gh-pages
python3 ci/docs.py deploy v1.2.0 --push         # what CI does for a tag
python3 ci/docs.py build                        # one version into site/, as CI checks it
```

[mike](https://github.com/jimporter/mike) publishes the guides: each language
is a separate build, `mike deploy --deploy-prefix <lang>`, and Material's
version selector reads the `versions.json` it writes. `ci/docs.py` adds the API
reference and the root redirects in the same layout. The language switcher
links the same page in the other language of the same version
(`doc/overrides/partials/alternate.html`). Only the top of `ci/docs.py`, which
builds the API reference, is specific to this project; the rest of the
publishing can serve any mkdocs project with a reference generated next to it.

### Translations

A translation of `doc/<page>.md` is `doc/<page>.ru.md`, next to it, with the
same headings in the same order and links to the same `.md` files: the site
sends a link to the translation when there is one. A page with no translation
shows the English one, so pages can be translated one at a time. A new section
of the nav needs its Russian title under `nav_translations` in `mkdocs.yml`.

```sh
python3 ci/doc_translations.py
```

lists the translations whose English page changed after them, with the commits
to follow, and those whose English page is gone. `docs.yml` runs it as a
warning.
