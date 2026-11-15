#!/usr/bin/env tarantool
-- Standalone demo for the KV example module.
-- First build it:  zig build modules   (produces zig-out/lib/kv.so,
--                                      zig-out/lib/kv.dylib on macOS)
-- Then run:        tarantool examples/kv/init.lua

local ext = require('tarantool').build.mod_format -- 'so', or 'dylib' on macOS
package.cpath = './zig-out/lib/?.' .. ext .. ';' .. package.cpath

os.execute('mkdir -p ./zig-out/tt-kv-demo')
box.cfg{ memtx_dir = './zig-out/tt-kv-demo', wal_dir = './zig-out/tt-kv-demo' }

local s = box.schema.space.create('kv', { if_not_exists = true })
s:format({ { name = 'key', type = 'string' }, { name = 'value', type = 'string' } })
s:create_index('pk', { parts = { { 1, 'string' } }, if_not_exists = true })

for _, fn in ipairs({ 'kv_set', 'kv_get', 'kv_del' }) do
    box.schema.func.create('kv.' .. fn, { language = 'C', if_not_exists = true })
end

box.func['kv.kv_set']:call{ 'lang', 'zig' }
print('kv_get(lang) =', box.func['kv.kv_get']:call{ 'lang' })
box.func['kv.kv_del']:call{ 'lang' }
print('kv_get(lang) after del =', box.func['kv.kv_get']:call{ 'lang' })

os.exit(0)
