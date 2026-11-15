-- Migrated from test/integration/box.lua: box CRUD / tuple / transaction module.
local t = require('luatest')
local helper = require('helper')

local g = t.group('box')

g.before_all(function()
    g.server = helper.start('box')
end)

g.after_all(function()
    g.server:drop()
end)

g.test_box = function()
    g.server:exec(function()
        -- Space + primary index are created here, not in C.
        local s = box.schema.space.create('t', { if_not_exists = true })
        s:create_index('pk', { parts = { 1, 'unsigned' }, if_not_exists = true })

        box.schema.func.create('box.box_roundtrip', { language = 'C', if_not_exists = true })
        box.schema.func.create('box.box_decode', { language = 'C', if_not_exists = true })
        box.schema.func.create('box.box_txn_rollback_proc', { language = 'C', if_not_exists = true })
        box.schema.func.create('box.box_txn_commit_proc', { language = 'C', if_not_exists = true })

        -- 1. insert / get / delete round-trip returns the name field read back.
        local name = box.func['box.box_roundtrip']:call({ 1, 'alice' })
        assert(name == 'alice', 'roundtrip: expected alice, got ' .. tostring(name))
        assert(s:get({ 1 }) == nil, 'roundtrip: row 1 should be deleted')

        -- 2. decode whole tuple + fieldCount.
        local res = box.func['box.box_decode']:call({})
        -- res is {id_back, field_count}
        assert(res[1] == 99, 'decode: expected id 99, got ' .. tostring(res[1]))
        assert(res[2] == 2, 'decode: expected 2 fields, got ' .. tostring(res[2]))
        assert(s:get({ 99 }) == nil, 'decode: row 99 should be deleted')

        -- 3. transaction rollback: the row must NOT be present afterwards.
        local ok = box.func['box.box_txn_rollback_proc']:call({ 7 })
        assert(ok == true, 'rollback proc: expected true')
        assert(s:get({ 7 }) == nil, 'rollback: row 7 must be absent after rollback')

        -- 4. transaction commit: the row MUST be present afterwards.
        local ok2 = box.func['box.box_txn_commit_proc']:call({ 8 })
        assert(ok2 == true, 'commit proc: expected true')
        local row = s:get({ 8 })
        assert(row ~= nil, 'commit: row 8 must be present')
        assert(row[2] == 'committed', 'commit: expected committed, got ' .. tostring(row and row[2]))
        s:delete({ 8 })
    end)
end
