-- Migrated from test/integration/range.lua: box.Index.range/top + box.Range(Row) — the typed, auto-freeing index cursor.
local t = require('luatest')
local helper = require('helper')

local g = t.group('range')

g.before_all(function()
    g.server = helper.start('range')
end)

g.after_all(function()
    g.server:drop()
end)

g.test_range = function()
    g.server:exec(function()
        local rng = box.schema.space.create('rng', { if_not_exists = true })
        rng:format({
            { name = 'id', type = 'unsigned' },
            { name = 'name', type = 'string' },
            { name = 'score', type = 'integer' },
        })
        rng:create_index('pk', { parts = { { 1, 'unsigned' } }, if_not_exists = true })
        rng:create_index('by_score', { parts = { { 3, 'integer' } }, unique = false, if_not_exists = true })

        -- pk order: alice, bob, carol, max, zoe; scores chosen so descending-by-score
        -- = zoe(50), max(40), alice(30), bob(20), carol(10). Sum = 150.
        rng:replace({ 1, 'alice', 30 })
        rng:replace({ 2, 'bob', 20 })
        rng:replace({ 3, 'carol', 10 })
        rng:replace({ 4, 'max', 40 })
        rng:replace({ 5, 'zoe', 50 })

        for _, fn in ipairs({
            'rng_scan_sum', 'rng_limit_offset', 'rng_top', 'rng_copyout',
            'cur_scan_sum', 'cur_offset_limit', 'cur_copyout',
        }) do
            box.schema.func.create('range.' .. fn, { language = 'C', if_not_exists = true })
        end
        local function call(fn, ...) return box.func['range.' .. fn]:call({ ... }) end

        -- Full typed scan, freeing each row as the cursor advances: sum of all scores.
        assert(call('rng_scan_sum') == 150, 'full scan sums every score')

        -- offset 1 + limit 2 over the pk yields ids 2 and 3 -> checksum 203.
        assert(call('rng_limit_offset') == 203, 'offset/limit window is ids 2,3')

        -- top(2) over by_score is descending: zoe (50), max (40).
        assert(call('rng_top') == 1, 'top(2) descending by score')

        -- A duped name outlives the host tuples freed while advancing the cursor.
        assert(call('rng_copyout') == 1, 'copy-out outlives freed host tuples')

        -- Raw box.Cursor: full scan auto-frees each tuple as it advances (sum 150).
        assert(call('cur_scan_sum') == 150, 'raw cursor full scan sums every score')

        -- Raw cursor offset 1 + limit 2 over the pk yields ids 2 and 3 -> checksum 203.
        assert(call('cur_offset_limit') == 203, 'raw cursor offset/limit window is ids 2,3')

        -- A duped name outlives the borrowed tuple the cursor freed on advance.
        assert(call('cur_copyout') == 1, 'raw cursor copy-out outlives freed tuple')
    end)
end
