//! symresolve — runtime resolver for *hidden* symbols in the main binary.
//!
//! Tarantool hides parts of its internal C API behind an export list
//! (`-unexported_symbols_list` on macOS, `--dynamic-list` on Linux) and
//! `-fvisibility=hidden`. Those symbols are absent from the dynamic table
//! (`.dynsym` / Mach-O export trie), so `dlsym` returns null for them — but
//! they remain in the FULL symbol table of the main binary (`.symtab` /
//! `LC_SYMTAB`) as long as the binary is not stripped.
//!
//! `resolve()` reads that full table directly and returns a runtime address
//! suitable for `@ptrCast`ing to a function pointer with a known signature.
//! This is the escape hatch a plugin uses to hook unstable-but-present
//! internal APIs (e.g. replication / parallel-read paths) that the stable
//! module ABI does not export.
//!
//! Port of a C symresolve helper. Same algorithm; the Linux side no
//! longer needs libelf — we parse ELF64 directly.
//!
//! Limitations (unchanged from the C original):
//!   - A stripped binary has no `.symtab`/`LC_SYMTAB`; every lookup fails.
//!   - macOS: only the main image is searched. dyld shared-cache dylibs are
//!     not mapped at file-derived offsets, so they cannot be walked this way.
//!     Tarantool's own internals live in the main binary, which is enough.
//!   - The signature you cast the result to MUST match the symbol's real ABI
//!     for the running Tarantool version. Nothing here verifies it.
//!   - 64-bit little-endian only (amd64/arm64 Linux + macOS). The on-disk
//!     symbol-table format is fixed by the OS/ABI class (Mach-O 64 / ELF64),
//!     not the CPU, so no per-arch code is needed — only this width guard.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (@bitSizeOf(usize) != 64)
        @compileError("symresolve: 64-bit targets only");
}

/// Resolve `name` — an unmangled C symbol name, without a leading underscore —
/// to a runtime pointer, or null if the symbol is absent or the binary is
/// stripped. The macOS `_foo` convention is handled internally, so pass `foo`.
///
/// The result is `@ptrCast`-ready; the caller is responsible for casting to a
/// function-pointer type whose signature matches the symbol's real ABI.
pub fn resolve(name: []const u8) ?*anyopaque {
    if (name.len == 0) return null;
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos => macho.lookup(name),
        .linux => elf.lookup(name),
        else => @compileError("symresolve: unsupported OS"),
    };
}

// ---------------------------------------------------------------------------
// macOS — Mach-O LC_SYMTAB scanner (reads live memory via dyld).
// ---------------------------------------------------------------------------

