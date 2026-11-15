-- Migrated from test/integration/seq.lua: drives the box Sequence handle (seq.so)
-- end to end against a live Tarantool: byName id resolution cross-checked against
-- box.space._sequence, the next/current/set/reset cycle, byId/byName
-- addressing the same host sequence, and the two guards (missing name ->
-- NoSuchSequence, current on a never-advanced sequence -> SeqOp).
local t = require('luatest')
local helper = require('helper')

local g = t.group('seq')

g.before_all(function()
    g.server = helper.start('seq')
end)

g.after_all(function()
    g.server:drop()
end)

g.test_seq = function()
    g.server:exec(function()
        -- Sequence "s" exercises the next/current/set/reset cycle.
        box.schema.sequence.create('s', { start = 1, step = 1 })
        local sid = box.space._sequence.index.name:get('s')[1]

        -- Sequence "u" is created and never advanced: current() on it must fault.
        box.schema.sequence.create('u', { start = 1, step = 1 })

        for _, fn in ipairs({
            'seq_byname_id', 'seq_cycle', 'seq_byid_matches',
            'seq_no_such', 'seq_current_unadvanced',
        }) do
            box.schema.func.create('seq.' .. fn, { language = 'C', if_not_exists = true })
        end

        local function call(fn, ...) return box.func['seq.' .. fn]:call({ ... }) end

        -- byName resolves "s" to the same id box.space._sequence reports.
        local resolved_id = call('seq_byname_id')
        assert(resolved_id == sid,
            'byName id: expected ' .. tostring(sid) .. ', got ' .. tostring(resolved_id))

        -- The full cycle returns 0 on the exact expected progression; a non-zero is a
        -- raised host error (the proc fails with a per-step message).
        assert(call('seq_cycle') == 0, 'seq cycle next/current/set/reset')

        -- After seq_cycle, "s" was reset and advanced once (current value 1). byId on
        -- the same id must continue the SAME counter, not start fresh: next yields 2.
        local byid_val = call('seq_byid_matches', sid)
        assert(byid_val == 2,
            'byId advances same sequence: expected 2, got ' .. tostring(byid_val))

        -- Missing name -> NoSuchSequence.
        assert(call('seq_no_such') == 1, 'byName missing name -> NoSuchSequence')

        -- current() on never-advanced "u" -> SeqOp, never a silent 0.
        assert(call('seq_current_unadvanced') == 1, 'current on unadvanced -> SeqOp')
    end)
end
