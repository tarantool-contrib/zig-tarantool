//! A Tarantool C module with one typed stored procedure. Installed as
//! `zig-out/lib/hello.so` (`hello.dylib` on macOS); with that directory on
//! `package.cpath`:
//!
//!   box.schema.func.create('hello.add', {language = 'C'})
//!   box.func['hello.add']:call{1, 2} --> 3

const t = @import("tarantool");

fn add(a: i64, b: i64) i64 {
    return a + b;
}

comptime {
    t.proc.exportProc("add", add);
}
