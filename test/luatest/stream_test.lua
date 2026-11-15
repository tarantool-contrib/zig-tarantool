-- Drives the stream (interactive transaction) `tarantool-client` harness exe
-- (test/client/stream.zig, installed to zig-out/bin/stream) against a live
-- listening server. The exe speaks iproto over TCP and exercises Stream.open /
-- begin / commit / rollback + stream-scoped space DML; its linking at all — with
-- no box_* symbols — is the client module's purity proof. Same shape as
-- dml_test.lua: start a server (luatest's own unix-socket listener drives
-- readiness/:exec), then ADD an ephemeral 127.0.0.1:0 TCP listener for the exe.
--
-- box_cfg enables `memtx_use_mvcc_engine` so an open stream transaction's
-- uncommitted writes are INVISIBLE to plain (autocommit) reads on the same
-- connection — the isolation the exe's checks assert. before_all creates the
-- fixture space `stream_kv` {id unsigned, v string} (pk on id). The exe runs with
-- TT_URI/TT_USER/TT_PASS in the environment; the driver asserts a clean (exit 0)
-- TAP run and surfaces captured output on failure.
local t = require('luatest')
local helper = require('helper')
local fio = require('fio')

local g = t.group('stream')

g.before_all(function()
    -- MVCC on: required for the stream-vs-plain isolation the exe checks.
    g.server = helper.start('stream', { memtx_use_mvcc_engine = true })
    g.uri = g.server:exec(function()
        if not box.schema.user.exists('tester') then
            box.schema.user.create('tester', { password = 'secret' })
            -- Granting 'super' takes admin on Tarantool < 3.6 (:exec runs as guest).
            box.session.su('admin', box.schema.user.grant, 'tester', 'super')
        end

        -- Fixture space the exe transacts over: {id unsigned, v string} pk on id.
        if box.space.stream_kv == nil then
            local s = box.schema.space.create('stream_kv', {
                engine = 'memtx',
                format = {
                    { name = 'id', type = 'unsigned' },
                    { name = 'v', type = 'string' },
                },
            })
            s:create_index('primary', { type = 'tree', parts = { 'id' } })
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

g.before_each(function()
    -- Truncate the fixture so the case is rerunnable regardless of a prior run's
    -- leftovers (the exe also deletes/rolls back what it inserts, but this is the
    -- backstop).
    g.server:exec(function()
        if box.space.stream_kv ~= nil then box.space.stream_kv:truncate() end
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

g.test_stream = function()
    local code, tap = run_exe('stream')
    t.assert_equals(code, 0, 'stream harness exe did not exit clean; TAP output:\n' .. tap)
end
