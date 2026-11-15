-- Drives the Latch fiber-mutex handle and the clock wrappers (latch_clock.so)
-- end to end: mutual exclusion (tryLock false while held, acquire after unlock),
-- FIFO grant order (deterministic by park-order construction, zero sleeps),
-- withLock releasing on BOTH value and error returns, self-held tryLock false
-- without deadlock, clock monotonic growth + *64 units cross-check + CPU-clock
-- busy-loop advance, and a Lua-vs-module realtime window.
local t = require('luatest')
local helper = require('helper')

local g = t.group('latch_clock')

g.before_all(function()
    g.server = helper.start('latch_clock')
end)

g.after_all(function()
    g.server:drop()
end)

g.test_latch_clock = function()
    g.server:exec(function()
        for _, fn in ipairs({
            'latch_mutex', 'latch_fifo', 'latch_with_lock',
            'latch_trylock_self', 'clock_invariants', 'clock_realtime_now',
        }) do
            box.schema.func.create('latch_clock.' .. fn, { language = 'C', if_not_exists = true })
        end

        local function call(fn, ...) return box.func['latch_clock.' .. fn]:call({ ... }) end

        -- mutual exclusion: tryLock is false while the proc holds the latch; the
        -- parked waiter acquires only after the proc unlocks.
        assert(call('latch_mutex') == 1, 'mutex: try-while-held false + acquire after unlock')

        -- FIFO grant order: two waiters parked B-then-C acquire in that order
        -- (order[0]*10 + order[1] == 12), deterministic by construction.
        assert(call('latch_fifo') == 12, 'fifo: B then C in strict request order')

        -- withLock releases on BOTH the value and error return paths.
        assert(call('latch_with_lock') == 1, 'withLock: released on value AND error return')

        -- tryLock on a self-held latch is false without deadlocking.
        assert(call('latch_trylock_self') == 1, 'trylock_self: held false, then free true')

        -- clock monotonic growth + *64 units cross-check + CPU-clock advance.
        -- 
        assert(call('clock_invariants') == 1, 'clock: monotonic grows, units match, CPU ticks')

        -- the module's realtime and the host Lua's realtime fall in a loose
        -- wall-clock window of each other (seconds).
        assert(math.abs(call('clock_realtime_now') - require('clock').realtime()) < 5,
            'clock: module realtime within window of host Lua realtime')
    end)
end
