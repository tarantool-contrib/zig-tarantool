-- Migrated from test/integration/counter.lua: drives the counter example module
-- (counter.so): a sequence-backed counter and auto-incrementing ids for an
-- `events` space.
local t = require('luatest')
local helper = require('helper')

local g = t.group('counter')

g.before_all(function()
    g.server = helper.start('counter')
end)

g.after_all(function()
    g.server:drop()
end)

g.test_counter = function()
    g.server:exec(function()
        box.schema.sequence.create('counter_seq', { if_not_exists = true })

        local events = box.schema.space.create('events', { if_not_exists = true })
        events:format({ { name = 'id', type = 'unsigned' }, { name = 'name', type = 'string' } })
        events:create_index('pk', { parts = { { 1, 'unsigned' } }, if_not_exists = true })

        for _, fn in ipairs({
            'counter_next', 'counter_current', 'counter_set', 'counter_reset', 'counter_add_event',
        }) do
            box.schema.func.create('counter.' .. fn, { language = 'C', if_not_exists = true })
        end
        local function call(fn, ...) return box.func['counter.' .. fn]:call({ ... }) end

        -- next advances from the sequence start (1), monotonically.
        assert(call('counter_next') == 1, 'first next == 1')
        assert(call('counter_next') == 2, 'second next == 2')
        assert(call('counter_current') == 2, 'current reflects last next')

        -- set then next continues from the set value.
        call('counter_set', 100)
        assert(call('counter_next') == 101, 'next after set == 101')

        -- reset returns the sequence to its start.
        call('counter_reset')
        assert(call('counter_next') == 1, 'next after reset == 1')

        -- add_event mints ids from the sequence and inserts into `events`.
        local id1 = call('counter_add_event', 'login')
        local id2 = call('counter_add_event', 'logout')
        assert(id1 == 2 and id2 == 3, 'auto ids advance (2, 3)')
        assert(events:get(id1)[2] == 'login', 'event row stored under its id')
        assert(events:get(id2)[2] == 'logout', 'second event row stored')
    end)
end
