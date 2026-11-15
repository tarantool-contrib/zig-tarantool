-- Migrated from test/integration/proc.lua: raw + typed stored-proc layers.
local t = require('luatest')
local helper = require('helper')

local g = t.group('proc')

g.before_all(function()
    g.server = helper.start('proc')
end)

g.after_all(function()
    g.server:drop()
end)

g.test_proc = function()
    g.server:exec(function()
        box.schema.func.create('proc.proc_add', { language = 'C', if_not_exists = true })
        box.schema.func.create('proc.proc_raw', { language = 'C', if_not_exists = true })
        box.schema.func.create('proc.proc_fail', { language = 'C', if_not_exists = true })

        -- Typed proc: decode (i64, i64) -> i64.
        local sum = box.func['proc.proc_add']:call({ 2, 40 })
        assert(sum == 42, 'expected 42, got ' .. tostring(sum))

        -- Typed proc with negative operands (exercises the codec's signed path).
        local neg = box.func['proc.proc_add']:call({ -5, 3 })
        assert(neg == -2, 'expected -2, got ' .. tostring(neg))

        -- Raw proc: hand-written, returns 7.
        local raw = box.func['proc.proc_raw']:call({})
        assert(raw == 7, 'expected 7, got ' .. tostring(raw))

        -- Arity mismatch must surface as an error, not a silent coercion.
        local ok_arity, err_arity = pcall(function()
            return box.func['proc.proc_add']:call({ 1 })
        end)
        assert(not ok_arity, 'expected arity mismatch to error')
        assert(tostring(err_arity):find('wrong argument count'),
            'expected "wrong argument count", got ' .. tostring(err_arity))

        -- A typed proc returning a Zig error must surface that error.
        local ok_fail, err_fail = pcall(function()
            return box.func['proc.proc_fail']:call({ 1 })
        end)
        assert(not ok_fail, 'expected proc_fail to error')
        assert(tostring(err_fail):find('Boom'),
            'expected "Boom", got ' .. tostring(err_fail))
    end)
end
