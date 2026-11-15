-- Shared luatest harness: start a Server that can load the built modules.
--
-- Each module group gets its own luatest.Server (a separate tarantool
-- subprocess with its own datadir), preserving the per-driver isolation the
-- old plain-tarantool drivers had.
--
-- The Server's cwd is its own workdir, so a relative `package.cpath` would not
-- find zig-out/lib. We compute the absolute path in the runner (whose cwd is
-- the project root) and inject it into the Server via srv:exec — exec closures
-- cannot capture upvalues, so the path is passed as an argument.
--
-- The build installs modules as <name>.so on Linux and <name>.dylib on macOS,
-- the extension Tarantool itself searches for; the server reports it as
-- `require('tarantool').build.mod_format`.
local t = require('luatest')
local fio = require('fio')

local M = {}

-- start(alias[, box_cfg]) -> server: a started Server with zig-out/lib on its
-- cpath. `box_cfg` defaults to `{}`; pass a table (e.g. to enable the MVCC
-- engine) for groups that need non-default box configuration.
function M.start(alias, box_cfg)
    local server = t.Server:new({ alias = alias, box_cfg = box_cfg or {} })
    server:start()
    local libdir = fio.abspath('zig-out/lib')
    server:exec(function(dir)
        local ext = require('tarantool').build.mod_format
        package.cpath = dir .. '/?.' .. ext .. ';' .. package.cpath
    end, { libdir })
    return server
end

return M
