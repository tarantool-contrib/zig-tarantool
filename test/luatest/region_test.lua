-- Migrated from test/integration/region.lua: drives the box region allocator /
-- Savepoint module (region.so) end to end. Asserts correctness AND that repeated
-- invocations do not grow region usage unbounded: each "net delta" proc must
-- return 0 on BOTH calls.
local t = require('luatest')
local helper = require('helper')

local g = t.group('region')

g.before_all(function()
    g.server = helper.start('region')
end)

g.after_all(function()
    g.server:drop()
end)

g.test_region = function()
    g.server:exec(function()
        -- Space + primary index for the box CRUD round-trip proc.
        local s = box.schema.space.create('t', { if_not_exists = true })
        s:create_index('pk', { parts = { 1, 'unsigned' }, if_not_exists = true })

        for _, fn in ipairs({
            'region_alloc_sum', 'region_net_zero', 'region_box_crud',
            'region_truncate',
        }) do
            box.schema.func.create('region.' .. fn, { language = 'C', if_not_exists = true })
        end

        local function call(fn, ...) return box.func['region.' .. fn]:call({ ... }) end

        -- region_alloc_sum: buffers of sizes 1..8, buffer k filled with byte k.
        -- sum = 1*1 + 2*2 + ... + 8*8 = 204. Proves usable, correctly-sized scratch.
        assert(call('region_alloc_sum') == 204, 'alloc sum (usable region memory)')

        -- region_net_zero: the Savepoint reclaims everything in its scope, so the net
        -- change in region.used() is 0. Call it TWICE and assert both are 0 — repeated
        -- invocations stay flat, no unbounded growth.
        assert(call('region_net_zero') == 0, 'net-zero region usage, call 1')
        assert(call('region_net_zero') == 0, 'net-zero region usage, call 2')

        -- region_box_crud: the box CRUD layer's internal per-call savepoints reclaim
        -- their encode scratch, so an insert/get/delete round-trip leaves region usage
        -- flat. Call it TWICE and assert both deltas are 0 (IF2).
        assert(call('region_box_crud') == 0, 'box CRUD net-zero region usage, call 1')
        assert(call('region_box_crud') == 0, 'box CRUD net-zero region usage, call 2')
        assert(s:get({ 4242 }) == nil, 'box CRUD: row 4242 must be deleted')

        -- region_truncate: allocate 64 bytes, assert used() grew, truncate back
        -- to the saved mark, assert used() == mark. Returns 1 on success.
        assert(call('region_truncate') == 1, 'region_truncate')
    end)
end
