-- Drives the say logging module (say.so) end to end against a live Tarantool.
-- Each proc logs a unique marker; observation is runner-side via
-- `srv:grep_log` (a Lua-pattern search over the Server's own <alias>.log that
-- self-synchronizes by writing its own marker, so a positive grep does not race
-- the log pipe and a nil after it is a meaningful negative).
--
-- Coverage: every level lands with its severity tag (positive); a filtered
-- debug does NOT (negative); printf specifiers survive as literal data;
-- a >1 KiB line is truncated with `...` and the server survives;
-- sysError appends the strerror text; and std.log routes through the adapter.
local t = require('luatest')
local helper = require('helper')

local g = t.group('say')

g.before_all(function()
    g.server = helper.start('say')
end)

g.after_all(function()
    g.server:drop()
end)

g.test_say = function()
    local srv = g.server

    -- Phase 1: at log_level=7 (debug), every level is enabled. Register the
    -- procs and drive the positive + invariant cases.
    srv:exec(function()
        for _, fn in ipairs({
            'say_levels', 'say_enabled_debug', 'say_fmt_passthrough',
            'say_truncation', 'say_syserror', 'say_stdlog',
            'say_debug_filtered',
        }) do
            box.schema.func.create('say.' .. fn, { language = 'C', if_not_exists = true })
        end

        box.cfg{ log_level = 7 }

        local function call(fn) return box.func['say.' .. fn]:call({}) end

        -- log_level=7 reaches the C global our enabled() reads.
        assert(call('say_enabled_debug') == 1, 'debug enabled at log_level=7')

        assert(call('say_levels') == 1, 'say_levels ran')
        assert(call('say_fmt_passthrough') == 1, 'say_fmt_passthrough ran')
        assert(call('say_truncation') == 1, 'say_truncation ran')
        assert(call('say_syserror') == 1, 'say_syserror ran')
        assert(call('say_stdlog') == 1, 'say_stdlog ran')
    end)

    -- Runner-side log observation (Lua patterns; `%` and `.` are escaped).
    -- Each level marker with its severity tag.
    t.assert(srv:grep_log('E> .*ZIGSAY_ERR'), 'ERROR marker with E> tag')
    t.assert(srv:grep_log('C> .*ZIGSAY_CRIT'), 'CRIT marker with C> tag')
    t.assert(srv:grep_log('W> .*ZIGSAY_WARN'), 'WARN marker with W> tag')
    t.assert(srv:grep_log('I> .*ZIGSAY_INFO'), 'INFO marker with I> tag')
    t.assert(srv:grep_log('V> .*ZIGSAY_VERBOSE'), 'VERBOSE marker with V> tag')
    t.assert(srv:grep_log('D> .*ZIGSAY_DEBUG'), 'DEBUG marker with D> tag')

    -- printf specifiers survived verbatim as data.
    t.assert(srv:grep_log('ZIGSAY_FMT %%s %%d %%n'), 'printf specifiers logged as literal data')

    -- The >1 KiB line is present AND truncated with the `...` marker.
    t.assert(srv:grep_log('ZIGSAY_TRUNC A*%.%.%.'), 'oversized line truncated with ... marker')

    -- sysError appends the strerror text for errno 2 (ENOENT).
    t.assert(srv:grep_log('ZIGSAY_SYS.*No such file or directory'), 'sysError appended strerror')

    -- std.log routed through the adapter.
    t.assert(srv:grep_log('ZIGSAY_STDLOG'), 'std.log routed into the Tarantool log')

    -- Phase 2: lower the threshold to info; debug is now filtered.
    srv:exec(function()
        box.cfg{ log_level = 5 }
        assert(box.func['say.say_enabled_debug']:call({}) == 0, 'debug disabled at log_level=5')
        box.func['say.say_debug_filtered']:call({})
    end)

    -- Negative: the filtered debug marker must NOT appear (grep_log's self-marker
    -- sync makes the nil meaningful).
    t.assert_is(srv:grep_log('ZIGSAY_FILTERED'), nil, 'filtered debug did not reach the log')

    -- Tail: the server survived the 2 KiB line and is still responsive.
    assert(srv:exec(function() return 1 end) == 1, 'server alive after truncated line')
end
