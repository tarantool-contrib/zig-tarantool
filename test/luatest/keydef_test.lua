-- Migrated from test/integration/keydef.lua: key_def module — key extraction by a KeyDef and by an index's own key_def, the three orderings of compare / compareWithKey, and a repeated build/extract loop.
local t = require('luatest')
local helper = require('helper')

local g = t.group('keydef')

g.before_all(function()
    g.server = helper.start('keydef')
end)

g.after_all(function()
    g.server:drop()
end)

g.test_keydef = function()
    g.server:exec(function()
        -- Space "kd" with a primary key on the first field; idx_extract resolves it.
        local s = box.schema.space.create('kd', { if_not_exists = true })
        s:create_index('pk', { parts = { 1, 'unsigned' }, if_not_exists = true })
        s:replace({ 42, 'v' })

        for _, fn in ipairs({
            'kd_extract',
            'kd_compare', 'kd_compare_eq', 'kd_compare_gt',
            'kd_compare_key', 'kd_compare_key_lt', 'kd_compare_key_gt',
            'idx_extract',
            'kd_repeat',
        }) do
            box.schema.func.create('keydef.' .. fn, { language = 'C', if_not_exists = true })
        end

        local function call(fn, ...) return box.func['keydef.' .. fn]:call({ ... }) end

        -- kd_extract returns the MessagePack key [7, "abc"] as a Lua table.
        local key = call('kd_extract')
        assert(key[1] == 7, 'extract key[1]: expected 7, got ' .. tostring(key[1]))
        assert(key[2] == 'abc', 'extract key[2]: expected abc, got ' .. tostring(key[2]))
        assert(key[3] == nil, 'extract key: expected exactly 2 parts')

        -- compare orderings: 1<2 → -1, 5==5 → 0, 9>3 → 1.
        assert(call('kd_compare') == -1, 'compare lt')
        assert(call('kd_compare_eq') == 0, 'compare eq')
        assert(call('kd_compare_gt') == 1, 'compare gt')

        -- compareWithKey orderings: 5 vs {5} → 0, 5 vs {8} → -1, 8 vs {5} → 1.
        assert(call('kd_compare_key') == 0, 'compareWithKey eq')
        assert(call('kd_compare_key_lt') == -1, 'compareWithKey lt')
        assert(call('kd_compare_key_gt') == 1, 'compareWithKey gt')

        -- idx_extract returns the primary key [42] of row {42,"v"} as a Lua table.
        local pk = call('idx_extract')
        assert(pk[1] == 42, 'idx extract key[1]: expected 42, got ' .. tostring(pk[1]))
        assert(pk[2] == nil, 'idx extract key: expected exactly 1 part')

        -- Repeated build/extract/deinit stays correct.
        assert(call('kd_repeat') == 1, 'repeat build/extract')
    end)
end
