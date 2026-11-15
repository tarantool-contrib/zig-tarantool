-- Drives the batch `tarantool-client` harness exe (test/client/batch.zig,
-- installed to zig-out/bin) against a live listening server. The exe pipelines
-- N request frames in one flush and reads all N replies matched by sync
-- (src/client/batch.zig). Mirrors dml_test.lua: luatest starts a server (its own
-- unix-socket listener drives readiness/:exec), then this group ADDS an
-- ephemeral 127.0.0.1:0 TCP listener for the exe to connect to (ephemeral so
-- parallel/repeat runs never collide on a fixed port). before_all also creates
-- the fixture space + the stored function the batch calls. The exe runs with
-- TT_URI/TT_USER/TT_PASS in the environment; the driver asserts a clean (exit 0)
-- TAP run and surfaces captured output on failure.
local t = require('luatest')
local helper = require('helper')
local fio = require('fio')

local g = t.group('batch')

g.before_all(function()
    -- No box_cfg.listen override: luatest keeps its default unix-socket listener,
    -- which its own net.box connection (used by :exec) and readiness wait rely on.
    g.server = helper.start('batch')
    g.uri = g.server:exec(function()
        -- A password-bearing user exercises the AUTH path the exe connects with;
        -- `super` is ample for the fixture DML/DDL + CALL the harness performs.
        if not box.schema.user.exists('tester') then
            box.schema.user.create('tester', { password = 'secret' })
            -- Granting 'super' takes admin on Tarantool < 3.6 (:exec runs as guest).
            box.session.su('admin', box.schema.user.grant, 'tester', 'super')
        end

        -- Fixture space: format {id unsigned, name string, score unsigned}, memtx,
        -- primary tree on id, plus a NON-UNIQUE secondary tree `by_score` on score.
        if box.space.batch_kv == nil then
            local s = box.schema.space.create('batch_kv', {
                engine = 'memtx',
                format = {
                    { name = 'id', type = 'unsigned' },
                    { name = 'name', type = 'string' },
                    { name = 'score', type = 'unsigned' },
                },
            })
            s:create_index('primary', { type = 'tree', parts = { 'id' } })
            s:create_index('by_score', { type = 'tree', unique = false, parts = { 'score' } })
        end

        -- Stored function the batch CALLs (batch_add(a, b) -> a + b). Persistent so
        -- the batch's CALL handle has a real return value to decode.
        rawset(_G, 'batch_add', function(a, b) return a + b end)
        box.schema.func.create('batch_add', { if_not_exists = true })

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

g.before_each(function()
    -- Truncate the fixture and drop any throwaway space a prior (possibly failed)
    -- run's drift case left behind, so the case is rerunnable.
    g.server:exec(function()
        if box.space.batch_kv ~= nil then box.space.batch_kv:truncate() end
        if box.space.batch_throwaway ~= nil then box.space.batch_throwaway:drop() end
    end)
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

g.test_batch = function()
    local code, tap = run_exe('batch')
    t.assert_equals(code, 0, 'batch harness exe did not exit clean; TAP output:\n' .. tap)
end
