-- Migrated from test/integration/typed.lua: box.Typed(Row) — the typed space view over a positional row.
local t = require('luatest')
local helper = require('helper')

local g = t.group('typed')

g.before_all(function()
    g.server = helper.start('typed')
end)

g.after_all(function()
    g.server:drop()
end)

g.test_typed = function()
    g.server:exec(function()
        local acct = box.schema.space.create('acct', { if_not_exists = true })
        acct:format({
            { name = 'id', type = 'string' },
            { name = 'balance', type = 'integer' },
        })
        acct:create_index('pk', { parts = { { 1, 'string' } }, if_not_exists = true })

        local nums = box.schema.space.create('nums', { if_not_exists = true })
        nums:format({
            { name = 'k', type = 'unsigned' },
            { name = 'v', type = 'integer' },
        })
        nums:create_index('pk', { parts = { { 1, 'unsigned' } }, if_not_exists = true })

        for _, fn in ipairs({
            'typed_acct_roundtrip', 'typed_nums_scalar', 'typed_absent', 'typed_mismatch',
            'typed_insert_dup',
        }) do
            box.schema.func.create('typed.' .. fn, { language = 'C', if_not_exists = true })
        end
        local function call(fn, ...) return box.func['typed.' .. fn]:call({ ... }) end

        -- put/get/del a []const u8 + i64 row (alloc + free copy-out path), then del->null.
        assert(call('typed_acct_roundtrip') == 100, 'acct put/get/del round-trip')

        -- A scalar-only row round-trips with no allocation (free is a no-op).
        assert(call('typed_nums_scalar') == 42, 'scalar-only row round-trip')

        -- A get of a missing key returns null, not an error.
        assert(call('typed_absent') == 0, 'absent get returns null')

        -- A 2-field row read as a 3-field Row surfaces a decode error (no silent truncation).
        assert(call('typed_mismatch') == 1, 'arity mismatch surfaces a decode error')

        -- insert fails on a duplicate pk; put still replaces on that same pk.
        assert(call('typed_insert_dup') == 1, 'insert fails on duplicate, put replaces')
    end)
end
