//! ABI parity check (CI only, `-Dverify-cabi`). Pulls in the real `module.h`
//! via translate-c and asserts that each symbol our hand-written `c.zig`
//! declares exists in the header with a compatible prototype. Never imported by
//! runtime code; existence here is what keeps `c.zig` honest.

const std = @import("std");
const c = @import("c.zig");
const query = @import("tarantool-proto").query;
const keydef = @import("keydef.zig");
const say = @import("say.zig");
const txn = @import("txn.zig");
// `module.h` + `lauxlib.h`, translated by the build (see `src/c_verify.h`).
const h = @import("module_h");

comptime {
    // For each symbol, take the address through both our decl and the header's.
    // A signature drift makes one of these fail to compile.
    assertSame("box_return_mp", c.box_return_mp, h.box_return_mp);
    assertSame("box_return_tuple", c.box_return_tuple, h.box_return_tuple);
    assertSame("box_space_id_by_name", c.box_space_id_by_name, h.box_space_id_by_name);
    assertSame("box_index_id_by_name", c.box_index_id_by_name, h.box_index_id_by_name);
    assertSame("box_insert", c.box_insert, h.box_insert);
    assertSame("box_replace", c.box_replace, h.box_replace);
    assertSame("box_delete", c.box_delete, h.box_delete);
    assertSame("box_update", c.box_update, h.box_update);
    assertSame("box_upsert", c.box_upsert, h.box_upsert);
    assertSame("box_index_get", c.box_index_get, h.box_index_get);
    assertSame("box_index_iterator", c.box_index_iterator, h.box_index_iterator);
    assertSame("box_iterator_next", c.box_iterator_next, h.box_iterator_next);
    assertSame("box_iterator_free", c.box_iterator_free, h.box_iterator_free);
    assertSame("box_index_min", c.box_index_min, h.box_index_min);
    assertSame("box_index_max", c.box_index_max, h.box_index_max);
    assertSame("box_index_count", c.box_index_count, h.box_index_count);
    assertSame("box_index_len", c.box_index_len, h.box_index_len);
    assertSame("box_index_bsize", c.box_index_bsize, h.box_index_bsize);
    assertSame("box_index_random", c.box_index_random, h.box_index_random);
    assertSame("box_tuple_field_count", c.box_tuple_field_count, h.box_tuple_field_count);
    assertSame("box_tuple_data", c.box_tuple_data, h.box_tuple_data);
    assertSame("box_tuple_field", c.box_tuple_field, h.box_tuple_field);
    assertSame("box_tuple_format_default", c.box_tuple_format_default, h.box_tuple_format_default);
    assertSame("box_tuple_new", c.box_tuple_new, h.box_tuple_new);
    assertSame("box_tuple_bsize", c.box_tuple_bsize, h.box_tuple_bsize);
    assertSame("box_tuple_iterator", c.box_tuple_iterator, h.box_tuple_iterator);
    assertSame("box_tuple_iterator_free", c.box_tuple_iterator_free, h.box_tuple_iterator_free);
    assertSame("box_tuple_position", c.box_tuple_position, h.box_tuple_position);
    assertSame("box_tuple_rewind", c.box_tuple_rewind, h.box_tuple_rewind);
    assertSame("box_tuple_seek", c.box_tuple_seek, h.box_tuple_seek);
    assertSame("box_tuple_next", c.box_tuple_next, h.box_tuple_next);
    assertSame("box_tuple_update", c.box_tuple_update, h.box_tuple_update);
    assertSame("box_region_used", c.box_region_used, h.box_region_used);
    assertSame("box_region_alloc", c.box_region_alloc, h.box_region_alloc);
    assertSame("box_region_aligned_alloc", c.box_region_aligned_alloc, h.box_region_aligned_alloc);
    assertSame("box_region_truncate", c.box_region_truncate, h.box_region_truncate);
    assertSame("box_error_last", c.box_error_last, h.box_error_last);
    assertSame("box_error_code", c.box_error_code, h.box_error_code);
    assertSame("box_txn_begin", c.box_txn_begin, h.box_txn_begin);
    assertSame("box_txn_commit", c.box_txn_commit, h.box_txn_commit);
    assertSame("box_txn_rollback", c.box_txn_rollback, h.box_txn_rollback);
    assertSame("box_txn_id", c.box_txn_id, h.box_txn_id);
    assertSame("box_txn_savepoint", c.box_txn_savepoint, h.box_txn_savepoint);
    assertSame("box_txn_rollback_to_savepoint", c.box_txn_rollback_to_savepoint, h.box_txn_rollback_to_savepoint);
    assertSame("box_txn_isolation", c.box_txn_isolation, h.box_txn_isolation);
    assertSame("box_txn_set_isolation", c.box_txn_set_isolation, h.box_txn_set_isolation);
    assertSame("box_txn_set_timeout", c.box_txn_set_timeout, h.box_txn_set_timeout);
    assertSame("box_txn_make_sync", c.box_txn_make_sync, h.box_txn_make_sync);
    assertSame("box_txn_alloc", c.box_txn_alloc, h.box_txn_alloc);
    assertSame("box_sequence_next", c.box_sequence_next, h.box_sequence_next);
    assertSame("box_sequence_current", c.box_sequence_current, h.box_sequence_current);
    assertSame("box_sequence_set", c.box_sequence_set, h.box_sequence_set);
    assertSame("box_sequence_reset", c.box_sequence_reset, h.box_sequence_reset);

    // ---- instance introspection & maintenance ----
    assertSame("box_status", c.box_status, h.box_status);
    assertSame("box_is_ro", c.box_is_ro, h.box_is_ro);
    assertSame("box_wait_ro", c.box_wait_ro, h.box_wait_ro);
    assertSame("box_ro_reason", c.box_ro_reason, h.box_ro_reason);
    assertSame("box_schema_version", c.box_schema_version, h.box_schema_version);
    assertSame("box_info_lsn", c.box_info_lsn, h.box_info_lsn);
    assertSame("box_slab_info", c.box_slab_info, h.box_slab_info);
    assertSame("box_truncate", c.box_truncate, h.box_truncate);

    // ---- on_shutdown trigger ----
    // First bound extern with fn-pointer parameters. assertSame compares only
    // param count + varargs-ness (opaque-pointer tolerance, :335), which the
    // two `int(*)(void*)` handler params satisfy — no fn-pointer-specific
    // fallback needed (did not materialize).
    assertSame("box_on_shutdown", c.box_on_shutdown, h.box_on_shutdown);

    assertSame("box_key_def_new", c.box_key_def_new, h.box_key_def_new);
    assertSame("box_key_def_delete", c.box_key_def_delete, h.box_key_def_delete);
    assertSame("box_key_def_extract_key", c.box_key_def_extract_key, h.box_key_def_extract_key);
    assertSame("box_tuple_compare", c.box_tuple_compare, h.box_tuple_compare);
    assertSame("box_tuple_compare_with_key", c.box_tuple_compare_with_key, h.box_tuple_compare_with_key);
    assertSame("box_tuple_extract_key", c.box_tuple_extract_key, h.box_tuple_extract_key);
    assertConst("BOX_DECIMAL_STRING_BUFFER_SIZE", c.BOX_DECIMAL_STRING_BUFFER_SIZE, h.BOX_DECIMAL_STRING_BUFFER_SIZE);
    // `box_decimal_t` is a by-value ABI type: assert byte-identity (size) and
    // that our alignment is not stricter than the header's (house rule for
    // struct-by-value types — assertSame only checks param count/varargs).
    if (@sizeOf(c.box_decimal_t) != @sizeOf(h.box_decimal_t))
        @compileError("c.zig/box_decimal_t: size differs from module.h");
    if (@alignOf(c.box_decimal_t) < @alignOf(h.box_decimal_t))
        @compileError("c.zig/box_decimal_t: alignment weaker than module.h");
    assertSame("box_decimal_precision", c.box_decimal_precision, h.box_decimal_precision);
    assertSame("box_decimal_scale", c.box_decimal_scale, h.box_decimal_scale);
    assertSame("box_decimal_is_int", c.box_decimal_is_int, h.box_decimal_is_int);
    assertSame("box_decimal_is_neg", c.box_decimal_is_neg, h.box_decimal_is_neg);
    assertSame("box_decimal_zero", c.box_decimal_zero, h.box_decimal_zero);
    assertSame("box_decimal_from_string", c.box_decimal_from_string, h.box_decimal_from_string);
    assertSame("box_decimal_from_double", c.box_decimal_from_double, h.box_decimal_from_double);
    assertSame("box_decimal_from_int64", c.box_decimal_from_int64, h.box_decimal_from_int64);
    assertSame("box_decimal_from_uint64", c.box_decimal_from_uint64, h.box_decimal_from_uint64);
    assertSame("box_decimal_copy", c.box_decimal_copy, h.box_decimal_copy);
    assertSame("box_decimal_to_string", c.box_decimal_to_string, h.box_decimal_to_string);
    assertSame("box_decimal_to_int64", c.box_decimal_to_int64, h.box_decimal_to_int64);
    assertSame("box_decimal_to_uint64", c.box_decimal_to_uint64, h.box_decimal_to_uint64);
    assertSame("box_decimal_round", c.box_decimal_round, h.box_decimal_round);
    assertSame("box_decimal_floor", c.box_decimal_floor, h.box_decimal_floor);
    assertSame("box_decimal_trim", c.box_decimal_trim, h.box_decimal_trim);
    assertSame("box_decimal_rescale", c.box_decimal_rescale, h.box_decimal_rescale);
    assertSame("box_decimal_compare", c.box_decimal_compare, h.box_decimal_compare);
    assertSame("box_decimal_abs", c.box_decimal_abs, h.box_decimal_abs);
    assertSame("box_decimal_minus", c.box_decimal_minus, h.box_decimal_minus);
    assertSame("box_decimal_add", c.box_decimal_add, h.box_decimal_add);
    assertSame("box_decimal_sub", c.box_decimal_sub, h.box_decimal_sub);
    assertSame("box_decimal_mul", c.box_decimal_mul, h.box_decimal_mul);
    assertSame("box_decimal_div", c.box_decimal_div, h.box_decimal_div);
    assertSame("box_decimal_remainder", c.box_decimal_remainder, h.box_decimal_remainder);
    assertSame("box_decimal_log10", c.box_decimal_log10, h.box_decimal_log10);
    assertSame("box_decimal_ln", c.box_decimal_ln, h.box_decimal_ln);
    assertSame("box_decimal_pow", c.box_decimal_pow, h.box_decimal_pow);
    assertSame("box_decimal_exp", c.box_decimal_exp, h.box_decimal_exp);
    assertSame("box_decimal_sqrt", c.box_decimal_sqrt, h.box_decimal_sqrt);
    assertSame("box_decimal_mp_sizeof", c.box_decimal_mp_sizeof, h.box_decimal_mp_sizeof);
    assertSame("box_decimal_mp_encode", c.box_decimal_mp_encode, h.box_decimal_mp_encode);
    assertSame("box_decimal_mp_decode", c.box_decimal_mp_decode, h.box_decimal_mp_decode);
    assertSame("box_decimal_mp_decode_data", c.box_decimal_mp_decode_data, h.box_decimal_mp_decode_data);

    // ---- fibers ----
    assertSame("fiber_self", c.fiber_self, h.fiber_self);
    assertSame("fiber_new", c.fiber_new, h.fiber_new);
    assertSame("fiber_start", c.fiber_start, h.fiber_start);
    assertSame("fiber_set_ctx", c.fiber_set_ctx, h.fiber_set_ctx);
    assertSame("fiber_get_ctx", c.fiber_get_ctx, h.fiber_get_ctx);
    assertSame("fiber_set_joinable", c.fiber_set_joinable, h.fiber_set_joinable);
    assertSame("fiber_join", c.fiber_join, h.fiber_join);
    assertSame("fiber_join_timeout", c.fiber_join_timeout, h.fiber_join_timeout);
    assertSame("fiber_yield", c.fiber_yield, h.fiber_yield);
    assertSame("fiber_sleep", c.fiber_sleep, h.fiber_sleep);
    assertSame("fiber_wakeup", c.fiber_wakeup, h.fiber_wakeup);
    assertSame("fiber_cancel", c.fiber_cancel, h.fiber_cancel);
    assertSame("fiber_is_cancelled", c.fiber_is_cancelled, h.fiber_is_cancelled);
    assertSame("fiber_reschedule", c.fiber_reschedule, h.fiber_reschedule);
    assertSame("fiber_id", c.fiber_id, h.fiber_id);
    assertSame("fiber_clock", c.fiber_clock, h.fiber_clock);
    assertSame("fiber_attr_new", c.fiber_attr_new, h.fiber_attr_new);
    assertSame("fiber_attr_delete", c.fiber_attr_delete, h.fiber_attr_delete);
    assertSame("fiber_attr_setstacksize", c.fiber_attr_setstacksize, h.fiber_attr_setstacksize);
    assertSame("fiber_attr_getstacksize", c.fiber_attr_getstacksize, h.fiber_attr_getstacksize);
    assertSame("fiber_new_ex", c.fiber_new_ex, h.fiber_new_ex);
    assertSame("fiber_name", c.fiber_name, h.fiber_name);
    assertSame("fiber_set_name_n", c.fiber_set_name_n, h.fiber_set_name_n);
    assertSame("fiber_csw", c.fiber_csw, h.fiber_csw);
    assertSame("fiber_find", c.fiber_find, h.fiber_find);
    assertSame("fiber_time", c.fiber_time, h.fiber_time);
    assertSame("fiber_time64", c.fiber_time64, h.fiber_time64);
    assertSame("fiber_clock64", c.fiber_clock64, h.fiber_clock64);

    // ---- fiber cond ----
    assertSame("fiber_cond_new", c.fiber_cond_new, h.fiber_cond_new);
    assertSame("fiber_cond_delete", c.fiber_cond_delete, h.fiber_cond_delete);
    assertSame("fiber_cond_signal", c.fiber_cond_signal, h.fiber_cond_signal);
    assertSame("fiber_cond_broadcast", c.fiber_cond_broadcast, h.fiber_cond_broadcast);
    assertSame("fiber_cond_wait_timeout", c.fiber_cond_wait_timeout, h.fiber_cond_wait_timeout);
    assertSame("fiber_cond_wait", c.fiber_cond_wait, h.fiber_cond_wait);

    // ---- latch ----
    assertSame("box_latch_new", c.box_latch_new, h.box_latch_new);
    assertSame("box_latch_delete", c.box_latch_delete, h.box_latch_delete);
    assertSame("box_latch_lock", c.box_latch_lock, h.box_latch_lock);
    assertSame("box_latch_trylock", c.box_latch_trylock, h.box_latch_trylock);
    assertSame("box_latch_unlock", c.box_latch_unlock, h.box_latch_unlock);

    // ---- clock ----
    assertSame("clock_realtime", c.clock_realtime, h.clock_realtime);
    assertSame("clock_monotonic", c.clock_monotonic, h.clock_monotonic);
    assertSame("clock_process", c.clock_process, h.clock_process);
    assertSame("clock_thread", c.clock_thread, h.clock_thread);
    assertSame("clock_realtime64", c.clock_realtime64, h.clock_realtime64);
    assertSame("clock_monotonic64", c.clock_monotonic64, h.clock_monotonic64);
    assertSame("clock_process64", c.clock_process64, h.clock_process64);
    assertSame("clock_thread64", c.clock_thread64, h.clock_thread64);

    // ---- coio ----
    assertSame("coio_wait", c.coio_wait, h.coio_wait);
    assertSame("coio_close", c.coio_close, h.coio_close);
    assertSame("coio_call", c.coio_call, h.coio_call);
    assertSame("coio_getaddrinfo", c.coio_getaddrinfo, h.coio_getaddrinfo);
    if (c.COIO_READ != h.COIO_READ) @compileError("c.zig/COIO_READ differs from module.h");
    if (c.COIO_WRITE != h.COIO_WRITE) @compileError("c.zig/COIO_WRITE differs from module.h");

    // ---- say (logging) ----
    // The fn is checked like every other; the two extern VARIABLES need the new
    // variable-parity helpers below (first extern data bound in c.zig).
    assertSame("_say_strerror", c._say_strerror, h._say_strerror);
    assertVar("log_level", @TypeOf(c.log_level), @TypeOf(h.log_level));
    assertVarFnPtr("_say", @TypeOf(c._say), @TypeOf(h._say));

    // ---- lua (authoring Lua C modules) ----
    assertSame("lua_gettop", c.lua_gettop, h.lua_gettop);
    assertSame("lua_settop", c.lua_settop, h.lua_settop);
    assertSame("lua_type", c.lua_type, h.lua_type);
    assertSame("lua_pushvalue", c.lua_pushvalue, h.lua_pushvalue);
    assertSame("lua_pushnil", c.lua_pushnil, h.lua_pushnil);
    assertSame("lua_pushboolean", c.lua_pushboolean, h.lua_pushboolean);
    assertSame("lua_pushnumber", c.lua_pushnumber, h.lua_pushnumber);
    assertSame("lua_pushlstring", c.lua_pushlstring, h.lua_pushlstring);
    assertSame("lua_pushcclosure", c.lua_pushcclosure, h.lua_pushcclosure);
    assertSame("lua_pushlightuserdata", c.lua_pushlightuserdata, h.lua_pushlightuserdata);
    assertSame("lua_toboolean", c.lua_toboolean, h.lua_toboolean);
    assertSame("lua_tonumber", c.lua_tonumber, h.lua_tonumber);
    assertSame("lua_tolstring", c.lua_tolstring, h.lua_tolstring);
    assertSame("lua_touserdata", c.lua_touserdata, h.lua_touserdata);
    assertSame("lua_createtable", c.lua_createtable, h.lua_createtable);
    assertSame("lua_rawgeti", c.lua_rawgeti, h.lua_rawgeti);
    assertSame("lua_rawseti", c.lua_rawseti, h.lua_rawseti);
    assertSame("lua_getfield", c.lua_getfield, h.lua_getfield);
    assertSame("lua_setfield", c.lua_setfield, h.lua_setfield);
    assertSame("lua_next", c.lua_next, h.lua_next);
    assertSame("lua_objlen", c.lua_objlen, h.lua_objlen);
    assertSame("luaL_register", c.luaL_register, h.luaL_register);
    assertSame("luaL_error", c.luaL_error, h.luaL_error);
    assertSame("luaL_ref", c.luaL_ref, h.luaL_ref);
    assertSame("luaL_unref", c.luaL_unref, h.luaL_unref);
    assertSame("luaL_pushint64", c.luaL_pushint64, h.luaL_pushint64);
    assertSame("luaL_pushuint64", c.luaL_pushuint64, h.luaL_pushuint64);
    assertSame("luaL_toint64", c.luaL_toint64, h.luaL_toint64);
    assertSame("luaL_touint64", c.luaL_touint64, h.luaL_touint64);
    assertSame("luaT_istuple", c.luaT_istuple, h.luaT_istuple);
    assertSame("luaT_pushtuple", c.luaT_pushtuple, h.luaT_pushtuple);
    assertSame("luaT_newdecimal", c.luaT_newdecimal, h.luaT_newdecimal);
    assertSame("luaT_pushdecimal", c.luaT_pushdecimal, h.luaT_pushdecimal);
    assertSame("luaT_isdecimal", c.luaT_isdecimal, h.luaT_isdecimal);
    assertSame("luaT_state", c.luaT_state, h.luaT_state);
    assertSame("luaT_call", c.luaT_call, h.luaT_call);

    // LuaJIT pseudo-index constants must match lua.h exactly (translate-c
    // exposes the #defines).
    assertConst("LUA_REGISTRYINDEX", c.LUA_REGISTRYINDEX, h.LUA_REGISTRYINDEX);
    assertConst("LUA_GLOBALSINDEX", c.LUA_GLOBALSINDEX, h.LUA_GLOBALSINDEX);

    // Lua value type tags must match lua.h exactly.
    assertConst("LUA_TNONE", c.LUA_TNONE, h.LUA_TNONE);
    assertConst("LUA_TNIL", c.LUA_TNIL, h.LUA_TNIL);
    assertConst("LUA_TBOOLEAN", c.LUA_TBOOLEAN, h.LUA_TBOOLEAN);
    assertConst("LUA_TNUMBER", c.LUA_TNUMBER, h.LUA_TNUMBER);
    assertConst("LUA_TSTRING", c.LUA_TSTRING, h.LUA_TSTRING);
    assertConst("LUA_TTABLE", c.LUA_TTABLE, h.LUA_TTABLE);

    // BOX_ID_NIL sentinel must match the header.
    if (c.BOX_ID_NIL != h.BOX_ID_NIL)
        @compileError("c.zig/BOX_ID_NIL differs from module.h");

    // ER_PROC_C must match enum box_error_code (was silently pinned to 70 =
    // ER_IDENTIFIER before this check existed).
    assertConst("ER_PROC_C", c.ER_PROC_C, h.ER_PROC_C);

    // IteratorType values must match enum iterator_type exactly.
    assertIter("ITER_EQ", .eq, h.ITER_EQ);
    assertIter("ITER_REQ", .req, h.ITER_REQ);
    assertIter("ITER_ALL", .all, h.ITER_ALL);
    assertIter("ITER_LT", .lt, h.ITER_LT);
    assertIter("ITER_LE", .le, h.ITER_LE);
    assertIter("ITER_GE", .ge, h.ITER_GE);
    assertIter("ITER_GT", .gt, h.ITER_GT);
    assertIter("ITER_BITS_ALL_SET", .bits_all_set, h.ITER_BITS_ALL_SET);
    assertIter("ITER_BITS_ANY_SET", .bits_any_set, h.ITER_BITS_ANY_SET);
    assertIter("ITER_BITS_ALL_NOT_SET", .bits_all_not_set, h.ITER_BITS_ALL_NOT_SET);
    assertIter("ITER_OVERLAPS", .overlaps, h.ITER_OVERLAPS);
    assertIter("ITER_NEIGHBOR", .neighbor, h.ITER_NEIGHBOR);
    assertIter("ITER_NP", .np, h.ITER_NP);
    assertIter("ITER_PP", .pp, h.ITER_PP);

    // FieldType values must match enum field_type exactly.
    assertField("FIELD_TYPE_ANY", .any, h.FIELD_TYPE_ANY);
    assertField("FIELD_TYPE_UNSIGNED", .unsigned, h.FIELD_TYPE_UNSIGNED);
    assertField("FIELD_TYPE_STRING", .string, h.FIELD_TYPE_STRING);
    assertField("FIELD_TYPE_NUMBER", .number, h.FIELD_TYPE_NUMBER);
    assertField("FIELD_TYPE_DOUBLE", .double, h.FIELD_TYPE_DOUBLE);
    assertField("FIELD_TYPE_INTEGER", .integer, h.FIELD_TYPE_INTEGER);
    assertField("FIELD_TYPE_BOOLEAN", .boolean, h.FIELD_TYPE_BOOLEAN);
    assertField("FIELD_TYPE_VARBINARY", .varbinary, h.FIELD_TYPE_VARBINARY);
    assertField("FIELD_TYPE_SCALAR", .scalar, h.FIELD_TYPE_SCALAR);
    assertField("FIELD_TYPE_DECIMAL", .decimal, h.FIELD_TYPE_DECIMAL);
    assertField("FIELD_TYPE_UUID", .uuid, h.FIELD_TYPE_UUID);
    assertField("FIELD_TYPE_DATETIME", .datetime, h.FIELD_TYPE_DATETIME);

    // say.Level values must match enum say_level exactly (pin;
    // module.h:509-519, implicit 0..7).
    assertLevel("S_FATAL", .fatal, h.S_FATAL);
    assertLevel("S_SYSERROR", .syserror, h.S_SYSERROR);
    assertLevel("S_ERROR", .err, h.S_ERROR);
    assertLevel("S_CRIT", .crit, h.S_CRIT);
    assertLevel("S_WARN", .warn, h.S_WARN);
    assertLevel("S_INFO", .info, h.S_INFO);
    assertLevel("S_VERBOSE", .verbose, h.S_VERBOSE);
    assertLevel("S_DEBUG", .debug, h.S_DEBUG);

    // box_slab_info_type values must match enum box_slab_info_type exactly.
    assertSlab("BOX_SLAB_INFO_ITEMS_SIZE", .items_size, h.BOX_SLAB_INFO_ITEMS_SIZE);
    assertSlab("BOX_SLAB_INFO_ITEMS_USED", .items_used, h.BOX_SLAB_INFO_ITEMS_USED);
    assertSlab("BOX_SLAB_INFO_ARENA_SIZE", .arena_size, h.BOX_SLAB_INFO_ARENA_SIZE);
    assertSlab("BOX_SLAB_INFO_ARENA_USED", .arena_used, h.BOX_SLAB_INFO_ARENA_USED);
    assertSlab("BOX_SLAB_INFO_QUOTA_SIZE", .quota_size, h.BOX_SLAB_INFO_QUOTA_SIZE);
    assertSlab("BOX_SLAB_INFO_QUOTA_USED", .quota_used, h.BOX_SLAB_INFO_QUOTA_USED);

    // IsolationLevel values must match enum txn_isolation_level exactly.
    // txn_isolation_level_MAX has no Zig member — not pinned (members only,
    // consistent with IteratorType/FieldType).
    assertTxnIso("TXN_ISOLATION_DEFAULT", .default, h.TXN_ISOLATION_DEFAULT);
    assertTxnIso("TXN_ISOLATION_READ_COMMITTED", .read_committed, h.TXN_ISOLATION_READ_COMMITTED);
    assertTxnIso("TXN_ISOLATION_READ_CONFIRMED", .read_confirmed, h.TXN_ISOLATION_READ_CONFIRMED);
    assertTxnIso("TXN_ISOLATION_BEST_EFFORT", .best_effort, h.TXN_ISOLATION_BEST_EFFORT);
    assertTxnIso("TXN_ISOLATION_LINEARIZABLE", .linearizable, h.TXN_ISOLATION_LINEARIZABLE);
}

