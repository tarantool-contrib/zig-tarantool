-- Migrated from test/integration/pipeline.lua: a fiber producer/consumer handoff
-- over a condition variable, summing 1..n.
local t = require('luatest')
local helper = require('helper')

local g = t.group('pipeline')

g.before_all(function()
    g.server = helper.start('pipeline')
end)

g.after_all(function()
    g.server:drop()
end)

g.test_pipeline = function()
    g.server:exec(function()
        box.schema.func.create('pipeline.pipeline_sum', { language = 'C', if_not_exists = true })
        local function sum(n) return box.func['pipeline.pipeline_sum']:call({ n }) end

        -- The consumer fiber drains every item the producer signals: sum(n) == n(n+1)/2.
        assert(sum(100) == 5050, 'sum 1..100')
        assert(sum(1) == 1, 'sum of a single item')
        assert(sum(0) == 0, 'empty pipeline: consumer sees close-and-empty, returns 0')
        assert(sum(10) == 55, 'sum 1..10 (re-run proves state resets per call)')
    end)
end
