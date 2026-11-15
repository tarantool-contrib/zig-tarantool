-- Live parity for the pure iproto protocol layer: the
-- connector's analog of verify-cabi. Drives iproto.so end to end:
--   * constant parity: every Zig-pinned RequestType/Key/Feature value is
--     asserted equal to the running server's box.iproto.type/.key/.feature, and
--     the pin COUNT is asserted so a silently dropped or renamed pin fails
--     loudly rather than passing by omission.
--   * scramble cross-check: a random 20-byte salt is scrambled by the Zig
--     chap-sha1 code and independently recomputed in Lua via digest.sha1 +
--     bit.bxor; the raw bytes must match.
--   * SELECT frame fixture: one full request frame built by request.select is
--     decoded here (size prefix, header map, body map) and every key/value
--     asserted, incl. names-in-DML (SPACE_NAME present, SPACE_ID/INDEX_ID
--     absent).
local t = require('luatest')
local helper = require('helper')

local g = t.group('iproto')

g.before_all(function()
    g.server = helper.start('iproto')
end)

g.after_all(function()
    g.server:drop()
end)

g.test_iproto_parity = function()
    g.server:exec(function()
        local digest = require('digest')
        local msgpack = require('msgpack')
        local bit = require('bit')

        for _, fn in ipairs({
            'iproto_type_pins', 'iproto_key_pins', 'iproto_feature_pins',
            'iproto_scramble', 'iproto_build_select_frame',
        }) do
            box.schema.func.create('iproto.' .. fn, { language = 'C', if_not_exists = true })
        end
        local function call(fn, ...) return box.func['iproto.' .. fn]:call({ ... }) end

        -- ---- constant parity -------------------------------------------
        -- For each Zig pin {name -> value}, resolve the live table key
        -- (uppercase for type/key tables; features are already lowercase) and
        -- assert the values match. Returns the pin count so the caller can
        -- assert nothing was silently dropped.
        local function assert_pins(pins, live, uppercase, alias)
            local count = 0
            for name, value in pairs(pins) do
                count = count + 1
                local lname = (alias and alias[name])
                    or (uppercase and name:upper())
                    or name
                local lv = live[lname]
                assert(lv ~= nil, string.format(
                    'live iproto table missing %q (zig pin %s=%d)', lname, name, value))
                assert(lv == value, string.format(
                    'PIN MISMATCH %s: zig=%d live[%s]=%s',
                    name, value, lname, tostring(lv)))
            end
            return count
        end

        local n_types = assert_pins(call('iproto_type_pins'), box.iproto.type, true, nil)
        assert(n_types == 21, string.format(
            'expected 21 type pins (20 RequestType + TYPE_ERROR), got %d', n_types))

        -- `err` (0x52) is the ERROR key; every other Key uppercases directly.
        local n_keys = assert_pins(call('iproto_key_pins'), box.iproto.key, true, { err = 'ERROR' })
        assert(n_keys == 25, string.format('expected 25 key pins, got %d', n_keys))

        local n_feat = assert_pins(call('iproto_feature_pins'), box.iproto.feature, false, nil)
        assert(n_feat == 13, string.format('expected 13 feature pins, got %d', n_feat))

        -- ---- scramble cross-check --------------------------------------------
        -- Must match test/integration/iproto.zig's `test_password`.
        local test_password = 'iproto-parity-secret'

        local function xor_bytes(a, b)
            assert(#a == #b)
            local out = {}
            for i = 1, #a do out[i] = bit.bxor(a:byte(i), b:byte(i)) end
            return string.char(unpack(out))
        end
        -- scramble = sha1(pass) XOR sha1(salt .. sha1(sha1(pass)))
        local function chap_sha1(pass, salt)
            local s1 = digest.sha1(pass)
            local s1s1 = digest.sha1(s1)
            local hashed = digest.sha1(salt .. s1s1)
            return xor_bytes(s1, hashed)
        end

        math.randomseed(os.time() + os.clock() * 1e6)
        local salt_bytes = {}
        for i = 1, 20 do salt_bytes[i] = math.random(0, 255) end
        local salt = string.char(unpack(salt_bytes))

        local got = call('iproto_scramble', salt)
        assert(type(got) == 'string' and #got == 20,
            'scramble: expected 20 raw bytes, got ' .. tostring(got))
        assert(got == chap_sha1(test_password, salt),
            'scramble: Zig chap-sha1 disagrees with the live digest chain')

        -- ---- SELECT frame fixture --------------------------------------------
        local frame = call('iproto_build_select_frame')
        assert(type(frame) == 'string', 'select frame: expected raw bytes')

        -- size prefix: 0xce + u32 BE, and it must equal the remaining length.
        assert(frame:byte(1) == 0xce, 'select frame: size prefix is not 0xce')
        local size = frame:byte(2) * 0x1000000
            + frame:byte(3) * 0x10000
            + frame:byte(4) * 0x100
            + frame:byte(5)
        assert(size == #frame - 5, string.format(
            'select frame: size prefix %d != payload %d', size, #frame - 5))

        local key = box.iproto.key
        local rtype = box.iproto.type

        -- header map {REQUEST_TYPE, SYNC}
        local hdr, nxt = msgpack.decode(frame, 6)
        assert(hdr[key.REQUEST_TYPE] == rtype.SELECT, 'select frame: header type != SELECT')
        assert(hdr[key.SYNC] == 0x1234, 'select frame: header SYNC mismatch')

        -- body map {SPACE_NAME, INDEX_NAME, ITERATOR, LIMIT, OFFSET, KEY}
        local body = msgpack.decode(frame, nxt)
        assert(body[key.SPACE_NAME] == 'tester', 'select frame: SPACE_NAME mismatch')
        assert(body[key.INDEX_NAME] == 'primary', 'select frame: INDEX_NAME mismatch')
        assert(body[key.ITERATOR] == 0, 'select frame: ITERATOR != EQ')
        assert(body[key.LIMIT] == 100, 'select frame: LIMIT mismatch')
        assert(body[key.OFFSET] == 5, 'select frame: OFFSET mismatch')
        assert(type(body[key.KEY]) == 'table' and #body[key.KEY] == 1
            and body[key.KEY][1] == 42, 'select frame: KEY != [42]')

        -- names-in-DML: ids never appear on the wire.
        assert(body[key.SPACE_ID] == nil, 'select frame: SPACE_ID must be absent')
        assert(body[key.INDEX_ID] == nil, 'select frame: INDEX_ID must be absent')

        -- exact body key set: precisely the six keys above.
        local n_body = 0
        for _ in pairs(body) do n_body = n_body + 1 end
        assert(n_body == 6, string.format('select frame: expected 6 body keys, got %d', n_body))
    end)
end
