-- Drives the loop-independence harness exe (test/client/evented.zig, installed
-- to zig-out/bin/evented) which runs the SAME tarantool-client over the platform
-- *evented* std.Io backend (macOS: std.Io.Kqueue) instead of the default Threaded
-- one. Same pattern as client_test.lua: start a server (luatest's unix-socket
-- listener drives readiness/:exec), add an ephemeral 127.0.0.1:0 TCP listener for
-- the exe, create the tester user and the evented_kv fixture space, then run the
-- exe and assert a clean TAP run.
--
-- On Zig 0.16.0 the macOS std.Io.Kqueue backend has
-- netWrite/netClose as @panic("TODO") (see test/client/evented.zig header +
-- $STD/Io/Kqueue.zig), so the client's send/close path cannot run over it. Per
-- the fallback this case runs the exe with
-- TT_EVENTED_SKIP=1: the exe emits a documented skip line and exits 0 without
-- attempting the doomed flow. This is an explicit skip, NOT a faked pass and NOT
-- a silent Threaded fallback. When a future Zig implements those vtable slots, an
-- un-skipped run starts passing and this case can drop the env + assert the flow.
local t = require('luatest')
local helper = require('helper')
local fio = require('fio')

local g = t.group('evented')

g.before_all(function()
    g.server = helper.start('evented')
    g.uri = g.server:exec(function()
        if not box.schema.user.exists('tester') then
            box.schema.user.create('tester', { password = 'secret' })
            -- Granting 'super' takes admin on Tarantool < 3.6 (:exec runs as guest).
            box.session.su('admin', box.schema.user.grant, 'tester', 'super')
        end

        -- Fixture space the exe round-trips over: {id unsigned, v string} pk on id.
        if not box.space.evented_kv then
            local s = box.schema.space.create('evented_kv')
            s:format({
                { name = 'id', type = 'unsigned' },
                { name = 'v', type = 'string' },
            })
            s:create_index('pk', { parts = { 'id' } })
        end

        -- Add an ephemeral TCP listener alongside luatest's unix socket, keeping
        -- the existing one so :exec stays connected.
        local listen = {}
        local cur = box.cfg.listen
        if type(cur) == 'table' then
            for _, v in ipairs(cur) do listen[#listen + 1] = v end
        elseif cur ~= nil then
            listen[#listen + 1] = cur
        end
        listen[#listen + 1] = '127.0.0.1:0'
        box.cfg{ listen = listen }

        local bound = box.info.listen
        local entries = type(bound) == 'table' and bound or { bound }
        for _, u in ipairs(entries) do
            if not u:find('unix/', 1, true) then return u end
        end
        error('no TCP listener bound; box.info.listen=' .. require('json').encode(bound))
    end)
    g.bindir = fio.abspath('zig-out/bin')
end)

g.after_all(function()
    if g.server ~= nil then
        g.server:drop()
    end
end)

-- Run the evented exe capturing combined stdout+stderr and the real exit code.
-- LuaJIT's io.popen handle:close() drops the child status (Lua 5.1 semantics),
-- so the exit code is smuggled out via a trailing __EXIT__:<n> shell marker.
-- TT_EVENTED_SKIP=1: see the group header.
local function run_evented()
    local cmd = string.format(
        "TT_URI=%s TT_USER=tester TT_PASS=secret TT_EVENTED_SKIP=1 %s/evented 2>&1; echo __EXIT__:$?",
        g.uri, g.bindir)
    local h = io.popen(cmd)
    local out = h:read('*a')
    h:close()
    local code = out:match('__EXIT__:(%d+)')
    assert(code ~= nil, 'harness marker missing from exe output:\n' .. out)
    local tap = out:gsub('__EXIT__:%d+%s*$', '')
    return tonumber(code), tap
end

g.test_evented_smoke = function()
    local code, tap = run_evented()
    t.assert_equals(code, 0,
        'evented harness exe did not exit clean; TAP output:\n' .. tap)
    -- The clean exit must be the DOCUMENTED skip, not some other 0-exit
    -- path — assert the skip marker is present so a regression that silently
    -- stops emitting it is caught.
    t.assert_str_contains(tap, 'SKIP evented Io smoke',
        'evented exe exited 0 without the documented skip line; TAP:\n' .. tap)
end
