#!/bin/sh
# Install the test-time Lua dependencies into a project-local .rocks/ tree.
# luatest pulls `checks` transitively, so this needs network access (one-off).
# `tt` lives at the Tarantool SDK path, not always on PATH — override with TT=.
set -e
${TT:-tt} rocks install --tree .rocks luatest
