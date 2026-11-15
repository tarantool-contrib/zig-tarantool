-- Migrated from test/integration/tuple.lua: tuple construction / iterator module.
local t = require('luatest')
local helper = require('helper')

local g = t.group('tuple')

g.before_all(function()
    g.server = helper.start('tuple')
end)

g.after_all(function()
    g.server:drop()
end)

g.test_tuple = function()
    g.server:exec(function()
        for _, fn in ipairs({
            'tup_make', 'tup_bsize', 'tup_iter_count', 'tup_iter_sum',
            'tup_iter_seek', 'tup_iter_rewind',
            'tup_update_new', 'tup_update_orig', 'tup_update_returns',
        }) do
            box.schema.func.create('tuple.' .. fn, { language = 'C', if_not_exists = true })
        end

        local function call(fn, ...) return box.func['tuple.' .. fn]:call({ ... }) end

        -- tup_make returns the tuple {7, "hi", 42}; inspect its fields.
        local tup = call('tup_make')
        assert(tup[1] == 7, 'make[1]')
        assert(tup[2] == 'hi', 'make[2]')
        assert(tup[3] == 42, 'make[3]')

        -- bsize of {1,2,3}: msgpack array(3) header (1 byte) + three fixints (1 byte
        -- each) = 4 bytes.
        assert(call('tup_bsize') == 4, 'bsize')

        assert(call('tup_iter_count') == 4, 'iter count')
        assert(call('tup_iter_sum') == 100, 'iter sum')   -- 10+20+30+40
        assert(call('tup_iter_seek') == 30, 'iter seek')  -- field 2 (0-based)
        assert(call('tup_iter_rewind') == 1, 'iter rewind/position')

        -- Tuple.update is 1-based: set(1, 99) targets the FIRST field of {7,"hi",42},
        -- so the new tuple's first field is 99 (pins the 1-based base).
        assert(call('tup_update_new') == 99, 'update new first field (1-based)')
        -- The original tuple is untouched by update (returns a new tuple).
        assert(call('tup_update_orig') == 7, 'update leaves original unchanged')
        -- Full new tuple from set(2,"yo"): field 2 (1-based) is the SECOND field.
        local utup = call('tup_update_returns')
        assert(utup[1] == 7, 'update returns[1]')
        assert(utup[2] == 'yo', 'update returns[2]')
        assert(utup[3] == 42, 'update returns[3]')
    end)
end
