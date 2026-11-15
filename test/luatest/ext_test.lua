-- Migrated from test/integration/ext.lua: drives the MP_EXT codec module (ext.so)
-- end to end:
--   * ext_roundtrip: build {id, uuid, datetime, decimal} via the pure Zig codec,
--     replace into a typed space, read back, and assert each field as its
--     native Tarantool type.
--   * dec_oracle: cross-check the pure decimal encoding against the host's
--     box_decimal_mp_encode for a fixed set of strings.
local t = require('luatest')
local helper = require('helper')

local g = t.group('ext')

g.before_all(function()
    g.server = helper.start('ext')
end)

g.after_all(function()
    g.server:drop()
end)

g.test_ext = function()
    g.server:exec(function()
        local uuid = require('uuid')
        local datetime = require('datetime')
        local decimal = require('decimal')

        -- Typed space: every ext field gets its Tarantool type so the host validates
        -- the round-tripped bytes on replace and hands them back as native values.
        local s = box.schema.space.create('x', { if_not_exists = true })
        s:format({
            { name = 'id', type = 'unsigned' },
            { name = 'u',  type = 'uuid' },
            { name = 'dt', type = 'datetime' },
            { name = 'd',  type = 'decimal' },
            { name = 'iv', type = 'interval' },
        })
        s:create_index('pk', { parts = { 1, 'unsigned' }, if_not_exists = true })

        for _, fn in ipairs({ 'ext_roundtrip', 'dec_oracle', 'interval_reencode' }) do
            box.schema.func.create('ext.' .. fn, { language = 'C', if_not_exists = true })
        end

        local function call(fn, ...) return box.func['ext.' .. fn]:call({ ... }) end

        -- ext_roundtrip stores the typed tuple and returns 1.
        assert(call('ext_roundtrip') == 1, 'ext_roundtrip returned non-1')

        -- Read the row back and assert each field as its native type.
        local row = s:get({ 1 })
        assert(row ~= nil, 'roundtrip: no row stored')
        assert(row[1] == 1, 'roundtrip: id mismatch')

        local expect_u = uuid.fromstr('00112233-4455-6677-8899-aabbccddeeff')
        assert(row[2] == expect_u,
            'roundtrip: uuid mismatch, got ' .. tostring(row[2]))

        -- 1609459200 == 2021-01-01T00:00:00Z.
        local expect_dt = datetime.new({ timestamp = 1609459200 })
        assert(row[3] == expect_dt,
            'roundtrip: datetime mismatch, got ' .. tostring(row[3]))

        local expect_d = decimal.new('3.14159')
        assert(row[4] == expect_d,
            'roundtrip: decimal mismatch, got ' .. tostring(row[4]))

        -- dec_oracle returns the full sample count when every pure encoding is
        -- byte-identical to box_decimal_mp_encode. Any divergence fails the proc.
        assert(call('dec_oracle') == 8, 'dec_oracle did not match all 8 samples')

        -- Interval field (row[5]) round-trips: interval __eq on stored values.
        assert(row[5] == datetime.interval.new({ year = 1, day = -3, sec = 7, adjust = 'last' }),
            'roundtrip: interval mismatch, got ' .. tostring(row[5]))

        -- interval byte-oracle: for each sample, the proc decodes the host's
        -- MP_EXT bytes and re-encodes via the pure codec; the result must equal
        -- msgpack.encode(itv) exactly. No host C API — this is the whole proof.
        local msgpack = require('msgpack')
        local samples = {
            {},
            { year = 1 }, { month = 2 }, { week = 3 }, { day = 4 },
            { hour = 5 }, { min = 6 }, { sec = 7 }, { nsec = 8 },
            { day = -3 }, { day = -33 },
            { sec = 200 }, { sec = 1000 }, { sec = 70000 },
            { sec = 5000000000 }, { sec = -5000000000 },
            { month = 1, adjust = 'excess' },
            { adjust = 'excess' },
            { sec = 200, adjust = 'excess' },
            { day = 4, hour = 5, sec = 200, adjust = 'excess' },
            { adjust = 'last' },
            { year = 1, month = 2, week = 3, day = 4, hour = 5, min = 6, sec = 7, nsec = 8, adjust = 'last' },
            { year = -1, month = -2, day = -4, sec = -7 },
        }
        for i, sample in ipairs(samples) do
            local itv = datetime.interval.new(sample)
            assert(call('interval_reencode', itv) == msgpack.encode(itv),
                'interval_reencode mismatch at sample ' .. i)
        end
    end)
end
