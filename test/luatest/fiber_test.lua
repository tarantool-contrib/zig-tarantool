-- Migrated from test/integration/fiber.lua: drives the Fiber(Result) handle and
-- spawn helpers (fiber.so) end to end -- spawn/join collects a body result,
-- detached runs before returning to the caller then completes on a later
-- yield, cancel + join cooperatively unwinds a yielding loop, and
-- join blocks across a real sleep-yield to collect the body result.
local t = require('luatest')
local helper = require('helper')

local g = t.group('fiber')

g.before_all(function()
    g.server = helper.start('fiber')
end)

g.after_all(function()
    g.server:drop()
end)

g.test_fiber = function()
    g.server:exec(function()
        for _, fn in ipairs({
            'fib_spawn_join', 'fib_detached_counter',
            'fib_cancel_join', 'fib_join_after_sleep',
            'fib_wakeup',
        }) do
            box.schema.func.create('fiber.' .. fn, { language = 'C', if_not_exists = true })
        end

        local function call(fn, ...) return box.func['fiber.' .. fn]:call({ ... }) end

        -- spawn computes a + b in a fiber and join collects it.
        assert(call('fib_spawn_join', 20, 22) == 42, 'spawn/join sum')

        -- detached body ran before returning to the caller (counter 1) and completed on
        -- a later yield (counter 11), without crashing.
        assert(call('fib_detached_counter') == 11, 'detached counter advanced to 11')

        -- cancel wakes the yielding loop; isCancelled flips true; join collects the
        -- sentinel (cooperative cancel, no crash).
        assert(call('fib_cancel_join') == 7, 'cancel + join sentinel')

        -- join blocks across the body's real sleep-yield and collects 99 from the typed
        -- slot, freeing it once.
        assert(call('fib_join_after_sleep') == 99, 'join across sleep collects result')

        -- wakeup resumes a fiber parked on a long sleep so join collects the
        -- sentinel promptly; a wakeup no-op would hang and luatest's timeout
        -- would fail the test.
        assert(call('fib_wakeup') == 7, 'fib_wakeup')
    end)
end
