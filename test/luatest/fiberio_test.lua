-- Self-connect deadlock-freedom proof for `tarantool.fiberio`.
-- Drives the fiberio.so procs, which run the in-process
-- `tarantool-client` over the SDK's fiber-yielding `std.Io` backend from a
-- stored proc — i.e. on a fiber on the TX thread, connecting BACK to this very
-- instance. A blocking I/O backend would deadlock (the server can't serve the
-- client's own connection while the TX thread is blocked in a syscall); a
-- fiber-yielding one completes the round-trip. So a clean `fiberio_selftest`
-- run IS the yield proof.
--
-- Setup mirrors the client groups (batch/dml): luatest keeps its default
-- unix-socket listener for :exec, and this group ADDS an ephemeral 127.0.0.1:0
-- TCP listener the proc connects to. The proc takes that URI as an argument
-- (no discovery). Both cases carry a few-seconds connect timeout inside the
-- proc, so a regression fails fast; luatest's own per-test timeout is the outer
-- backstop against a true hang.
local t = require('luatest')
local helper = require('helper')

local g = t.group('fiberio')

g.before_all(function()
    -- No box_cfg.listen override: luatest keeps its default unix-socket listener,
    -- which its own net.box connection (used by :exec) relies on.
    g.server = helper.start('fiberio')
    g.uri = g.server:exec(function()
        -- A password-bearing user exercises the AUTH path the proc connects with;
        -- `super` is ample for the fixture DML the self-connect performs.
        if not box.schema.user.exists('tester') then
            box.schema.user.create('tester', { password = 'secret' })
            -- Granting 'super' takes admin on Tarantool < 3.6 (:exec runs as guest).
            box.session.su('admin', box.schema.user.grant, 'tester', 'super')
        end

        -- Fixture space the self-connect inserts into: format {id unsigned,
        -- v string}, memtx, primary tree on id.
        if box.space.fiberio_kv == nil then
            local s = box.schema.space.create('fiberio_kv', {
                engine = 'memtx',
                format = {
                    { name = 'id', type = 'unsigned' },
                    { name = 'v', type = 'string' },
                },
            })
            s:create_index('primary', { type = 'tree', parts = { 'id' } })
        end

        -- Register both C procs from fiberio.so.
        for _, fn in ipairs({ 'fiberio_selftest', 'fiberio_deadport' }) do
            box.schema.func.create('fiberio.' .. fn, { language = 'C', if_not_exists = true })
        end

        -- Add an ephemeral TCP listener alongside luatest's unix socket, keeping
        -- the existing listener so :exec stays connected.
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
        -- one (the proc's parseAddress needs numeric host:port, not a unix socket).
        local bound = box.info.listen
        local entries = type(bound) == 'table' and bound or { bound }
        for _, u in ipairs(entries) do
            if not u:find('unix/', 1, true) then return u end
        end
        error('no TCP listener bound; box.info.listen=' .. require('json').encode(bound))
    end)
end)

g.before_each(function()
    -- Truncate the fixture so the self-connect insert {1,hello} is rerunnable.
    g.server:exec(function()
        if box.space.fiberio_kv ~= nil then box.space.fiberio_kv:truncate() end
    end)
end)

g.after_all(function()
    if g.server ~= nil then
        g.server:drop()
    end
end)

-- Case 1: the deadlock-freedom proof. The proc connects back to this instance's
-- TCP listener over tarantool.fiberio, pings, inserts+gets on fiberio_kv, evals
-- 1+1, and closes — all from a fiber on the TX thread. A blocking backend would
-- hang here (caught by the in-proc timeout / luatest timeout); the fiber-yielding
-- backend returns "ok".
g.test_fiberio_selftest = function()
    local res = g.server:exec(function(uri)
        return box.func['fiberio.fiberio_selftest']:call({ uri })
    end, { g.uri })
    t.assert_equals(res, 'ok', 'in-process self-connect round-trip did not complete cleanly')
end

-- Case 2: the negative. Connecting to a dead port (127.0.0.1:1) must FAIL within
-- the timeout, not hang. The proc returns "ok" iff the connect errored.
g.test_fiberio_deadport = function()
    local res = g.server:exec(function()
        return box.func['fiberio.fiberio_deadport']:call({ '127.0.0.1:1' })
    end)
    t.assert_equals(res, 'ok', 'dead-port connect should fail cleanly within the timeout, not hang')
end