const macho = struct {
    const m = std.macho;

    /// N_TYPE mask and N_UNDF value from <mach-o/nlist.h>: an entry whose
    /// masked type is N_UNDF (0) is undefined and has no runtime location.
    const N_TYPE: u8 = 0x0e;
    const N_UNDF: u8 = 0x00;

    fn lookup(name: []const u8) ?*anyopaque {
        const hdr = std.c._dyld_get_image_header(0) orelse return null;
        const mh: *const m.mach_header_64 = @ptrCast(@alignCast(hdr));
        if (mh.magic != m.MH_MAGIC_64 and mh.magic != m.MH_CIGAM_64)
            return null;

        const slide: usize = std.c._dyld_get_image_vmaddr_slide(0);

        const symtab = findSymtab(mh) orelse return null;
        const sym_base = fileOffToPtr(mh, slide, symtab.symoff) orelse return null;
        const str_base = fileOffToPtr(mh, slide, symtab.stroff) orelse return null;
        const symbols: [*]const m.nlist_64 = @ptrCast(@alignCast(sym_base));
        const strings: [*]const u8 = str_base;

        var i: u32 = 0;
        while (i < symtab.nsyms) : (i += 1) {
            const sym = &symbols[i];
            if (!nameMatches(sym, strings, name)) continue;
            if (!hasAddress(sym)) continue;
            return @ptrFromInt(@as(usize, @intCast(sym.n_value)) +% slide);
        }
        return null;
    }

    /// True if `sym` names the target. Accepts both Mach-O's `_foo`
    /// representation and the bare `foo`, so callers need not pre-prefix.
    fn nameMatches(sym: *const m.nlist_64, strings: [*]const u8, target: []const u8) bool {
        if (sym.n_strx == 0) return false;
        const raw: [*:0]const u8 = @ptrCast(strings + sym.n_strx);
        const s = std.mem.span(raw);
        const bare = if (s.len != 0 and s[0] == '_') s[1..] else s;
        return std.mem.eql(u8, bare, target) or std.mem.eql(u8, s, target);
    }

    /// Reject undefined / address-less entries whose name happens to match.
    fn hasAddress(sym: *const m.nlist_64) bool {
        const nt: u8 = @bitCast(sym.n_type);
        if (nt & N_TYPE == N_UNDF) return false;
        if (sym.n_value == 0) return false;
        return true;
    }

    fn firstLc(mh: *const m.mach_header_64) *const m.load_command {
        return @ptrFromInt(@intFromPtr(mh) + @sizeOf(m.mach_header_64));
    }

    fn nextLc(lc: *const m.load_command) *const m.load_command {
        return @ptrFromInt(@intFromPtr(lc) + lc.cmdsize);
    }

    fn findSymtab(mh: *const m.mach_header_64) ?*const m.symtab_command {
        var lc = firstLc(mh);
        var i: u32 = 0;
        while (i < mh.ncmds) : (i += 1) {
            if (lc.cmd == .SYMTAB)
                return @ptrCast(@alignCast(lc));
            lc = nextLc(lc);
        }
        return null;
    }

    /// Map a file offset to its in-memory address for the main image:
    ///   runtime(F) = seg.vmaddr + slide + (F - seg.fileoff)
    /// for the unique LC_SEGMENT_64 whose file range covers F.
    fn fileOffToPtr(mh: *const m.mach_header_64, slide: usize, file_off: u64) ?[*]const u8 {
        var lc = firstLc(mh);
        var i: u32 = 0;
        while (i < mh.ncmds) : (i += 1) {
            if (lc.cmd == .SEGMENT_64) {
                const seg: *const m.segment_command_64 = @ptrCast(@alignCast(lc));
                if (seg.filesize > 0 and
                    file_off >= seg.fileoff and
                    file_off < seg.fileoff + seg.filesize)
                {
                    const rt = @as(usize, @intCast(seg.vmaddr)) +% slide +%
                        @as(usize, @intCast(file_off - seg.fileoff));
                    return @ptrFromInt(rt);
                }
            }
            lc = nextLc(lc);
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Linux — ELF64 .symtab scanner (reads the on-disk main binary, no libelf).
// ---------------------------------------------------------------------------

const elf = struct {
    const e = std.elf;
    // The unprefixed field names (`ident`, `shoff`, `type`, ...); the
    // top-level `std.elf.Ehdr` & co are the deprecated `e_`-prefixed structs.
    const e64 = std.elf.Elf64;
    const linux = std.os.linux;

    const MainImage = struct {
        base: usize = 0,
        found: bool = false,
    };

    fn lookup(name: []const u8) ?*anyopaque {
        // Load base (0 for ET_EXEC, nonzero for PIE). The path is always
        // /proc/self/exe — dlpi_name is typically empty for the main image.
        var img = MainImage{};
        std.posix.dl_iterate_phdr(&img, error{Done}, phdrCb) catch {};
        if (!img.found) return null;

        const fd = std.posix.openatZ(std.posix.AT.FDCWD, "/proc/self/exe", .{}, 0) catch return null;
        defer _ = linux.close(fd);

        const end = linux.lseek(fd, 0, std.posix.SEEK.END);
        switch (linux.errno(end)) {
            .SUCCESS => {},
            else => return null,
        }
        const size: usize = end;
        if (size < @sizeOf(e64.Ehdr)) return null;

        const page = std.heap.pageSize();
        const map_len = std.mem.alignForward(usize, size, page);
        const mapped = std.posix.mmap(
            null,
            map_len,
            .{ .READ = true },
            .{ .TYPE = .PRIVATE },
            fd,
            0,
        ) catch return null;
        defer std.posix.munmap(mapped);

        const value = scan(mapped[0..size], name) orelse return null;
        return @ptrFromInt(img.base +% value);
    }

    fn phdrCb(info: *linux.dl_phdr_info, size: usize, ctx: *MainImage) error{Done}!void {
        _ = size;
        ctx.base = info.addr;
        ctx.found = true;
        return error.Done; // stop after the first object (the main exe)
    }

    /// Copy a fixed-size struct out of `data` at `off`, bounds-checked.
    /// Copying (vs. a pointer cast) sidesteps any alignment assumptions about
    /// the file layout — this is the cost of parsing ELF without libelf.
    fn readStruct(comptime T: type, data: []const u8, off: u64) ?T {
        if (off > data.len or @sizeOf(T) > data.len - off) return null;
        var v: T = undefined;
        @memcpy(std.mem.asBytes(&v), data[@intCast(off)..][0..@sizeOf(T)]);
        return v;
    }

    /// Walk `data` (the whole binary), pick a symbol section, scan it.
    fn scan(data: []const u8, name: []const u8) ?u64 {
        const eh = readStruct(e64.Ehdr, data, 0) orelse return null;
        if (!std.mem.eql(u8, &eh.ident.magic, e.MAGIC)) return null;
        if (eh.ident.class != .@"64") return null;
        if (eh.ident.data != .@"2LSB") return null;
        if (eh.shentsize < @sizeOf(e64.Shdr)) return null;

        const symsec = pickSymbolSection(data, eh) orelse return null;
        if (symsec.entsize == 0) return null;

        // Its linked string table.
        const strsec = shdrAt(data, eh, symsec.link) orelse return null;
        const strtab = section(data, strsec) orelse return null;

        const nsyms = symsec.size / symsec.entsize;
        var i: u64 = 0;
        while (i < nsyms) : (i += 1) {
            const sym = readStruct(e64.Sym, data, symsec.offset + i * symsec.entsize) orelse return null;
            if (sym.name == 0) continue;
            if (sym.shndx == e.SHN_UNDEF) continue;
            const nm = cstr(strtab, sym.name) orelse continue;
            if (!std.mem.eql(u8, nm, name)) continue;
            return sym.value;
        }
        return null;
    }

    /// Prefer SHT_SYMTAB (the full table, where hidden symbols live) over
    /// SHT_DYNSYM (a fallback for partially-stripped binaries).
    fn pickSymbolSection(data: []const u8, eh: e64.Ehdr) ?e64.Shdr {
        var dynsym: ?e64.Shdr = null;
        var i: u16 = 0;
        while (i < eh.shnum) : (i += 1) {
            const sh = shdrAt(data, eh, i) orelse continue;
            switch (sh.type) {
                .SYMTAB => return sh,
                .DYNSYM => dynsym = sh,
                else => {},
            }
        }
        return dynsym;
    }

    fn shdrAt(data: []const u8, eh: e64.Ehdr, idx: u32) ?e64.Shdr {
        if (idx >= eh.shnum) return null;
        const off = eh.shoff + @as(u64, idx) * eh.shentsize;
        return readStruct(e64.Shdr, data, off);
    }

    /// The byte range a section spans in the file, bounds-checked.
    fn section(data: []const u8, sh: e64.Shdr) ?[]const u8 {
        if (sh.offset > data.len or sh.size > data.len - sh.offset) return null;
        return data[@intCast(sh.offset)..][0..@intCast(sh.size)];
    }

    /// NUL-terminated string at `off` within `blob`, bounded by the blob.
    fn cstr(blob: []const u8, off: u32) ?[]const u8 {
        if (off >= blob.len) return null;
        const rest = blob[off..];
        const end = std.mem.indexOfScalar(u8, rest, 0) orelse return null;
        return rest[0..end];
    }
};

// ---------------------------------------------------------------------------
// Tests — only the OS-independent glue is unit-testable; the symbol-table
// walk needs a live binary and is covered by the integration suite.
// ---------------------------------------------------------------------------

test "empty name resolves to null" {
    try std.testing.expect(resolve("") == null);
}

test "missing symbol resolves to null" {
    // No symbol table has this name; on a normal test binary this is a
    // well-formed miss (not a crash), exercising the full walk to completion.
    try std.testing.expect(resolve("zig_tarantool_symresolve_definitely_absent") == null);
}
