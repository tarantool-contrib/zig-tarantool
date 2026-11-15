-- Drives the `tarantool-client` harness exes (test/client/*.zig, installed to
-- zig-out/bin) against a live listening server. Each exe is a standalone binary
-- that speaks iproto over TCP; it linking at all — with no box_* symbols — is the
-- client module's purity proof. This group starts a server
-- (luatest's own unix-socket listener drives readiness/:exec), then ADDS an
-- ephemeral 127.0.0.1:0 TCP listener for the exes to connect to — ephemeral so
-- parallel/repeat runs never collide on a fixed port. Each exe runs with
-- TT_URI/TT_USER/TT_PASS in the environment; the driver asserts a clean (exit 0)
-- TAP run and surfaces the captured output on failure.
local t = require('luatest')
local helper = require('helper')
local fio = require('fio')

local g = t.group('client')

g.before_all(function()
    -- No box_cfg.listen override: luatest keeps its default unix-socket listener,
    -- which its own net.box connection (used by :exec) and readiness wait rely on.
    g.server = helper.start('client')
    g.uri = g.server:exec(function()
        -- `super` is ample for the harness (it only pings); a password is what the
        -- AUTH path needs to exercise chap-sha1 and the wrong-password reject.
        if not box.schema.user.exists('tester') then
            box.schema.user.create('tester', { password = 'secret' })
            -- Granting 'super' takes admin on Tarantool < 3.6 (:exec runs as guest).
            box.session.su('admin', box.schema.user.grant, 'tester', 'super')
        end

        -- Persistent Lua function the calleval harness resolves by name over CALL.
        -- A stored `body` registers it in _func so CALL('harness_add', ...) works;
        -- 'super' (granted above) already covers execute, so no extra grant needed.
        box.schema.func.create('harness_add', {
            body = 'function(a, b) return a + b end',
            if_not_exists = true,
        })

        -- Add an ephemeral TCP listener alongside whatever luatest configured,
        -- keeping the existing (unix-socket) listener so :exec stays connected.
        local listen = {}
        local cur = box.cfg.listen
        if type(cur) == 'table' then
            for _, v in ipairs(cur) do listen[#listen + 1] = v end
        elseif cur ~= nil then
            listen[#listen + 1] = cur
        end
        listen[#listen + 1] = '127.0.0.1:0'
        box.cfg{ listen = listen }

        -- box.info.listen is an array once several URIs are bound; return the TCP
        -- one (the exe's parseAddress needs numeric host:port, not a unix socket).
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

-- Run one harness exe with the given env, capturing combined stdout+stderr and
-- the real exit code. LuaJIT's io.popen `handle:close()` does NOT return the
-- child status (Lua 5.1 semantics — returns only `true`), so the exit code is
-- smuggled out via a trailing `__EXIT__:<n>` marker printed by the shell.
local function run_exe(name)
    local cmd = string.format(
        "TT_URI=%s TT_USER=tester TT_PASS=secret %s/%s 2>&1; echo __EXIT__:$?",
        g.uri, g.bindir, name)
    local h = io.popen(cmd)
    local out = h:read('*a')
    h:close()
    local code = out:match('__EXIT__:(%d+)')
    assert(code ~= nil, 'harness marker missing from exe output:\n' .. out)
    -- Strip the marker line from the displayed TAP so failure messages read clean.
    local tap = out:gsub('__EXIT__:%d+%s*$', '')
    return tonumber(code), tap
end

g.test_ping = function()
    local code, tap = run_exe('ping')
    t.assert_equals(code, 0, 'ping harness exe did not exit clean; TAP output:\n' .. tap)
end

g.test_calleval = function()
    local code, tap = run_exe('calleval')
    t.assert_equals(code, 0, 'calleval harness exe did not exit clean; TAP output:\n' .. tap)
end
