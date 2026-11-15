-- Migrated from test/integration/luamod_drv.lua: integration driver for the Lua
-- C-API authoring layer. Module built to zig-out/lib/luamod.so; require('luamod')
-- calls luaopen_luamod.
local t = require('luatest')
local helper = require('helper')

local g = t.group('luamod')

g.before_all(function()
    g.server = helper.start('luamod')
end)

g.after_all(function()
    g.server:drop()
end)

g.test_luamod = function()
    g.server:exec(function()
        local m = require('luamod')

        assert(m.echo('hello') == 'hello', 'echo round-trips a string')
        assert(m.echo('') == '', 'echo handles the empty string')

        -- A missing / non-string argument must raise, not silently coerce.
        local ok, err = pcall(m.echo)
        assert(not ok, 'echo with no argument must error')
        assert(tostring(err):find('expected a string'),
            'expected the raise message, got ' .. tostring(err))

        -- Typed scalars: i64 in/out as cdata, full precision and signedness.
        assert(m.add(2, 40) == 42, 'add(2,40)')
        assert(m.add(-5, 3) == -2, 'add(-5,3) signed path')

        -- Unsigned 64-bit path: value above i64 max, must not truncate.
        assert(m.add_u64(18446744073709551610ULL, 5ULL) == 18446744073709551615ULL,
            'add_u64 full u64 precision')

        -- Typed strings: region-allocated result copied into a Lua string.
        assert(m.concat('foo', 'bar') == 'foobar', 'concat')
        assert(m.concat('', '') == '', 'concat empty')

        -- Typed optionals: nil <-> null both directions.
        assert(m.inc_opt(5) == 6, 'inc_opt present')
        assert(m.inc_opt(nil) == nil, 'inc_opt nil -> nil')

        -- Arity mismatch is fail-fast.
        local ok_ar = pcall(m.add, 1)
        assert(not ok_ar, 'add with one arg must error')
        local _, e_ar = pcall(m.add, 1)
        assert(tostring(e_ar):find('ArityMismatch'), 'arity error, got ' .. tostring(e_ar))

        -- Type mismatch is fail-fast, never a silent coercion.
        local ok_ty, e_ty = pcall(m.add, 'x', 1)
        assert(not ok_ty, 'add with a string arg must error')
        assert(tostring(e_ty):find('TypeMismatch'), 'type error, got ' .. tostring(e_ty))

        -- Named struct <-> table.
        local pt = m.bump({ x = 1, y = 2 })
        assert(pt.x == 2 and pt.y == 3, 'bump named struct <-> table')

        -- Tuple struct <-> 1-based array.
        local sw = m.swap({ 10, 20 })
        assert(sw[1] == 20 and sw[2] == 10, 'swap tuple struct <-> array')

        -- Slice <-> array.
        assert(m.sum_i64({ 1, 2, 3, 4 }) == 10, 'sum slice')
        assert(m.sum_i64({}) == 0, 'sum empty slice')

        -- A wrong element type inside an array is fail-fast.
        local ok_el, e_el = pcall(m.sum_i64, { 1, 'x', 3 })
        assert(not ok_el, 'sum with a non-integer element must error')
        assert(tostring(e_el):find('TypeMismatch'), 'element type error, got ' .. tostring(e_el))

        -- A non-table where a struct is expected is fail-fast.
        local ok_ns = pcall(m.bump, 5)
        assert(not ok_ns, 'bump with a non-table must error')

        -- Tuple bridge: box.tuple in, derived box.tuple out.
        local r = m.tuple_bump(box.tuple.new({ 41, 'x', 'y' }))
        assert(r[1] == 42, 'tuple_bump field0 + 1')
        assert(r[2] == 'ok', 'tuple_bump second field')

        -- A non-tuple (plain table) where a tuple is expected is fail-fast.
        local ok_tp = pcall(m.tuple_bump, { 1, 2, 3 })
        assert(not ok_tp, 'tuple_bump with a non-tuple must error')

        -- Decimal bridge: decimal cdata in, decimal cdata out (copy both ways).
        local dec = require('decimal')
        assert(tostring(m.dec_incr(dec.new('1.5'))) == '2.5', 'decimal round-trip +1')

        -- A plain number / string is not a decimal cdata: pull raises TypeMismatch,
        -- never a silent coercion.
        local ok_dn, e_dn = pcall(m.dec_incr, 1.5)
        assert(not ok_dn, 'dec_incr with a plain number must error')
        assert(tostring(e_dn):find('TypeMismatch'), 'decimal number coercion error, got ' .. tostring(e_dn))
        local ok_ds, e_ds = pcall(m.dec_incr, 'x')
        assert(not ok_ds, 'dec_incr with a string must error')
        assert(tostring(e_ds):find('TypeMismatch'), 'decimal string coercion error, got ' .. tostring(e_ds))

        -- Multi-return: two i64 results fan out as two Lua values (not one table).
        local q, r_mod = m.divmod(7, 2)
        assert(q == 3 and r_mod == 1, 'divmod returns quotient, remainder')
        assert(select('#', m.divmod(7, 2)) == 2, 'true multi-return (two values)')

        -- Mixed string+int multi-return (direct-init form).
        local n, a = m.name_age()
        assert(n == 'bob' and a == 30, 'name_age returns a string and an int')

        -- The error path of a Multi-returning export still raises.
        assert(not pcall(m.divmod, 1, 0), 'divmod error path still raises')

        -- Regression: a plain tuple-struct return is still exactly one table.
        assert(select('#', m.swap({ 10, 20 })) == 1, 'plain tuple still one table')
    end)
end
