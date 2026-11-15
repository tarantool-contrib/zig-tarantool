-- Migrated from test/integration/txn.lua: drives the transaction savepoint module
-- (txn.so) end to end against a live host. Asserts the outside-txn clean state, a
-- savepoint round-trip's persisted and rolled-back rows, and the NoTxn /
-- StaleSavepoint guards.
local t = require('luatest')
local helper = require('helper')

local g = t.group('txn')

g.before_all(function()
    g.server = helper.start('txn')

    -- Second server for the txn extras: non-default isolation needs
    -- the MVCC engine (non-dynamic, so a separate instance), and the sync commit
    -- needs a claimed limbo on a quorum-1 instance.
    g.mvcc = helper.start('txn-mvcc', {
        memtx_use_mvcc_engine = true,
        replication_synchro_quorum = 1,
        replication_synchro_timeout = 120,
    })
    g.mvcc:exec(function()
        box.ctl.promote() -- claim the limbo so sync commits have an owner

        local s = box.schema.space.create('t', { if_not_exists = true })
        s:create_index('pk', { parts = { 1, 'unsigned' }, if_not_exists = true })

        local sync = box.schema.space.create('sync_t', { is_sync = true, if_not_exists = true })
        sync:create_index('pk', { parts = { 1, 'unsigned' }, if_not_exists = true })

        for _, fn in ipairs({
            'txn_iso_roundtrip', 'txn_iso_after_dml', 'txn_timeout_expired',
            'txn_timeout_ok', 'txn_sync_commit', 'txn_alloc_roundtrip',
            'txn_read_committed_sees', 'txn_read_confirmed_sees',
        }) do
            box.schema.func.create('txn.' .. fn, { language = 'C', if_not_exists = true })
        end
    end)
end)

g.after_all(function()
    g.server:drop()
    g.mvcc:drop()
end)

g.test_txn = function()
    g.server:exec(function()
        -- Space + primary index for the savepoint round-trip proc.
        local s = box.schema.space.create('t', { if_not_exists = true })
        s:create_index('pk', { parts = { 1, 'unsigned' }, if_not_exists = true })

        for _, fn in ipairs({
            'txn_outside_clean', 'txn_sp_roundtrip', 'txn_sp_no_txn', 'txn_sp_stale',
        }) do
            box.schema.func.create('txn.' .. fn, { language = 'C', if_not_exists = true })
        end

        local function call(fn, ...) return box.func['txn.' .. fn]:call({ ... }) end

        -- Outside any transaction, the proc context is clean: no id, not active.
        assert(call('txn_outside_clean') == 1, 'outside txn: id() nil and not active')

        -- Savepoint round-trip: {1001,"a"} persists (committed before the savepoint
        -- scope closed), {1002,"b"} is rolled back to the savepoint and never commits.
        assert(call('txn_sp_roundtrip') == 0, 'savepoint round-trip success path')
        assert(s:get({ 1001 }) ~= nil, 'savepoint round-trip: row 1001 (A) persisted')
        assert(s:get({ 1002 }) == nil, 'savepoint round-trip: row 1002 (B) rolled back')

        -- save() with no active transaction yields error.NoTxn.
        assert(call('txn_sp_no_txn') == 1, 'savepoint save with no txn -> NoTxn')

        -- rollback() against a different transaction yields error.StaleSavepoint,
        -- caught before the host call (cross-transaction guard only).
        assert(call('txn_sp_stale') == 1, 'cross-txn savepoint rollback -> StaleSavepoint')
    end)
end

-- Isolation / timeout / sync / alloc surface, all on the MVCC server.
g.test_txn_extras = function()
    g.mvcc:exec(function()
        local t_space = box.space.t
        local function call(fn, ...) return box.func['txn.' .. fn]:call({ ... }) end

        -- Isolation set inside transactionWith is observed by the closure;
        -- null outside.
        assert(call('txn_iso_roundtrip') == 1, 'isolation null -> read_committed -> null')

        -- setIsolation after the first DML -> error.TxnStarted; the txn is
        -- rolled back so {2001} never persists.
        assert(call('txn_iso_after_dml') == 1, 'setIsolation after DML -> TxnStarted')
        assert(t_space:get({ 2001 }) == nil, 'iso-after-dml txn rolled back')

        -- Timeout fires mid-f: the commit sees the aborted txn, {2002} absent.
        assert(call('txn_timeout_expired') == 1, 'timeout expiry -> aborted-by-timeout diag')
        assert(t_space:get({ 2002 }) == nil, 'timeout-expired txn rolled back')

        -- Timeout not hit: commit succeeds, {2003} persists.
        assert(call('txn_timeout_ok') == 0, 'timeout not hit -> commit')
        assert(t_space:get({ 2003 }) ~= nil, 'timeout-ok row persisted')

        -- Sync commit on the quorum-1 promoted instance: {2004} persists.
        assert(call('txn_sync_commit') == 0, 'sync commit succeeds')
        assert(t_space:get({ 2004 }) ~= nil, 'sync-commit row persisted')

        -- Txn-pool alloc: NoTxn outside, round-trips (incl. over-aligned) inside.
        assert(call('txn_alloc_roundtrip') == 1, 'alloc NoTxn guard + round-trips')
    end)
end

-- MVCC visibility smoke: a committed-not-confirmed sync insert parked in the
-- limbo is visible to a .read_committed reader and not to a .read_confirmed one
-- (one assert each; full MVCC semantics are the host's tests, not ours).
g.test_txn_mvcc_visibility = function()
    local srv = g.mvcc

    -- Park a sync insert: quorum 2 on a single instance can never confirm, so
    -- {3001} sits in the limbo — committed locally, not yet confirmed.
    srv:exec(function()
        box.cfg({ replication_synchro_quorum = 2 })
        local fiber = require('fiber')
        local writer = fiber.new(function()
            box.space.sync_t:insert({ 3001 })
        end)
        writer:set_joinable(true)
        rawset(_G, 'txn_writer', writer)
    end)

    -- Wait for the entry to be parked (retry on the driver, not a sleep).
    t.helpers.retrying({ timeout = 10 }, function()
        assert(srv:exec(function() return box.info.synchro.queue.len end) == 1,
            'sync insert parked in the limbo')
    end)

    srv:exec(function()
        local function call(fn, ...) return box.func['txn.' .. fn]:call({ ... }) end
        assert(call('txn_read_committed_sees') == 1, 'read_committed sees limbo row')
        assert(call('txn_read_confirmed_sees') == 0, 'read_confirmed does not see it')
    end)

    -- Lower quorum to 1 to confirm the parked entry, then join the writer.
    srv:exec(function() box.cfg({ replication_synchro_quorum = 1 }) end)
    t.helpers.retrying({ timeout = 10 }, function()
        assert(srv:exec(function() return box.info.synchro.queue.len end) == 0,
            'limbo drained after quorum lowered')
    end)
    srv:exec(function()
        _G.txn_writer:join()
        rawset(_G, 'txn_writer', nil)
    end)
end
