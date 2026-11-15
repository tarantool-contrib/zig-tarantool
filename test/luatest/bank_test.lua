-- Migrated from test/integration/bank.lua: drives the bank example module
-- (bank.so): atomic transfers via txn.transaction, with rollback leaving no
-- partial write.
local t = require('luatest')
local helper = require('helper')

local g = t.group('bank')

g.before_all(function()
    g.server = helper.start('bank')
end)

g.after_all(function()
    g.server:drop()
end)

g.test_bank = function()
    g.server:exec(function()
        local accounts = box.schema.space.create('accounts', { if_not_exists = true })
        accounts:format({ { name = 'id', type = 'string' }, { name = 'balance', type = 'integer' } })
        accounts:create_index('pk', { parts = { { 1, 'string' } }, if_not_exists = true })

        for _, fn in ipairs({ 'bank_open', 'bank_balance', 'bank_transfer' }) do
            box.schema.func.create('bank.' .. fn, { language = 'C', if_not_exists = true })
        end
        local function call(fn, ...) return box.func['bank.' .. fn]:call({ ... }) end

        call('bank_open', 'alice', 100)
        call('bank_open', 'bob', 50)
        assert(call('bank_balance', 'alice') == 100, 'alice opened with 100')

        -- A valid transfer commits both legs.
        call('bank_transfer', 'alice', 'bob', 30)
        assert(call('bank_balance', 'alice') == 70, 'alice debited')
        assert(call('bank_balance', 'bob') == 80, 'bob credited')

        -- Insufficient funds: the pre-check fails, nothing is written.
        local ok = pcall(call, 'bank_transfer', 'alice', 'bob', 1000)
        assert(not ok, 'overdraft transfer is rejected')
        assert(call('bank_balance', 'alice') == 70, 'alice unchanged after overdraft')
        assert(call('bank_balance', 'bob') == 80, 'bob unchanged after overdraft')

        -- Missing destination: the debit happens then the credit fails, so the helper
        -- rolls the whole transaction back — alice keeps her balance.
        ok = pcall(call, 'bank_transfer', 'alice', 'charlie', 10)
        assert(not ok, 'transfer to a missing account is rejected')
        assert(call('bank_balance', 'alice') == 70, 'debit rolled back when credit failed')
    end)
end