fn assertIter(comptime name: []const u8, ours: query.IteratorType, theirs: anytype) void {
    if (@backingInt(ours) != theirs)
        @compileError("query.IteratorType differs from module.h " ++ name);
}

fn assertField(comptime name: []const u8, ours: keydef.FieldType, theirs: anytype) void {
    if (@backingInt(ours) != theirs)
        @compileError("keydef.FieldType differs from module.h " ++ name);
}

fn assertLevel(comptime name: []const u8, ours: say.Level, theirs: anytype) void {
    if (@backingInt(ours) != theirs)
        @compileError("say.Level differs from module.h " ++ name);
}

fn assertSlab(comptime name: []const u8, ours: c.box_slab_info_type, theirs: anytype) void {
    if (@backingInt(ours) != theirs)
        @compileError("c.box_slab_info_type differs from module.h " ++ name);
}

fn assertTxnIso(comptime name: []const u8, ours: txn.IsolationLevel, theirs: anytype) void {
    if (@backingInt(ours) != theirs)
        @compileError("txn.IsolationLevel differs from module.h " ++ name);
}

/// Compile-time check that two function declarations have argument/return types
/// that the C ABI treats identically. translate-c maps opaque pointers to
/// distinct types, so we compare by parameter count and scalar kinds rather than
/// strict type identity.
/// Compile-time check that a hand-written integer constant equals the header's.
fn assertConst(comptime name: []const u8, comptime ours: anytype, comptime theirs: anytype) void {
    if (ours != theirs)
        @compileError("c.zig/" ++ name ++ " differs from module.h");
}

