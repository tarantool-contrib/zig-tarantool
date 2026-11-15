-- Migrated from test/integration/index.lua: Index/Iterator module.
local t = require('luatest')
local helper = require('helper')

local g = t.group('index')

g.before_all(function()
    g.server = helper.start('index')
end)

g.after_all(function()
    g.server:drop()
end)

g.test_index = function()
    g.server:exec(function()
        local s = box.schema.space.create('t', { if_not_exists = true })
        s:format({ { name = 'id', type = 'unsigned' }, { name = 'sec', type = 'unsigned' } })
        s:create_index('pk', { parts = { { 1, 'unsigned' } }, if_not_exists = true })
        s:create_index('sec', { parts = { { 2, 'unsigned' } }, unique = false, if_not_exists = true })

        -- Rows (id, sec): two ties at sec=10.
        s:replace{ 1, 30 }
        s:replace{ 2, 10 }
        s:replace{ 3, 20 }
        s:replace{ 4, 10 }

        for _, fn in ipairs({
            'idx_len', 'idx_count', 'idx_sum_ge', 'idx_first', 'idx_min', 'idx_max',
            'idx_select', 'idx_random', 'idx_missing_space', 'idx_missing_index',
            'idx_by_id', 'idx_bsize',
        }) do
            box.schema.func.create('index.' .. fn, { language = 'C', if_not_exists = true })
        end

        local function call(fn, ...) return box.func['index.' .. fn]:call({ ... }) end

        -- iterator type codes: EQ=0 REQ=1 ALL=2 LT=3 LE=4 GE=5 GT=6
        assert(call('idx_len') == 4, 'len')

        assert(call('idx_count', 2, 0) == 4, 'count ALL')   -- ALL ignores key
        assert(call('idx_count', 5, 20) == 2, 'count GE 20') -- {20,30}
        assert(call('idx_count', 6, 10) == 2, 'count GT 10') -- {20,30}
        assert(call('idx_count', 0, 10) == 2, 'count EQ 10') -- two ties
        assert(call('idx_count', 3, 20) == 2, 'count LT 20') -- {10,10}

        assert(call('idx_sum_ge', 20) == 4, 'sum_ge 20')     -- ids 3 + 1

        assert(call('idx_first', 5, 20) == 20, 'first GE 20')
        assert(call('idx_first', 6, 20) == 30, 'first GT 20')
        assert(call('idx_first', 4, 20) == 20, 'first LE 20 (desc)')
        assert(call('idx_first', 3, 20) == 10, 'first LT 20 (desc)')

        assert(call('idx_min') == 10, 'min')
        assert(call('idx_max') == 30, 'max')

        assert(call('idx_select', 0, 2) == 2, 'select offset0 limit2')
        assert(call('idx_select', 1, 10) == 3, 'select offset1 (4-1 left)')

        assert(call('idx_random') == 1, 'random')
        assert(call('idx_missing_space') == 1, 'missing space errors')
        assert(call('idx_missing_index') == 1, 'missing index errors')

        assert(call('idx_by_id') == 4, 'idx_by_id: secondary index (id=1) has same row count as primary')
        assert(call('idx_bsize') > 0, 'idx_bsize: secondary index has non-zero memory footprint')
    end)
end
