//! Hand-written bindings to the C shim (`shim.h`).
//!
//! Zig 0.16's `@cImport` cannot digest the PostgreSQL headers, so instead of
//! translating them we keep every PostgreSQL type opaque and reach it through
//! the wrappers in `shim.c`. This module is the single declaration surface
//! for that boundary.

// --- PostgreSQL scalar types (fixed width on the platforms we target) ---
pub const Datum = usize;
pub const Oid = u32;
pub const Xid = u32;
pub const Cid = u32;
pub const SubXid = u32;
pub const BlockNumber = u32;
pub const OffsetNumber = u16;

// --- opaque PostgreSQL handles ---
pub const Relation = ?*anyopaque;
pub const Snapshot = ?*anyopaque;
pub const Slot = ?*anyopaque;
pub const HeapTuple = ?*anyopaque;
pub const Scan = ?*anyopaque;
pub const ItemPointer = ?*anyopaque;
pub const IndexFetch = ?*anyopaque;
pub const IndexInfo = ?*anyopaque;
pub const IndexDeleteOp = ?*anyopaque;
pub const ReadStream = ?*anyopaque;
pub const EState = ?*anyopaque;
pub const TupleDesc = ?*anyopaque;
pub const FCInfo = ?*anyopaque;
pub const ParallelScan = ?*anyopaque;
pub const SlotOps = anyopaque;

// SnapshotType enum values (utils/snapshot.h).
pub const SNAPSHOT_MVCC: c_int = 0;
pub const SNAPSHOT_SELF: c_int = 1;
pub const SNAPSHOT_ANY: c_int = 2;
pub const SNAPSHOT_TOAST: c_int = 3;
pub const SNAPSHOT_DIRTY: c_int = 4;
pub const SNAPSHOT_HISTORIC_MVCC: c_int = 5;
pub const SNAPSHOT_NON_VACUUMABLE: c_int = 6;

// TM_Result enum values (access/tableam.h).
pub const TM_OK: c_int = 0;
pub const TM_DELETED: c_int = 4;

// ForkNumber: the main fork is 0 (common/relpath.h).
pub const MAIN_FORKNUM: c_int = 0;

pub const MAX_OFFSETS = 1024;

pub const TbmPage = extern struct {
    blockno: BlockNumber,
    recheck: bool,
    lossy: bool,
    noffsets: c_int,
    offsets: [MAX_OFFSETS]OffsetNumber,
};

pub const SRF = extern struct {
    tupstore: ?*anyopaque,
    tupdesc: ?*anyopaque,
};

// --- errors ---
pub extern fn shim_ereport_error(msg: [*:0]const u8) noreturn;
pub extern fn shim_ereport_warning(msg: [*:0]const u8) void;

// --- backend globals ---
pub extern fn shim_data_dir() [*:0]const u8;
pub extern fn shim_my_database_id() Oid;

// --- filesystem ---
pub extern fn shim_mkdir_p(path: [*:0]const u8) c_int;
pub extern fn shim_file_size(path: [*:0]const u8) i64;
pub extern fn shim_unlink(path: [*:0]const u8) void;
pub extern fn shim_list_dir(
    path: [*:0]const u8,
    cb: *const fn (?*anyopaque, [*:0]const u8) callconv(.c) void,
    ctx: ?*anyopaque,
) void;

// --- transaction callbacks ---
pub extern fn shim_register_xact_callbacks() void;

// --- transaction id helpers ---
pub extern fn shim_current_xid() Xid;
pub extern fn shim_current_cid(used: bool) Cid;
pub extern fn shim_oldest_non_removable_xid(rel: Relation) Xid;
pub extern fn shim_xid_did_commit(xid: Xid) bool;
pub extern fn shim_xid_is_current(xid: Xid) bool;
pub extern fn shim_xid_in_progress(xid: Xid) bool;
pub extern fn shim_xid_precedes(a: Xid, b: Xid) bool;
pub extern fn shim_xid_follows(a: Xid, b: Xid) bool;

// --- relation ---
pub extern fn shim_rel_oid(rel: Relation) Oid;
pub extern fn shim_rel_tupdesc(rel: Relation) TupleDesc;

// --- slots ---
pub extern fn shim_slot_clear(slot: Slot) void;
pub extern fn shim_slot_store_tuple(slot: Slot, tup: HeapTuple) void;
pub extern fn shim_slot_copy_heaptuple(slot: Slot) HeapTuple;
pub extern fn shim_slot_set_tid(slot: Slot, table_oid: Oid, blk: BlockNumber, off: OffsetNumber) void;
pub extern fn shim_slot_get_tid(slot: Slot, blk: *BlockNumber, off: *OffsetNumber) void;

// --- item pointers ---
pub extern fn shim_itemptr_block(p: ItemPointer) BlockNumber;
pub extern fn shim_itemptr_offset(p: ItemPointer) OffsetNumber;

// --- heap tuples ---
pub extern fn shim_build_heap_tuple(
    table_oid: Oid,
    blk: BlockNumber,
    off: OffsetNumber,
    bytes: ?*const anyopaque,
    len: u32,
    xmin: Xid,
    xmax: Xid,
    cid: Cid,
) HeapTuple;
pub extern fn shim_heaptuple_bytes(tup: HeapTuple, len: *u32) ?*const anyopaque;
pub extern fn shim_heap_freetuple(tup: HeapTuple) void;

