-- Drives the blocking-work offload + fiber-friendly getaddrinfo (coio_call.so)
-- end to end: a callback round-trips a magic value through the worker pool,
-- a callback's own -1 comes back as data not OffloadFailed,
-- the tx loop keeps running while the worker blocks, getAddrInfo resolves
-- localhost, a nonexistent TLD yields ResolveFailed, and a
-- 1e-9 s timeout yields Timeout.
local t = require('luatest')
local helper = require('helper')

local g = t.group('coio_call')

g.before_all(function()
    g.server = helper.start('coio_call')
end)

g.after_all(function()
    g.server:drop()
end)

g.test_coio_call = function()
    g.server:exec(function()
        for _, fn in ipairs({
            'coio_call_roundtrip', 'coio_call_negative_passthrough',
            'coio_call_loop_alive', 'coio_getaddrinfo_localhost',
            'coio_getaddrinfo_bad_host', 'coio_getaddrinfo_tiny_timeout',
        }) do
            box.schema.func.create('coio_call.' .. fn, { language = 'C', if_not_exists = true })
        end

        local function call(fn, ...) return box.func['coio_call.' .. fn]:call({ ... }) end

        -- a callback that sleeps then returns a magic value round-trips exactly
        -- through the worker pool.
        assert(call('coio_call_roundtrip') == 1, 'offload callback round-trips its value')

        -- a callback that itself returns -1 comes back as the VALUE -1, not
        -- error.OffloadFailed (the ran-flag proof).
        assert(call('coio_call_negative_passthrough') == 1, 'callback -1 is data, not OffloadFailed')

        -- the tx event loop keeps running while the worker thread blocks.
        assert(call('coio_call_loop_alive') == 1, 'tx loop stays live during offload')

        -- getAddrInfo resolves localhost to >=1 entry with a non-null addr.
        assert(call('coio_getaddrinfo_localhost') == 1, 'getAddrInfo resolves localhost')

        -- a nonexistent .invalid TLD yields error.ResolveFailed, not a crash.
        assert(call('coio_getaddrinfo_bad_host') == 1, 'bad host yields ResolveFailed')

        -- a 1e-9 s timeout yields error.Timeout -- validates the ER_TIMEOUT diag
        -- mapping live.
        assert(call('coio_getaddrinfo_tiny_timeout') == 1, 'tiny timeout yields Timeout')
    end)
end
