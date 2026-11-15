-- Migrated from test/integration/coio.lua: drives the cooperative fd-readiness
-- free functions (coio.so) end to end -- a fiber parked in wait wakes readable
-- once a byte is written, a wait with nothing to read returns
-- Error.Timeout (a 0 host return is an ERROR, not an empty Events), and
-- close on a fd a fiber is parked on wakes that fiber so it unblocks at all.
-- 
local t = require('luatest')
local helper = require('helper')

local g = t.group('coio')

g.before_all(function()
    g.server = helper.start('coio')
end)

g.after_all(function()
    g.server:drop()
end)

g.test_coio = function()
    g.server:exec(function()
        for _, fn in ipairs({
            'coio_wait_readable', 'coio_wait_timeout', 'coio_close_wakes_waiter',
            'coio_events_bits',
        }) do
            box.schema.func.create('coio.' .. fn, { language = 'C', if_not_exists = true })
        end

        local function call(fn, ...) return box.func['coio.' .. fn]:call({ ... }) end

        -- a parked waiter wakes readable once a byte lands on the write end (the >0 return carries the COIO_READ bit).
        assert(call('coio_wait_readable') == 1, 'wait wakes readable after a write')

        -- a wait with nothing to read returns Error.Timeout (a 0 host return is an
        -- ERROR, never an empty Events).
        assert(call('coio_wait_timeout') == 1, 'wait with no data times out')

        -- close on the fd a fiber is parked on wakes that fiber so it unblocks at all
        -- (assert it returns, not which arm).
        assert(call('coio_close_wakes_waiter') == 1, 'close wakes the parked waiter')

        -- pure bitcast helpers: toInt/fromInt/isEmpty return exact bit values.
        assert(call('coio_events_bits') == 1, 'coio_events_bits')
    end)
end