// --- snapshots ---
pub extern fn shim_snapshot_type(snap: Snapshot) c_int;
pub extern fn shim_snap_xmin(snap: Snapshot) Xid;
pub extern fn shim_snap_xmax(snap: Snapshot) Xid;
pub extern fn shim_snap_curcid(snap: Snapshot) Cid;
pub extern fn shim_snap_xcnt(snap: Snapshot) u32;
pub extern fn shim_snap_xip(snap: Snapshot, i: u32) Xid;
pub extern fn shim_snap_reset_dirty_out(snap: Snapshot) void;
pub extern fn shim_snap_set_xmin(snap: Snapshot, xid: Xid) void;
pub extern fn shim_snap_set_xmax(snap: Snapshot, xid: Xid) void;

// --- scan descriptor ---
pub extern fn shim_scan_alloc(
    rel: Relation,
    snapshot: Snapshot,
    nkeys: c_int,
    key: ?*anyopaque,
    pscan: ParallelScan,
    flags: u32,
    cursor: ?*anyopaque,
) Scan;
pub extern fn shim_scan_cursor(scan: Scan) ?*anyopaque;
pub extern fn shim_scan_free(scan: Scan) void;
pub extern fn shim_scan_rel(scan: Scan) Relation;
pub extern fn shim_scan_snapshot(scan: Scan) Snapshot;
pub extern fn shim_scan_set_tidrange(scan: Scan, mintid: ItemPointer, maxtid: ItemPointer) void;
pub extern fn shim_scan_get_tidrange(
    scan: Scan,
    min_blk: *BlockNumber,
    min_off: *OffsetNumber,
    max_blk: *BlockNumber,
    max_off: *OffsetNumber,
) void;
pub extern fn shim_tbm_next(scan: Scan, out: *TbmPage) bool;

// --- analyze / sample ---
pub extern fn shim_read_stream_next(stream: ReadStream) bool;

// --- parallel scan ---
pub extern fn shim_parallelscan_estimate(rel: Relation) usize;
pub extern fn shim_parallelscan_initialize(rel: Relation, pscan: ParallelScan) usize;
pub extern fn shim_parallelscan_reinitialize(rel: Relation, pscan: ParallelScan) void;

// --- index fetch ---
pub extern fn shim_index_fetch_alloc(rel: Relation) IndexFetch;
pub extern fn shim_index_fetch_rel(data: IndexFetch) Relation;
pub extern fn shim_index_fetch_free(data: IndexFetch) void;

// --- index delete ---
pub extern fn shim_idel_count(op: IndexDeleteOp) c_int;
pub extern fn shim_idel_set_count(op: IndexDeleteOp, n: c_int) void;
pub extern fn shim_idel_tid(op: IndexDeleteOp, i: c_int, blk: *BlockNumber, off: *OffsetNumber) void;
pub extern fn shim_idel_id(op: IndexDeleteOp, i: c_int) c_int;
pub extern fn shim_idel_set_deletable(op: IndexDeleteOp, status_idx: c_int) void;

// --- index build ---
pub extern fn shim_index_info_natts(info: IndexInfo) c_int;
pub extern fn shim_index_build_setup(table_rel: Relation, estate_out: *EState, slot_out: *Slot) void;
pub extern fn shim_index_build_form_datum(
    info: IndexInfo,
    slot: Slot,
    estate: EState,
    values: [*]Datum,
    isnull: [*]bool,
) void;
pub extern fn shim_index_build_emit(
    callback: ?*anyopaque,
    index_rel: Relation,
    blk: BlockNumber,
    off: OffsetNumber,
    values: [*]Datum,
    isnull: [*]bool,
    callback_state: ?*anyopaque,
) void;
pub extern fn shim_index_build_teardown(estate: EState, slot: Slot) void;

// --- tuple update index signalling ---
pub extern fn shim_set_update_indexes_all(update_indexes: ?*anyopaque) void;

// --- Datum construction / argument access ---
pub extern fn shim_int64_datum(v: i64) Datum;
pub extern fn shim_int32_datum(v: i32) Datum;
pub extern fn shim_bool_datum(v: bool) Datum;
pub extern fn shim_oid_datum(v: Oid) Datum;
pub extern fn shim_text_datum(s: [*:0]const u8) Datum;
pub extern fn shim_getarg_oid(fcinfo: FCInfo, n: c_int) Oid;

// --- set-returning functions ---
pub extern fn shim_srf_begin(fcinfo: FCInfo) SRF;
pub extern fn shim_srf_put(srf: *SRF, values: [*]Datum, nulls: [*]bool) void;

// --- slot operations vtable ---
pub extern fn shim_tts_ops_heaptuple() *const SlotOps;

// --- macro-only constants ---
pub extern fn shim_blcksz() u32;

// --- helpers ---

/// Raise a PostgreSQL ERROR (longjmps; never returns). The Rust port turned
/// SQLite failures into Postgres ERRORs the same way.
pub fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    const std = @import("std");
    var buf: [768]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, fmt, args) catch
        "sqlite_heap_zig: error (message too long to format)";
    shim_ereport_error(msg.ptr);
}

/// Emit a PostgreSQL WARNING. Used on the abort path, where unwinding would be
/// unsafe and there is nothing left to roll back.
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    const std = @import("std");
    var buf: [768]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, fmt, args) catch
        "sqlite_heap_zig: warning (message too long to format)";
    shim_ereport_warning(msg.ptr);
}
