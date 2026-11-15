-- Drives the trigger module (trigger.so) end to end -- on_commit fires once and
-- is one-shot; on_rollback fires on rollback; a txn trigger outside a
-- transaction is rejected (NoTxn); on_replace fires with the decoded op +
-- tuple and the handle deregisters it; a veto aborts only the
-- triggering statement -- the whole implicit txn in autocommit and just that
-- statement inside an explicit transaction, which survives and commits;
-- and an on_shutdown handler runs during graceful stop.
--
-- Everything lives in ONE test function so the shutdown leg (which stops the
-- server) runs last, deterministically, regardless of luatest ordering.
local t = require('luatest')
local helper = require('helper')
local fio = require('fio')

local g = t.group('trigger')

g.before_all(function()
    g.server = helper.start('trigger')
end)

g.after_all(function()
    -- The shutdown leg already stops the server; guard against a double stop.
    if g.server ~= nil and not g.stopped then
        g.server:drop()
    end
end)

g.test_trigger = function()
    g.server:exec(function()
        local s = box.schema.space.create('trig_s', { if_not_exists = true })
        s:create_index('pk', { parts = { 1, 'integer' }, if_not_exists = true })

        for _, fn in ipairs({
            'trig_commit', 'trig_rollback', 'trig_no_txn',
            'trig_replace_lifecycle', 'trig_replace_abort',
            'trig_replace_abort_txn',
        }) do
            box.schema.func.create('trigger.' .. fn, { language = 'C', if_not_exists = true })
        end

        local function call(fn) return box.func['trigger.' .. fn]:call({}) end

        assert(call('trig_commit') == 1, 'on_commit fires once, one-shot')
        assert(call('trig_rollback') == 1, 'on_rollback fires on rollback')
        assert(call('trig_no_txn') == 1, 'txn trigger outside a txn -> NoTxn')
        assert(call('trig_replace_lifecycle') == 1, 'on_replace fires + deregisters')
        assert(call('trig_replace_abort') == 1, 'veto aborts the autocommit statement')
        assert(call('trig_replace_abort_txn') == 1,
            'veto aborts only the statement; explicit txn survives + commits')
    end)

    -- Shutdown leg (runner side): register a sentinel-writing on_shutdown
    -- handler, stop the server gracefully, and assert the file appeared.
    local sentinel = fio.pathjoin(g.server.workdir, 'shutdown.sentinel')
    g.server:exec(function(path)
        box.schema.func.create('trigger.trig_shutdown_reg', { language = 'C', if_not_exists = true })
        assert(box.func['trigger.trig_shutdown_reg']:call({ path }) == 1, 'shutdown handler registered')
    end, { sentinel })

    g.server:stop()
    g.stopped = true

    t.helpers.retrying({ timeout = 5 }, function()
        assert(fio.path.exists(sentinel), 'on_shutdown handler wrote the sentinel')
    end)
end