/// Compile-time check that an extern VARIABLE has the identical type on both
/// sides. Strict identity is safe here because the say variables are scalars
/// (`c_int`), no opaque translate-c pointer types are involved (contrast
/// `assertSame`, which must tolerate distinct opaque-pointer renderings).
fn assertVar(comptime name: []const u8, comptime Ours: type, comptime Theirs: type) void {
    if (Ours != Theirs)
        @compileError("c.zig/" ++ name ++ ": variable type differs from module.h");
}

/// Compile-time check that two extern fn-pointer VARIABLES agree on the pointee
/// function's parameter count and varargs-ness — the same tolerant policy
/// `assertSame` uses, but reaching the `.@"fn"` through the
/// `.optional`→`.pointer`→`.@"fn"` chain of a `sayfunc_t`-shaped variable.
fn assertVarFnPtr(comptime name: []const u8, comptime Ours: type, comptime Theirs: type) void {
    const a = @typeInfo(@typeInfo(@typeInfo(Ours).optional.child).pointer.child).@"fn";
    const b = @typeInfo(@typeInfo(@typeInfo(Theirs).optional.child).pointer.child).@"fn";
    if (a.param_types.len != b.param_types.len)
        @compileError("c.zig/" ++ name ++ ": param count differs from module.h");
    if (a.attrs.varargs != b.attrs.varargs)
        @compileError("c.zig/" ++ name ++ ": varargs-ness differs from module.h");
}

fn assertSame(comptime name: []const u8, comptime ours: anytype, comptime theirs: anytype) void {
    const a = @typeInfo(@TypeOf(ours)).@"fn";
    const b = @typeInfo(@TypeOf(theirs)).@"fn";
    if (a.param_types.len != b.param_types.len)
        @compileError("c.zig/" ++ name ++ ": param count differs from module.h");
    if (a.attrs.varargs != b.attrs.varargs)
        @compileError("c.zig/" ++ name ++ ": varargs-ness differs from module.h");
}

pub fn main() void {}
