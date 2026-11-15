-- Drives the watcher `tarantool-client` harness exe (test/client/watch.zig,
-- installed to zig-out/bin/watch) against a live listening server. The exe speaks
-- iproto over TCP and exercises the caller-pumped event mailbox (watch /
-- waitEvent / pollEvent / unwatch / watchOnce with auto-re-arm); its linking at
-- all — with no box_* symbols — is the client module's purity proof. Same
-- shape as dml_test.lua: start a server (luatest's own unix-socket listener drives
-- readiness/:exec), then ADD an ephemeral 127.0.0.1:0 TCP listener for the exe.
--
-- Standard box_cfg (no MVCC needed — watchers are unrelated to txn isolation).
-- before_each broadcasts `wkey = 100` BEFORE the exe runs, so the initial EVENT
-- after WATCH carries a deterministic value (the exe asserts 100), sidestepping
-- the never-broadcast null case. The exe runs with TT_URI/TT_USER/TT_PASS in the
-- environment; the driver asserts a clean (exit 0) TAP run and surfaces captured
-- output on failure.
local t = require('luatest')
local helper = require('helper')
local fio = require('fio')

local g = t.group('watch')

g.before_all(function()
    -- No box_cfg.listen override: luatest keeps its default unix-socket listener,
    -- which its own net.box connection (used by :exec) and readiness wait rely on.
    g.server = helper.start('watch')
    g.uri = g.server:exec(function()
        -- A password-bearing user exercises the AUTH path the exe connects with.
        if not box.schema.user.exists('tester') then
            box.schema.user.create('tester', { password = 'secret' })
            -- Granting 'super' takes admin on Tarantool < 3.6 (:exec runs as guest).
            box.session.su('admin', box.schema.user.grant, 'tester', 'super')
        end

        -- Add an ephemeral TCP listener alongside luatest's unix socket, keeping
        -- the existing one so :exec stays connected. Ephemeral (:0) so parallel /
        -- repeat runs never collide on a fixed port.
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

g.before_each(function()
    -- Broadcast the known initial value the exe asserts on its first waitEvent.
    -- Re-broadcasting each run resets any value a prior run's broadcasts left, so
    -- the initial-event check is deterministic and the case is rerunnable.
    g.server:exec(function()
        box.broadcast('wkey', 100)
    end)
end)

g.after_all(function()
    if g.server ~= nil then
        g.server:drop()
    end
end)

-- Run the harness exe capturing combined stdout+stderr and the real exit code.
-- LuaJIT's io.popen handle:close() drops the child status (Lua 5.1 semantics), so
-- the exit code is smuggled out via a trailing __EXIT__:<n> shell marker.
local function run_exe(name)
    local cmd = string.format(
        "TT_URI=%s TT_USER=tester TT_PASS=secret %s/%s 2>&1; echo __EXIT__:$?",
        g.uri, g.bindir, name)
    local h = io.popen(cmd)
    local out = h:read('*a')
    h:close()
    local code = out:match('__EXIT__:(%d+)')
    assert(code ~= nil, 'harness marker missing from exe output:\n' .. out)
    local tap = out:gsub('__EXIT__:%d+%s*$', '')
    return tonumber(code), tap
end

g.test_watch = function()
    local code, tap = run_exe('watch')
    t.assert_equals(code, 0, 'watch harness exe did not exit clean; TAP output:\n' .. tap)
end
