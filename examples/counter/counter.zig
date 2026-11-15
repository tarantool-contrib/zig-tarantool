//! Example Tarantool C module: an atomic counter and auto-incrementing ids
//! backed by a Tarantool **sequence** (`seq` module). Demonstrates the sequence
//! API — `next`/`current`/`set`/`reset` — and using a sequence to mint primary
//! keys for an append-only `events` space.
//!
//! Build into `counter.so`, then from Lua (see test/integration/counter.lua):
//!   box.schema.sequence.create('counter_seq')
//!   box.func['counter.counter_next']:call{}   --> 1, 2, 3, ...
//!
//! Every proc here is a *typed* proc (`exportProc`): the argument array and the
//! return value are (de)serialized by the comptime wrapper, and any returned
//! Zig error becomes a box error.

const t = @import("tarantool");
const box = t.box;
const seq = t.seq;
const proc = t.proc;

/// The sequence every proc operates on. Resolved by name each call (cheap: one
/// `_sequence` index lookup); a real module might cache the id.
const SEQ_NAME = "counter_seq";

/// counter_next() -> i64: advance the sequence and return its new value.
fn counterNext() !i64 {
    const s = try seq.Sequence.byName(SEQ_NAME);
    return s.next();
}

/// counter_current() -> i64: the sequence's current value (errors if it was
/// never advanced — sequences have no value until the first `next`).
fn counterCurrent() !i64 {
    const s = try seq.Sequence.byName(SEQ_NAME);
    return s.current();
}

/// counter_set(v): force the sequence's value; the next `next` returns v+1.
fn counterSet(v: i64) !void {
    const s = try seq.Sequence.byName(SEQ_NAME);
    try s.set(v);
}

/// counter_reset(): reset the sequence to its start state (next `next` == start).
fn counterReset() !void {
    const s = try seq.Sequence.byName(SEQ_NAME);
    try s.reset();
}

/// counter_add_event(name) -> i64: mint a fresh id from the sequence and insert
/// `{id, name}` into the `events` space, returning the id. Shows a sequence
/// driving primary keys.
fn counterAddEvent(name: []const u8) !i64 {
    const s = try seq.Sequence.byName(SEQ_NAME);
    const id = try s.next();
    const events = try box.Space.byName("events");
    if (try events.insert(.{ id, name })) |row| row.deinit();
    return id;
}

comptime {
    proc.exportProc("counter_next", counterNext);
    proc.exportProc("counter_current", counterCurrent);
    proc.exportProc("counter_set", counterSet);
    proc.exportProc("counter_reset", counterReset);
    proc.exportProc("counter_add_event", counterAddEvent);
}
