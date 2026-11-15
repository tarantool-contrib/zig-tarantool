-- Migrated from test/integration/update.lua: update + upsert module.
local t = require('luatest')
local helper = require('helper')

local g = t.group('update')

g.before_all(function()
    g.server = helper.start('update')
end)

g.after_all(function()
    g.server:drop()
end)

g.test_update = function()
    g.server:exec(function()
        -- Fields (0-based for the C ABI, index_base = 0). Only the first three are
        -- constrained by format; field 3 is an unconstrained trailing integer used as
        -- the negative-addressing target and the deletable field.
        --   0 id (unsigned)  1 n (integer)  2 s (string)  3 extra (untyped)
        local s = box.schema.space.create('t', { if_not_exists = true })
        s:format({
            { name = 'id', type = 'unsigned' },
            { name = 'n',  type = 'integer'  },
            { name = 's',  type = 'string'   },
        })
        s:create_index('pk', { parts = { { 1, 'unsigned' } }, if_not_exists = true })

        local function seed(id)
            s:replace{ id, 5, 'abcdef', 7 }
        end

        for _, fn in ipairs({
            'up_set_comptime', 'up_arith', 'up_splice', 'up_insert_field',
            'up_delete_field', 'up_type_mismatch', 'up_neg_field',
            'up_insert_oob', 'up_delete_oob', 'up_neg_oob',
            'up_upsert_insert', 'up_upsert_update', 'read_n',
        }) do
            box.schema.func.create('update.' .. fn, { language = 'C', if_not_exists = true })
        end

        local function call(fn, ...) return box.func['update.' .. fn]:call({ ... }) end

        -- ---- comptime `=` -------------------------------------------------------
        seed(1)
        assert(call('up_set_comptime', 1, 42) == 42, 'set = via comptime form')

        -- ---- arithmetic via the Ops builder (op codes 0..4) ---------------------
        -- start n = 5 each time
        seed(2)
        assert(call('up_arith', 2, 0, 3) == 8, 'add: 5 + 3')   -- +
        seed(2)
        assert(call('up_arith', 2, 1, 2) == 3, 'sub: 5 - 2')   -- -
        seed(2)
        assert(call('up_arith', 2, 2, 6) == 4, 'band: 5 & 6')  -- & -> 0b100
        seed(2)
        assert(call('up_arith', 2, 3, 2) == 7, 'bor: 5 | 2')   -- | -> 0b111
        seed(2)
        assert(call('up_arith', 2, 4, 6) == 3, 'bxor: 5 ^ 6')  -- ^ -> 0b011

        -- ---- splice `:` (comptime) ----------------------------------------------
        seed(3)
        assert(call('up_splice', 3) == 'XYZdef', 'splice replaces "abc" with "XYZ"')

        -- ---- insert `!` / delete `#` (field-count changes) ----------------------
        seed(4)
        assert(call('up_insert_field', 4) == 5, 'insert a 5th field -> count 5')
        seed(5)
        assert(call('up_delete_field', 5, 1) == 3, 'delete 1 field -> count 3')

        -- ---- type-mismatched `+` on a string field -> error (surfaced as 1) -----
        seed(6)
        local ok = pcall(call, 'up_type_mismatch', 6)
        assert(ok == false, 'type-mismatched + must raise a host error')

        -- ---- negative field addressing: -1 targets the last field ---------
        seed(7)
        assert(call('up_neg_field', 7, 99) == 99, 'set(-1) targets the last field')

        -- ---- insert/delete bounds ----------------------------------------
        -- Insert past the end does NOT error: Tarantool pads with nulls up to the
        -- target field. ! at 0-based field 9 grows {id,n,s,extra} (4 fields) to 10.
        seed(8)
        assert(call('up_insert_oob', 8) == 10, 'out-of-range insert pads with nulls (no error)')
        -- Delete that removes a format-required field DOES error. Deleting 99 fields
        -- from field 1 would drop the required `n`/`s` fields.
        seed(9)
        assert(call('up_delete_oob', 9, 1, 99) == 1, 'delete violating format errors')
        -- Negative field past the front of the tuple errors.
        seed(10)
        assert(call('up_neg_oob', 10) == 1, 'negative field past front errors')

        -- ---- upsert: insert mode then update mode ------------------------------
        -- key 100 absent -> upsert inserts {100, n, "u", "v"}; ops ignored on insert.
        assert(call('up_upsert_insert', 100, 11) == 1, 'upsert inserts when key absent')
        assert(call('read_n', 100) == 11, 'upsert insert stored n=11 (ops not applied)')
        -- key 100 now present -> upsert applies +5 to n.
        assert(call('up_upsert_update', 100, 5) == 1, 'upsert updates when key present')
        assert(call('read_n', 100) == 16, 'upsert update applied +5 -> 16')
    end)
end
