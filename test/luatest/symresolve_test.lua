-- Drives the symresolve module (symresolve.so) against the live tarantool
-- binary: proves resolve() reaches the full symbol table, finding hidden
-- internal symbols that dlsym cannot, and agreeing with dlsym on exported ones.
local t = require('luatest')
local helper = require('helper')

local g = t.group('symresolve')

g.before_all(function()
    g.server = helper.start('symresolve')
end)

g.after_all(function()
    g.server:drop()
end)

g.test_symresolve = function()
    g.server:exec(function()
        local fns = {
            'exported_matches_dlsym',
            'hidden_found',
            'hidden_absent_from_dlsym',
            'missing_is_null',
            'empty_is_null',
        }
        for _, fn in ipairs(fns) do
            box.schema.func.create('symresolve.' .. fn, { language = 'C', if_not_exists = true })
        end

        local function call(fn)
            return box.func['symresolve.' .. fn]:call({})
        end

        -- Exported symbol: resolve() finds it and its address matches dlsym's,
        -- proving the slide/base arithmetic end to end.
        assert(call('exported_matches_dlsym') == 1,
            'resolve(box_txn_begin) disagreed with dlsym')

        -- The control: the "hidden" symbol really is hidden from dlsym, so the
        -- next assertion is meaningful and not a tautology.
        assert(call('hidden_absent_from_dlsym') == 1,
            'txn_begin is unexpectedly visible to dlsym (test binary changed?)')

        -- The payoff: resolve() finds the hidden internal symbol dlsym cannot.
        assert(call('hidden_found') == 1,
            'resolve(txn_begin) returned null for a hidden symbol')

        -- Well-formed misses.
        assert(call('missing_is_null') == 1, 'missing symbol did not resolve to null')
        assert(call('empty_is_null') == 1, 'empty name did not resolve to null')
    end)
end
