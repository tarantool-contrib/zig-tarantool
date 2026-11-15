-- Migrated from test/integration/skeleton.lua: the walking-skeleton module.
local t = require('luatest')
local helper = require('helper')

local g = t.group('skeleton')

g.before_all(function()
    g.server = helper.start('skeleton')
end)

g.after_all(function()
    g.server:drop()
end)

g.test_skeleton = function()
    g.server:exec(function()
        box.schema.func.create('skeleton.skeleton_const', { language = 'C', if_not_exists = true })

        local res = box.func['skeleton.skeleton_const']:call({})
        assert(res == 42, 'expected 42, got ' .. tostring(res))
    end)
end
