-- Drives the proxy example (proxy.so): stored procedures that use
-- tarantool-client over tarantool.fiberio to reach a remote instance's `kv`
-- space. The "remote" is this same instance on an extra TCP listener, which
-- only works because the proc's fiber yields while it waits on the network.
local t = require('luatest')
local helper = require('helper')

local g = t.group('proxy')

g.before_all(function()
    g.server = helper.start('proxy')
    g.uri = g.server:exec(function()
        local kv = box.schema.space.create('kv', {
            format = { { name = 'key', type = 'string' }, { name = 'value', type = 'string' } },
            if_not_exists = true,
        })
        kv:create_index('pk', { parts = { 'key' }, if_not_exists = true })
        box.session.su('admin', box.schema.user.grant, 'guest', 'read,write', 'space', 'kv',
            { if_not_exists = true })

        for _, fn in ipairs({ 'put', 'get' }) do
            box.schema.func.create('proxy.' .. fn, { language = 'C', if_not_exists = true })
        end

        -- Keep luatest's own listener and add an ephemeral TCP one for the proc.
        local listen = {}
        local cur = box.cfg.listen
        if type(cur) == 'table' then
            for _, v in ipairs(cur) do listen[#listen + 1] = v end
        elseif cur ~= nil then
            listen[#listen + 1] = cur
        end
        listen[#listen + 1] = '127.0.0.1:0'
        box.cfg{ listen = listen }

        local bound = box.info.listen
        for _, u in ipairs(type(bound) == 'table' and bound or { bound }) do
            if not u:find('unix/', 1, true) then return u end
        end
        error('no TCP listener bound')
    end)
end)

g.after_all(function()
    g.server:drop()
end)

g.test_proxy = function()
    g.server:exec(function(uri)
        local t = require('luatest')
        local function call(fn, ...) return box.func['proxy.' .. fn]:call({ ... }) end

        -- A void proc returns no values (not an empty/garbage one).
        t.assert_equals({ call('put', uri, 'hello', 'world') }, {})
        t.assert_equals({ call('put', uri, 'hello', 'world') }, {})
        t.assert_equals(box.space.kv:get('hello'):totable(), { 'hello', 'world' })
        t.assert_equals(call('get', uri, 'hello'), 'world')
        t.assert_equals(call('get', uri, 'missing'), nil)

        -- A dead peer fails within the connect timeout instead of hanging.
        local ok, err = pcall(call, 'get', '127.0.0.1:1', 'hello')
        t.assert_not(ok, 'connect to a dead port fails')
        t.assert(err ~= nil)
    end, { g.uri })
end
