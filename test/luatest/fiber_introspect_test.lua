-- Migrated from test/integration/fiber_introspect.lua: drives the fiber
-- introspection / current-fiber / attr surface (fiber_introspect.so) end to end
-- -- name round-trips on the current and a spawned fiber (fi_name_roundtrip),
-- currentCsw strictly increases across real yields (fi_csw_increases), a live
-- fiber is findable by id while a never-allocated id resolves to null
-- (fi_find_by_id / fi_find_missing), and an enlarged-stack attr runs a
-- deep recursion to completion and is reusable for a second spawn
-- (fi_spawn_big_stack).
local t = require('luatest')
local helper = require('helper')

local g = t.group('fiber_introspect')

g.before_all(function()
    g.server = helper.start('fiber_introspect')
end)

g.after_all(function()
    g.server:drop()
end)

g.test_fiber_introspect = function()
    g.server:exec(function()
        for _, fn in ipairs({
            'fi_name_roundtrip', 'fi_csw_increases',
            'fi_find_by_id', 'fi_find_missing', 'fi_spawn_big_stack',
            'fi_handle_csw',
        }) do
            box.schema.func.create('fiber_introspect.' .. fn, { language = 'C', if_not_exists = true })
        end

        local function call(fn, ...) return box.func['fiber_introspect.' .. fn]:call({ ... }) end

        -- setCurrentName/currentName round-trips on the proc fiber and setName/name
        -- round-trips on a spawned fiber before join.
        assert(call('fi_name_roundtrip') == 1, 'name round-trip (current + spawned)')

        -- currentCsw strictly increases across real yields driven by a co-fiber; the
        -- proc returns the positive delta.
        assert(call('fi_csw_increases') > 0, 'currentCsw delta positive')

        -- find resolves a live fiber id and the read-only view's id matches.
        assert(call('fi_find_by_id') == 1, 'find live id resolves + matches')

        -- a spawned handle's csw is observably > 0 after rescheduling against it and
        -- equals the read-only find-view's csw (Fiber.csw == FiberInfo.csw).
        assert(call('fi_handle_csw') == 1, 'fi_handle_csw')

        -- a never-allocated id resolves to null, not an error.
        assert(call('fi_find_missing') == 1, 'find unused id is null')

        -- spawnWithAttr runs a deep recursion (depth 2500, ~600 KiB of frames) that
        -- overflows the ~516 KiB default fiber stack but completes on the enlarged 4 MiB
        -- attr stack, and the same attr drives a second spawn; the checksum is
        -- sum(1..2500) = 2500 * 2501 / 2 = 3126250.
        assert(call('fi_spawn_big_stack') == 3126250, 'big-stack deep recursion checksum')
    end)
end
