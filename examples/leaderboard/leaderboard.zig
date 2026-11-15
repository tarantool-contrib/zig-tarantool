//! Example Tarantool C module: a leaderboard over a `scores` space
//! (`{player: string, score: integer}`) with a non-unique secondary index
//! `by_score`. Demonstrates **index iteration** — `max`, `count` with an
//! iterator type, and a descending range `select` to read the top N.
//!
//! `lb_top_n` is a *raw* proc: it reads the top N via `Index.top` — a typed,
//! auto-freeing cursor that decodes each tuple and copies its strings out of the
//! borrowed host tuple before release — then returns the names as a MessagePack
//! array, so no host memory escapes.
//!
//! Build into `leaderboard.so`; see test/integration/leaderboard.lua.

const std = @import("std");
const t = @import("tarantool");
const box = t.box;
const query = t.query;
const proc = t.proc;
const msgpack = t.msgpack;
const c = t.c;

const Error = error{ NoScore, BadRow };

/// lb_submit(player, score): record or overwrite a player's score. Typed proc.
fn lbSubmit(player: []const u8, score: i64) !void {
    const scores = try box.Space.byName("scores");
    if (try scores.replace(.{ player, score })) |row| row.deinit();
}

/// lb_rank(score) -> i64: 1-based rank a player with `score` would hold — one
/// more than the number of players scoring strictly higher. Shows `count` over
/// the `gt` iterator on the secondary index.
fn lbRank(score: i64) !i64 {
    const scores = try box.Space.byName("scores");
    const by_score = try scores.index("by_score");
    const higher = try by_score.count(.gt, .{score});
    return @intCast(higher + 1);
}

/// lb_top_player() -> string | nil. The highest scorer's name via the secondary
/// index `max` (raw proc via `exportRaw`: the tuple is borrowed, so we read
/// field 0 and encode the result before releasing it — the kv_get pattern).
fn lbTopPlayer(
    ctx: ?*c.box_function_ctx_t,
    args: [*c]const u8,
    args_end: [*c]const u8,
) !c_int {
    _ = args;
    _ = args_end;

    const scores = try box.Space.byName("scores");
    const by_score = try scores.index("by_score");
    const maybe = try by_score.max(.{});

    if (maybe) |row| {
        defer row.deinit();
        if (try row.field(0, std.heap.c_allocator)) |v| return proc.returnValue(ctx, v);
        return Error.BadRow; // a max() row with no player field
    }
    return proc.returnValue(ctx, @as(?u8, null)); // nil: empty leaderboard
}

/// lb_top_n(n) -> [player, ...]. The top `n` players by score, descending. Raw
/// proc via `exportRaw`: `Index.top` returns an `alloc`-owned `[]Row` whose names
/// are already copied out of the host tuples, so nothing borrows host memory past
/// the tuple's lifetime; the player names encode as a MessagePack array of str.
fn lbTopN(
    ctx: ?*c.box_function_ctx_t,
    args: [*c]const u8,
    args_end: [*c]const u8,
) !c_int {
    const len = @intFromPtr(args_end) - @intFromPtr(args);
    var dec = msgpack.Decoder.init(args[0..len]);
    const parsed = try msgpack.decode(struct { i64 }, &dec);
    const n: u32 = if (parsed[0] < 0) 0 else @intCast(parsed[0]);

    const scores = try box.Space.byName("scores");
    const by_score = try scores.index("by_score");

    // Declaration order == space format: player (string), then score (integer).
    const Row = struct { player: []const u8, score: i64 };
    const a = std.heap.c_allocator;

    // Empty key + `le` iterator = every tuple in descending key (score) order.
    const rows = try by_score.top(n, Row, a);
    defer box.Range(Row).freeSlice(rows, a);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(a);
    for (rows) |row| {
        try names.append(a, row.player);
    }

    return proc.returnValue(ctx, names.items); // [][]const u8 -> array of str
}

comptime {
    proc.exportProc("lb_submit", lbSubmit);
    proc.exportProc("lb_rank", lbRank);
    proc.exportRaw("lb_top_player", lbTopPlayer);
    proc.exportRaw("lb_top_n", lbTopN);
}
