-- Drives the textutil example (textutil.so): a require()-able Lua module whose
-- entries are plain Zig functions exported with lua.exportModule.
local t = require('luatest')
local helper = require('helper')

local g = t.group('textutil')

g.before_all(function()
    g.server = helper.start('textutil')
end)

g.after_all(function()
    g.server:drop()
end)

g.test_textutil = function()
    g.server:exec(function()
        local t = require('luatest')
        local textutil = require('textutil')

        t.assert_equals(textutil.upper('hello, World'), 'HELLO, WORLD')
        t.assert_equals(textutil.upper(''), '')

        t.assert(textutil.words('  a bb  ccc ') == 3, 'three words')
        t.assert(textutil.words('') == 0, 'no words')

        local q, r = textutil.divmod(17, 5)
        t.assert(q == 3 and r == 2, 'divmod(17, 5) == 3, 2')

        local ok, err = pcall(textutil.divmod, 1, 0)
        t.assert_not(ok, 'divmod by zero raises')
        t.assert_str_contains(tostring(err), 'DivByZero')

        -- A wrong argument type raises instead of being coerced.
        t.assert_not(pcall(textutil.upper, 42), 'upper(42) raises')
    end)
end
