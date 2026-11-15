-- Migrated from test/integration/leaderboard.lua: a secondary index over
-- scores, read with max / count / a descending range select.
local t = require('luatest')
local helper = require('helper')

local g = t.group('leaderboard')

g.before_all(function()
    g.server = helper.start('leaderboard')
end)

g.after_all(function()
    g.server:drop()
end)

g.test_leaderboard = function()
    g.server:exec(function()
        local scores = box.schema.space.create('scores', { if_not_exists = true })
        scores:format({ { name = 'player', type = 'string' }, { name = 'score', type = 'integer' } })
        scores:create_index('pk', { parts = { { 1, 'string' } }, if_not_exists = true })
        scores:create_index('by_score', { parts = { { 2, 'integer' } }, unique = false, if_not_exists = true })

        for _, fn in ipairs({ 'lb_submit', 'lb_rank', 'lb_top_player', 'lb_top_n' }) do
            box.schema.func.create('leaderboard.' .. fn, { language = 'C', if_not_exists = true })
        end
        local function call(fn, ...) return box.func['leaderboard.' .. fn]:call({ ... }) end

        call('lb_submit', 'alice', 50)
        call('lb_submit', 'bob', 90)
        call('lb_submit', 'carol', 70)
        call('lb_submit', 'dave', 30)

        -- Highest scorer via the secondary-index max.
        assert(call('lb_top_player') == 'bob', 'top player is bob (90)')

        -- Rank = 1 + players scoring strictly higher (count over the `gt` iterator).
        assert(call('lb_rank', 90) == 1, 'score 90 ranks first')
        assert(call('lb_rank', 70) == 2, 'score 70 ranks second')
        assert(call('lb_rank', 30) == 4, 'score 30 ranks last')

        -- Descending range select: the top 3 players by score.
        local top3 = call('lb_top_n', 3)
        assert(#top3 == 3, 'top_n returns 3 names')
        assert(top3[1] == 'bob' and top3[2] == 'carol' and top3[3] == 'alice', 'top 3 in descending score order')

        -- An empty leaderboard yields nil for top_player.
        scores:truncate()
        assert(call('lb_top_player') == nil, 'empty leaderboard has no top player')
    end)
end
