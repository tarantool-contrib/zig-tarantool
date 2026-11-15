-- Migrated from test/integration/kv.lua: drives the KV example module (kv.so) end to end.
local t = require('luatest')
local helper = require('helper')

local g = t.group('kv')

g.before_all(function()
    g.server = helper.start('kv')
end)

g.after_all(function()
    g.server:drop()
end)

g.test_kv = function()
    g.server:exec(function()
        local s = box.schema.space.create('kv', { if_not_exists = true })
        s:format({ { name = 'key', type = 'string' }, { name = 'value', type = 'string' } })
        s:create_index('pk', { parts = { { 1, 'string' } }, if_not_exists = true })

        for _, fn in ipairs({ 'kv_set', 'kv_get', 'kv_del' }) do
            box.schema.func.create('kv.' .. fn, { language = 'C', if_not_exists = true })
        end

        box.func['kv.kv_set']:call{ 'hello', 'world' }
        assert(box.func['kv.kv_get']:call{ 'hello' } == 'world', 'set/get failed')

        box.func['kv.kv_set']:call{ 'hello', 'there' } -- overwrite
        assert(box.func['kv.kv_get']:call{ 'hello' } == 'there', 'overwrite failed')

        assert(box.func['kv.kv_get']:call{ 'missing' } == nil, 'missing key should be nil')

        box.func['kv.kv_del']:call{ 'hello' }
        assert(box.func['kv.kv_get']:call{ 'hello' } == nil, 'delete failed')
    end)
end
