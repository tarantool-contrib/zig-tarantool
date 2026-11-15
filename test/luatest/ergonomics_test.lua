-- Migrated from test/integration/ergonomics.lua: SDK ergonomics trio — Space *Discard variants, Tuple.get typed field access, and proc.fail / err.lastMessage host-error surfacing.
local t = require('luatest')
local helper = require('helper')

local g = t.group('ergonomics')

g.before_all(function()
    g.server = helper.start('ergonomics')
end)

g.after_all(function()
    g.server:drop()
end)

g.test_ergonomics = function()
    g.server:exec(function()
        local s = box.schema.space.create('erg', { if_not_exists = true })
        s:format({
            { name = 'id', type = 'unsigned' },
            { name = 'n', type = 'integer' },
            { name = 'name', type = 'string' },
        })
        s:create_index('pk', { parts = { { 1, 'unsigned' } }, if_not_exists = true })

        for _, fn in ipairs({
            'erg_discard', 'erg_typed_get', 'erg_fail_boxop', 'erg_fail_fallback', 'erg_last_message',
            'erg_last_error', 'erg_raw_nospace', 'erg_raw_dupkey',
        }) do
            box.schema.func.create('ergonomics.' .. fn, { language = 'C', if_not_exists = true })
        end
        local function call(fn, ...) return box.func['ergonomics.' .. fn]:call({ ... }) end

        -- All five *Discard write variants land and free their result.
        assert(call('erg_discard') == 1, 'discard variants')

        -- Tuple.get decodes a typed field (and the proc asserts absent->null, mismatch->error).
        assert(call('erg_typed_get') == 42, 'typed get returns the int field')

        -- A BoxOp surfaces the host's real message, not the fallback.
        local ok, e = pcall(function() return call('erg_fail_boxop') end)
        assert(not ok, 'duplicate-key insert should fail')
        local m = tostring(e)
        assert(m:find('Duplicate', 1, true), 'expected the host Duplicate message, got: ' .. m)
        assert(not m:find('fallback', 1, true), 'the fallback must not appear')

        -- A non-BoxOp failure surfaces the fallback, never the seeded stale host error.
        ok, e = pcall(function() return call('erg_fail_fallback') end)
        assert(not ok, 'NoSuchSpace should fail')
        m = tostring(e)
        assert(m:find('erg-fallback-msg', 1, true), 'expected the fallback, got: ' .. m)
        assert(not m:find('Duplicate', 1, true), 'the stale host error must not leak')

        -- err.lastMessage composes the host text into a new message.
        ok, e = pcall(function() return call('erg_last_message') end)
        assert(not ok, 'last_message proc returns -1')
        m = tostring(e)
        assert(m:find('erg: ', 1, true), 'composed prefix present, got: ' .. m)
        assert(m:find('Duplicate', 1, true), 'composed message includes the host text')

        -- err.lastError reads the host's last error back: the duplicate-key insert's
        -- code (ER_TUPLE_FOUND = box.error.TUPLE_FOUND = 3); the proc also asserts the
        -- message is non-empty.
        assert(call('erg_last_error') == box.error.TUPLE_FOUND, 'erg_last_error code')
        ok, e = pcall(function() return call('erg_raw_nospace') end)
        assert(not ok, 'exportRaw nospace should fail')
        m = tostring(e)
        assert(m:find('NoSuchSpace', 1, true), 'expected NoSuchSpace, got: ' .. m)

        -- exportRaw keeps the host message on a BoxOp.
        ok, e = pcall(function() return call('erg_raw_dupkey') end)
        assert(not ok, 'exportRaw dupkey should fail')
        m = tostring(e)
        assert(m:find('Duplicate', 1, true), 'expected host Duplicate message, got: ' .. m)
    end)
end
