//! Root module of the Zig sqlite_heap implementation.
//!
//! The interesting code is split across `tam.zig` (the table-AM callbacks),
//! `inspect.zig` (the SQL inspection functions), `sqlite.zig` (the backend),
//! `visibility.zig`, and `ffi.zig`. This file pulls those in and exports the
//! transaction-callback entry points the C shim's trampolines dispatch to.

const pg = @import("pg.zig");
const sqlite = @import("sqlite.zig");

// Force the callback / inspection modules into the compilation so their
// `export fn`s are emitted into the shared library.
comptime {
    _ = @import("tam.zig");
    _ = @import("inspect.zig");
}

// --- transaction / sub-transaction callbacks ---
//
// Registered once per backend via `shim_register_xact_callbacks`; the C
// trampolines filter the event kind and call into these.

export fn zig_on_precommit() void {
    sqlite.onPrecommit();
}

export fn zig_on_commit() void {
    sqlite.onCommit();
}

export fn zig_on_abort() void {
    sqlite.onAbort();
}

export fn zig_on_sub_start(my_subid: pg.SubXid) void {
    sqlite.onSubStart(my_subid);
}

export fn zig_on_sub_commit(my_subid: pg.SubXid) void {
    sqlite.onSubCommit(my_subid);
}

export fn zig_on_sub_abort(my_subid: pg.SubXid) void {
    sqlite.onSubAbort(my_subid);
}
