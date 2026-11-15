-- Migrated from test/integration/cond.lua: drives the Cond handle (cond.so) end
-- to end -- signal wakes exactly one waiter that observes the predicate flipped
-- before the signal; broadcast makes all 3 waiters runnable;
-- a waitTimeout timeout leaves the cond reusable; a wait
-- surfaces Error.Cancelled on cancel without crashing the host; and
-- waitUntil returns ok when the predicate holds and Timeout within the deadline
-- when it never does.
local t = require('luatest')
local helper = require('helper')

local g = t.group('cond')

g.before_all(function()
    g.server = helper.start('cond')
end)

g.after_all(function()
    g.server:drop()
end)

g.test_cond = function()
    g.server:exec(function()
        for _, fn in ipairs({
            'cond_signal_handshake', 'cond_broadcast_multi',
            'cond_timeout_then_reuse', 'cond_cancel_waiter',
            'cond_wait_until',
        }) do
            box.schema.func.create('cond.' .. fn, { language = 'C', if_not_exists = true })
        end

        local function call(fn, ...) return box.func['cond.' .. fn]:call({ ... }) end

        -- signal wakes one waiter, which observes the predicate flipped before the
        -- signal.
        assert(call('cond_signal_handshake') == 1, 'signal handshake: waiter saw flipped predicate')

        -- broadcast makes all 3 waiters runnable; the final woke count is 3.
        assert(call('cond_broadcast_multi') == 3, 'broadcast woke all 3 waiters')

        -- a waitTimeout timeout did not poison the cond: a post-timeout signal still
        -- wakes a reused waiter.
        assert(call('cond_timeout_then_reuse') == 1, 'timeout then reuse: both legs held')

        -- a wait surfaces Error.Cancelled on cancel; the waiter stored the sentinel 42
        -- and the host did not crash.
        assert(call('cond_cancel_waiter') == 42, 'cancel waiter: saw Cancelled (sentinel 42)')

        -- waitUntil returns ok when the predicate holds and Timeout within the deadline
        -- when it never does.
        assert(call('cond_wait_until') == 1, 'waitUntil: predicate ok + never-true timeout')
    end)
end
