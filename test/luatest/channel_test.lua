-- Migrated from test/integration/channel.lua: drives fiber.Channel(T)
-- (channel.so) end to end -- MPMC (2 producers + 2 consumers sum to n(n+1)/2,
-- proving signal-per-op suffices), close-then-drain FIFO + null,
-- send-after-close -> error.Closed, ring wraparound FIFO, and
-- full-buffer parking on a cap-1 channel. Every proc joins all fibers
-- before deinit.
local t = require('luatest')
local helper = require('helper')

local g = t.group('channel')

g.before_all(function()
    g.server = helper.start('channel')
end)

g.after_all(function()
    g.server:drop()
end)

g.test_channel = function()
    g.server:exec(function()
        for _, fn in ipairs({
            'chan_mpmc', 'chan_close_drain', 'chan_send_after_close',
            'chan_wraparound', 'chan_backpressure',
        }) do
            box.schema.func.create('channel.' .. fn, { language = 'C', if_not_exists = true })
        end

        local function call(fn, ...) return box.func['channel.' .. fn]:call({ ... }) end

        -- MPMC: 2 producers + 2 consumers over one channel sum 1..1000 == 500500. A
        -- lost wakeup under signal-per-op would hang the driver, never reach here.
        assert(call('chan_mpmc') == 500500, 'MPMC: combined total is n(n+1)/2')

        -- A closed channel drains its buffered items FIFO, then nulls.
        assert(call('chan_close_drain') == 1, 'close then drain: FIFO 1,2,3 then null')

        -- send after close is error.Closed even with free space.
        assert(call('chan_send_after_close') == 1, 'send after close -> error.Closed')

        -- The FIFO ring wraps head/tail modulo capacity with no off-by-one.
        assert(call('chan_wraparound') == 1, 'wraparound: strict FIFO across the wrap')

        -- A cap-1 channel parks the second send until the consumer drains the first.
        assert(call('chan_backpressure') == 1, 'full-buffer parking: second send blocked')
    end)
end
