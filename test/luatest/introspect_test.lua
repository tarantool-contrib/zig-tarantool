-- box.info introspection + Space.truncate against a live Tarantool.
-- Procs live in test/integration/introspect.zig (built to introspect.so).
local t = require('luatest')
local helper = require('helper')

local g = t.group('introspect')

g.before_all(function()
    g.server = helper.start('introspect')
    g.server:exec(function()
        -- Space + primary index created here, not in C.
        local s = box.schema.space.create('t', { if_not_exists = true })
        s:create_index('pk', { parts = { 1, 'unsigned' }, if_not_exists = true })

        box.schema.func.create('introspect.intro_snapshot', { language = 'C', if_not_exists = true })
        box.schema.func.create('introspect.intro_ro_probe', { language = 'C', if_not_exists = true })
        box.schema.func.create('introspect.intro_wait_ro', { language = 'C', if_not_exists = true })
        box.schema.func.create('introspect.intro_wait_ro_cancel', { language = 'C', if_not_exists = true })
        box.schema.func.create('introspect.intro_schema_version', { language = 'C', if_not_exists = true })
        box.schema.func.create('introspect.intro_lsn', { language = 'C', if_not_exists = true })
        box.schema.func.create('introspect.intro_truncate', { language = 'C', if_not_exists = true })
    end)
end)

g.after_all(function()
    g.server:drop()
end)

-- Unconditionally restore RW so a mid-test failure inside a flipped exec block
-- can never strand the server read-only and poison later tests.
g.after_each(function()
    g.server:exec(function()
        box.cfg{ read_only = false }
    end)
end)

g.test_snapshot = function()
    g.server:exec(function()
        local ok = box.func['introspect.intro_snapshot']:call({})
        assert(ok == true, 'snapshot: expected true')
    end)
end

g.test_ro_flip = function()
    g.server:exec(function()
        box.cfg{ read_only = true }
        local reason = box.func['introspect.intro_ro_probe']:call({})
        assert(type(reason) == 'string' and #reason > 0,
            'ro_probe: expected non-empty reason, got ' .. tostring(reason))
        box.cfg{ read_only = false }
        local r = box.func['introspect.intro_wait_ro']:call({ false, 1 })
        assert(r == 'ok', 'wait RW after flip back: expected ok, got ' .. tostring(r))
    end)
end

g.test_wait_ro_timeout = function()
    g.server:exec(function()
        -- RW instance: waiting for RO must time out.
        local r = box.func['introspect.intro_wait_ro']:call({ true, 0.05 })
        assert(r == 'timeout', 'wait_ro_timeout: expected timeout, got ' .. tostring(r))
        -- Prove the proc fiber and the server survived the timeout path.
        local lsn = box.func['introspect.intro_lsn']:call({})
        assert(type(lsn) == 'number', 'lsn after timeout: expected number, got ' .. tostring(lsn))
    end)
end

g.test_wait_ro_parks = function()
    g.server:exec(function()
        local fiber = require('fiber')
        local clock = require('clock')
        -- fiber.new only schedules; the flipper cannot run until the current
        -- fiber yields inside box_wait_ro (deterministic, no sleeps).
        fiber.new(function() box.cfg{ read_only = true } end)
        local t0 = clock.monotonic()
        local r = box.func['introspect.intro_wait_ro']:call({ true, 5 })
        local elapsed = clock.monotonic() - t0
        assert(r == 'ok', 'wait_ro_parks: expected ok, got ' .. tostring(r))
        assert(elapsed < 4, 'wait_ro_parks: returned too late, elapsed=' .. tostring(elapsed))
        box.cfg{ read_only = false }
    end)
end

g.test_wait_ro_cancelled = function()
    g.server:exec(function()
        -- Exercises the WaitError.Cancelled arm: the inner spawned fiber is
        -- cancelled, never the proc fiber itself.
        local ok = box.func['introspect.intro_wait_ro_cancel']:call({})
        assert(ok == true, 'wait_ro_cancel: expected true')
    end)
end

g.test_schema_version = function()
    g.server:exec(function()
        local v1 = box.func['introspect.intro_schema_version']:call({})
        local v2 = box.func['introspect.intro_schema_version']:call({})
        assert(v1 == v2, 'schema_version: unchanged across calls, got ' ..
            tostring(v1) .. ' vs ' .. tostring(v2))
        box.schema.space.create('sv_probe')
        local v3 = box.func['introspect.intro_schema_version']:call({})
        assert(v3 > v2, 'schema_version: expected bump after DDL, got ' ..
            tostring(v3) .. ' <= ' .. tostring(v2))
        box.space.sv_probe:drop()
    end)
end

g.test_lsn = function()
    g.server:exec(function()
        local l1 = box.func['introspect.intro_lsn']:call({})
        box.space.t:insert({ 100 })
        local l2 = box.func['introspect.intro_lsn']:call({})
        assert(l2 > l1, 'lsn: expected strictly greater after insert, got ' ..
            tostring(l2) .. ' <= ' .. tostring(l1))
        box.space.t:delete({ 100 })
    end)
end

g.test_truncate = function()
    g.server:exec(function()
        box.space.t:insert({ 1 })
        box.space.t:insert({ 2 })
        box.space.t:insert({ 3 })

        local ok = box.func['introspect.intro_truncate']:call({})
        assert(ok == true, 'truncate: expected true')
        assert(box.space.t:len() == 0, 'truncate: space not empty')

        -- Insert works after truncate.
        box.space.t:insert({ 42 })
        assert(box.space.t:len() == 1, 'truncate: insert after failed')
        box.space.t:delete({ 42 })

        -- Negative: truncate on a read-only instance must fail (ER_READONLY).
        box.cfg{ read_only = true }
        local perr = pcall(function()
            box.func['introspect.intro_truncate']:call({})
        end)
        assert(perr == false, 'truncate on RO: expected error')
        -- after_each restores RW.
    end)
end
