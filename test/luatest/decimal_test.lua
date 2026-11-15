-- Drives the typed-decimal module (decimal.so) end to end against a live
-- Tarantool, cross-checking against Lua's built-in `decimal` module (the same
-- host decNumber library — the truth):
--   * the seven counter-returning procs each assert their internal invariants
--     and return a known count;
--   * dec_bridge doubles the decimal Lua inserted and we assert the stored row
--     equals `decimal.new('123.45') * 2` (the ext bridge, hook decode + encode);
--   * dec_add is a typed `fn(Decimal, Decimal) !Decimal` — we call it with two
--     decimals and assert the result is a decimal equal to `decimal.new('0.3')`
--     (not a string or a double): the typed-proc payoff.
local t = require('luatest')
local helper = require('helper')

local g = t.group('decimal')

g.before_all(function()
    g.server = helper.start('decimal')
end)

g.after_all(function()
    g.server:drop()
end)

g.test_decimal = function()
    g.server:exec(function()
        -- Built-in, preloaded into package.loaded at startup: `require` never
        -- consults package.cpath, so it cannot load our decimal.so.
        local decimal = require('decimal')

        -- Typed space: field 2 is a decimal so the host validates the
        -- round-tripped bytes on replace and hands them back as a decimal.
        local s = box.schema.space.create('dd', { if_not_exists = true })
        s:format({
            { name = 'id', type = 'unsigned' },
            { name = 'd',  type = 'decimal' },
        })
        s:create_index('pk', { parts = { 1, 'unsigned' }, if_not_exists = true })

        for _, fn in ipairs({
            'dec_roundtrip', 'dec_arith', 'dec_inspect', 'dec_math',
            'dec_bridge', 'dec_add', 'dec_copy',
        }) do
            box.schema.func.create('decimal.' .. fn, { language = 'C', if_not_exists = true })
        end

        local function call(fn, ...) return box.func['decimal.' .. fn]:call({ ... }) end

        -- Pure-logic procs assert their invariants internally and return counts.
        assert(call('dec_roundtrip') == 7, 'dec_roundtrip')
        assert(call('dec_arith') == 1, 'dec_arith')
        assert(call('dec_inspect') == 1, 'dec_inspect')
        assert(call('dec_math') == 1, 'dec_math')
        assert(call('dec_copy') == 1, 'dec_copy')

        -- Ext bridge: insert a decimal, let the proc read + double + replace it,
        -- then assert the stored value against Lua decimal math (the oracle).
        s:replace({ 1, decimal.new('123.45') })
        assert(call('dec_bridge') == 1, 'dec_bridge')
        local row = s:get({ 1 })
        assert(row ~= nil, 'dec_bridge: no row')
        local want = decimal.new('123.45') * 2
        assert(row[2] == want, 'dec_bridge: got ' .. tostring(row[2]) .. ', want ' .. tostring(want))

        -- Typed-proc payoff: decimal args in, a decimal out (not a string/double).
        local got = call('dec_add', decimal.new('0.1'), decimal.new('0.2'))
        assert(type(got) == 'cdata', 'dec_add did not return a cdata decimal')
        assert(got == decimal.new('0.3'),
            'dec_add: got ' .. tostring(got) .. ', want 0.3')
    end)
end
