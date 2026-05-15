//! Table Access Method: the scan cursor and the ~43 `TableAmRoutine`
//! callbacks. The Zig port of `tam.rs`.
//!
//! The dispatch table itself lives in `shim.c`; this module exports the
//! callback bodies with the C ABI. Each one wraps the opaque PostgreSQL
//! handles in `shim_*` accessor calls and delegates to the `sqlite` /
//! `visibility` / `ffi` modules.

const std = @import("std");
const pg = @import("pg.zig");
const sqlite = @import("sqlite.zig");
const visibility = @import("visibility.zig");
const ffi = @import("ffi.zig");

const alloc = std.heap.c_allocator;

// --- scan cursor ---------------------------------------------------------

/// Per-scan iteration state. Allocated by Zig (`alloc`), referenced from the
/// shim-owned scan descriptor, and freed in `zig_scan_end`.
const SqliteCursor = struct {
    /// Whole relation, loaded lazily by `ensureRowsLoaded` -- a seq/sample/
    /// analyze scan needs it, a bitmap-exact scan must not pay for it.
    rows: []sqlite.StoredRow = &.{},
    rows_loaded: bool = false,
    pos: usize = 0,
    /// `scan_sample_next_block` models the table as one logical block.
    sample_block_consumed: bool = false,
    /// Offsets extracted from the current TBM page, and our position in them.
    bitmap_blockno: pg.BlockNumber = 0,
    bitmap_offsets: std.ArrayList(pg.OffsetNumber) = .empty,
    bitmap_offset_pos: usize = 0,

    fn ensureRowsLoaded(self: *SqliteCursor, rel_id: u32) void {
        if (!self.rows_loaded) {
            self.rows = sqlite.selectAll(rel_id);
            self.rows_loaded = true;
        }
    }

    fn deinit(self: *SqliteCursor) void {
        if (self.rows_loaded) sqlite.freeRows(self.rows);
        self.bitmap_offsets.deinit(alloc);
    }
};

fn cursorOf(scan: pg.Scan) *SqliteCursor {
    return @ptrCast(@alignCast(pg.shim_scan_cursor(scan).?));
}

// --- slot / parallel scan ------------------------------------------------

export fn zig_slot_callbacks(rel: pg.Relation) *const pg.SlotOps {
    _ = rel;
    return pg.shim_tts_ops_heaptuple();
}

export fn zig_parallelscan_estimate(rel: pg.Relation) usize {
    return pg.shim_parallelscan_estimate(rel);
}

export fn zig_parallelscan_initialize(rel: pg.Relation, pscan: pg.ParallelScan) usize {
    return pg.shim_parallelscan_initialize(rel, pscan);
}

export fn zig_parallelscan_reinitialize(rel: pg.Relation, pscan: pg.ParallelScan) void {
    pg.shim_parallelscan_reinitialize(rel, pscan);
}

// --- sequential scan -----------------------------------------------------

export fn zig_scan_begin(
    rel: pg.Relation,
    snapshot: pg.Snapshot,
    nkeys: c_int,
    key: ?*anyopaque,
    pscan: pg.ParallelScan,
    flags: u32,
) pg.Scan {
    const cursor = alloc.create(SqliteCursor) catch pg.fail("sqlite_heap_zig: out of memory", .{});
    cursor.* = .{};
    return pg.shim_scan_alloc(rel, snapshot, nkeys, key, pscan, flags, cursor);
}

export fn zig_scan_end(scan: pg.Scan) void {
    const cursor = cursorOf(scan);
    cursor.deinit();
    alloc.destroy(cursor);
    pg.shim_scan_free(scan);
}

export fn zig_scan_rescan(
    scan: pg.Scan,
    key: ?*anyopaque,
    set_params: bool,
    allow_strat: bool,
    allow_sync: bool,
    allow_pagemode: bool,
) void {
    _ = key;
    _ = set_params;
    _ = allow_strat;
    _ = allow_sync;
    _ = allow_pagemode;
    cursorOf(scan).pos = 0;
}

export fn zig_scan_getnextslot(scan: pg.Scan, direction: c_int, slot: pg.Slot) bool {
    _ = direction;
    const snapshot = pg.shim_scan_snapshot(scan);
    const rel_id = pg.shim_rel_oid(pg.shim_scan_rel(scan));
    const cursor = cursorOf(scan);

    pg.shim_slot_clear(slot);
    cursor.ensureRowsLoaded(rel_id);
    while (cursor.pos < cursor.rows.len) {
        const row = &cursor.rows[cursor.pos];
        cursor.pos += 1;
        if (visibility.rowVisible(&row.header, snapshot)) {
            ffi.storeRow(slot, rel_id, row);
            return true;
        }
    }
    return false;
}

export fn zig_scan_set_tidrange(scan: pg.Scan, mintid: pg.ItemPointer, maxtid: pg.ItemPointer) void {
    pg.shim_scan_set_tidrange(scan, mintid, maxtid);
    cursorOf(scan).pos = 0;
}

export fn zig_scan_getnextslot_tidrange(scan: pg.Scan, direction: c_int, slot: pg.Slot) bool {
    _ = direction;
    const snapshot = pg.shim_scan_snapshot(scan);
    const rel_id = pg.shim_rel_oid(pg.shim_scan_rel(scan));
    const cursor = cursorOf(scan);

    var min_blk: pg.BlockNumber = 0;
    var min_off: pg.OffsetNumber = 0;
    var max_blk: pg.BlockNumber = 0;
    var max_off: pg.OffsetNumber = 0;
    pg.shim_scan_get_tidrange(scan, &min_blk, &min_off, &max_blk, &max_off);
    const min_rowid = @as(i64, min_blk) * ffi.TIDS_PER_BLOCK + min_off;
    const max_rowid = @as(i64, max_blk) * ffi.TIDS_PER_BLOCK + max_off;

    pg.shim_slot_clear(slot);
    cursor.ensureRowsLoaded(rel_id);
    while (cursor.pos < cursor.rows.len) {
        const row = &cursor.rows[cursor.pos];
        cursor.pos += 1;
        if (row.header.rowid < min_rowid or row.header.rowid > max_rowid) continue;
        if (!visibility.rowVisible(&row.header, snapshot)) continue;
        ffi.storeRow(slot, rel_id, row);
        return true;
    }
    return false;
}

// --- index access -------------------------------------------------------

export fn zig_index_fetch_begin(rel: pg.Relation) pg.IndexFetch {
    return pg.shim_index_fetch_alloc(rel);
}

export fn zig_index_fetch_reset(data: pg.IndexFetch) void {
    _ = data;
}

export fn zig_index_fetch_end(data: pg.IndexFetch) void {
    pg.shim_index_fetch_free(data);
}

export fn zig_index_fetch_tuple(
    scan: pg.IndexFetch,
    tid: pg.ItemPointer,
    snapshot: pg.Snapshot,
    slot: pg.Slot,
    call_again: ?*bool,
    all_dead: ?*bool,
) bool {
    if (call_again) |p| p.* = false;
    if (all_dead) |p| p.* = false;
    const rel = pg.shim_index_fetch_rel(scan);
    const rowid = ffi.tidToRowid(tid);
    return fetchOneIntoSlot(rel, rowid, snapshot, slot);
}

const FetchCtx = struct {
    rel_id: u32,
    snapshot: pg.Snapshot,
    slot: pg.Slot,

    fn store(self: FetchCtx, header: *const sqlite.StoredHeader, bytes: []const u8) bool {
        if (!visibility.rowVisible(header, self.snapshot)) return false;
        ffi.storeParts(self.slot, self.rel_id, header, bytes);
        return true;
    }
};

fn fetchOneIntoSlot(rel: pg.Relation, rowid: i64, snapshot: pg.Snapshot, slot: pg.Slot) bool {
    const ctx = FetchCtx{
        .rel_id = pg.shim_rel_oid(rel),
        .snapshot = snapshot,
        .slot = slot,
    };
    return sqlite.fetchOneRef(ctx.rel_id, rowid, ctx, FetchCtx.store);
}

// --- tuple lifecycle ----------------------------------------------------

export fn zig_tuple_fetch_row_version(
    rel: pg.Relation,
    tid: pg.ItemPointer,
    snapshot: pg.Snapshot,
    slot: pg.Slot,
) bool {
    return fetchOneIntoSlot(rel, ffi.tidToRowid(tid), snapshot, slot);
}

export fn zig_tuple_tid_valid(scan: pg.Scan, tid: pg.ItemPointer) bool {
    const rel_id = pg.shim_rel_oid(pg.shim_scan_rel(scan));
    const row = sqlite.selectOne(rel_id, ffi.tidToRowid(tid)) orelse return false;
    alloc.free(row.tuple);
    return true;
}

export fn zig_tuple_get_latest_tid(scan: pg.Scan, tid: pg.ItemPointer) void {
    _ = scan;
    _ = tid;
}

export fn zig_tuple_satisfies_snapshot(rel: pg.Relation, slot: pg.Slot, snapshot: pg.Snapshot) bool {
    // The slot's tts_tid was set when we stored the row; look it back up and
    // re-check visibility under the current snapshot.
    var blk: pg.BlockNumber = 0;
    var off: pg.OffsetNumber = 0;
    pg.shim_slot_get_tid(slot, &blk, &off);
    const rowid = @as(i64, blk) * ffi.TIDS_PER_BLOCK + off;
    const row = sqlite.selectOne(pg.shim_rel_oid(rel), rowid) orelse return false;
    defer alloc.free(row.tuple);
    return visibility.rowVisible(&row.header, snapshot);
}

export fn zig_index_delete_tuples(rel: pg.Relation, delstate: pg.IndexDeleteOp) pg.Xid {
    // btree (notably bottom-up deletion) asks which of these index TIDs point
    // to reclaimable rows. Contract: mark each deletable entry; if *nothing*
    // is deletable, shrink ndeltids to 0 -- else btree's `_bt_delitems_delete`
    // hits `Assert(ndeletable > 0 || nupdatable > 0)`.
    const rel_id = pg.shim_rel_oid(rel);
    const n = pg.shim_idel_count(delstate);
    if (n == 0) return 0; // InvalidTransactionId

    const count: usize = @intCast(n);
    const rowids = alloc.alloc(i64, count) catch pg.fail("sqlite_heap_zig: out of memory", .{});
    defer alloc.free(rowids);
    const status_ids = alloc.alloc(c_int, count) catch pg.fail("sqlite_heap_zig: out of memory", .{});
    defer alloc.free(status_ids);

    var i: c_int = 0;
    while (i < n) : (i += 1) {
        var blk: pg.BlockNumber = 0;
        var off: pg.OffsetNumber = 0;
        pg.shim_idel_tid(delstate, i, &blk, &off);
        rowids[@intCast(i)] = @as(i64, blk) * ffi.TIDS_PER_BLOCK + off;
        status_ids[@intCast(i)] = pg.shim_idel_id(delstate, i);
    }

    // A row version is reclaimable iff its xmax is committed and older than
    // every still-running snapshot -- the same bar as VACUUM.
    const oldest = pg.shim_oldest_non_removable_xid(rel);
    var xmax_map = sqlite.selectXmaxBatch(rel_id, rowids);
    defer xmax_map.deinit(alloc);

    var latest_removed: pg.Xid = 0;
    var any_deletable = false;
    for (rowids, status_ids) |rowid, status_idx| {
        const xmax_opt = xmax_map.get(rowid);
        // `null` => row physically gone already (VACUUMed) => index entry stale.
        const deletable = if (xmax_opt) |xmax| blk: {
            if (xmax == 0) break :blk false; // still live
            break :blk visibility.didCommit(xmax) and pg.shim_xid_precedes(xmax, oldest);
        } else true;

        if (deletable) {
            pg.shim_idel_set_deletable(delstate, status_idx);
            any_deletable = true;
            if (xmax_opt) |xmax| {
                if (xmax != 0 and pg.shim_xid_follows(xmax, latest_removed)) latest_removed = xmax;
            }
        }
    }

    if (!any_deletable) {
        // Nothing to reclaim -- tell btree via an empty array so it returns
        // early instead of asserting.
        pg.shim_idel_set_count(delstate, 0);
    }
    return latest_removed;
}

// --- inserts ------------------------------------------------------------

fn doTupleInsert(rel: pg.Relation, slot: pg.Slot, cid: pg.Cid) void {
    const owned = ffi.copyHeapTuple(slot);
    defer owned.deinit();
    const xid = pg.shim_current_xid();
    const rel_id = pg.shim_rel_oid(rel);
    const rowid = sqlite.insert(rel_id, xid, cid, owned.bytes());
    ffi.setInsertedTid(slot, rel_id, rowid);
}

export fn zig_tuple_insert(
    rel: pg.Relation,
    slot: pg.Slot,
    cid: pg.Cid,
    options: c_int,
    bistate: ?*anyopaque,
) void {
    _ = options;
    _ = bistate;
    doTupleInsert(rel, slot, cid);
}

export fn zig_tuple_insert_speculative(
    rel: pg.Relation,
    slot: pg.Slot,
    cid: pg.Cid,
    options: c_int,
    bistate: ?*anyopaque,
    spec_token: u32,
) void {
    _ = options;
    _ = bistate;
    _ = spec_token;
    // Insert like any other row; `tuple_complete_speculative` retracts it if
    // the speculation lost.
    doTupleInsert(rel, slot, cid);
}

export fn zig_tuple_complete_speculative(
    rel: pg.Relation,
    slot: pg.Slot,
    spec_token: u32,
    succeeded: bool,
) void {
    _ = spec_token;
    if (succeeded) return;
    // Speculation lost: physically remove the speculative row.
    var blk: pg.BlockNumber = 0;
    var off: pg.OffsetNumber = 0;
    pg.shim_slot_get_tid(slot, &blk, &off);
    const rowid = @as(i64, blk) * ffi.TIDS_PER_BLOCK + off;
    _ = sqlite.physicalDelete(pg.shim_rel_oid(rel), rowid);
}

export fn zig_multi_insert(
    rel: pg.Relation,
    slots: [*]pg.Slot,
    nslots: c_int,
    cid: pg.Cid,
    options: c_int,
    bistate: ?*anyopaque,
) void {
    _ = options;
    _ = bistate;
    const n: usize = @intCast(nslots);
    if (n == 0) return;

    const rel_id = pg.shim_rel_oid(rel);
    const xid = pg.shim_current_xid();

    // Materialize every slot once, then one batched insert rather than N
    // trips through the per-row path.
    const owned = alloc.alloc(ffi.OwnedHeapTuple, n) catch pg.fail("sqlite_heap_zig: out of memory", .{});
    defer {
        for (owned) |o| o.deinit();
        alloc.free(owned);
    }
    const byte_slices = alloc.alloc([]const u8, n) catch pg.fail("sqlite_heap_zig: out of memory", .{});
    defer alloc.free(byte_slices);

    for (0..n) |i| {
        owned[i] = ffi.copyHeapTuple(slots[i]);
        byte_slices[i] = owned[i].bytes();
    }
    const rowids = sqlite.insertBatch(rel_id, xid, cid, byte_slices);
    defer alloc.free(rowids);

    // Stamp the assigned TID back so RETURNING / triggers see it.
    for (0..n) |i| ffi.setInsertedTid(slots[i], rel_id, rowids[i]);
}

// --- delete / update / lock ---------------------------------------------

export fn zig_tuple_delete(
    rel: pg.Relation,
    tid: pg.ItemPointer,
    cid: pg.Cid,
    snapshot: pg.Snapshot,
    crosscheck: pg.Snapshot,
    wait: bool,
    tmfd: ?*anyopaque,
    changing_part: bool,
) c_int {
    _ = snapshot;
    _ = crosscheck;
    _ = wait;
    _ = tmfd;
    _ = changing_part;
    const rel_id = pg.shim_rel_oid(rel);
    const rowid = ffi.tidToRowid(tid);
    const xid = pg.shim_current_xid();
    return if (sqlite.setXmax(rel_id, rowid, xid, cid) == 0) pg.TM_DELETED else pg.TM_OK;
}

export fn zig_tuple_update(
    rel: pg.Relation,
    otid: pg.ItemPointer,
    slot: pg.Slot,
    cid: pg.Cid,
    snapshot: pg.Snapshot,
    crosscheck: pg.Snapshot,
    wait: bool,
    tmfd: ?*anyopaque,
    lockmode: ?*anyopaque,
    update_indexes: ?*anyopaque,
) c_int {
    _ = snapshot;
    _ = crosscheck;
    _ = wait;
    _ = tmfd;
    _ = lockmode;
    const rel_id = pg.shim_rel_oid(rel);
    const old_rowid = ffi.tidToRowid(otid);
    const xid = pg.shim_current_xid();

    const owned = ffi.copyHeapTuple(slot);
    defer owned.deinit();

    // MVCC update: stamp the old row dead, insert the new version at a fresh
    // TID, and have PostgreSQL update every index to point at it.
    const new_rowid = sqlite.updateRow(rel_id, old_rowid, xid, cid, owned.bytes());
    ffi.setInsertedTid(slot, rel_id, new_rowid);
    if (update_indexes) |p| pg.shim_set_update_indexes_all(p);
    return pg.TM_OK;
}

export fn zig_tuple_lock(
    rel: pg.Relation,
    tid: pg.ItemPointer,
    snapshot: pg.Snapshot,
    slot: pg.Slot,
    cid: pg.Cid,
    mode: c_int,
    wait_policy: c_int,
    flags: u8,
    tmfd: ?*anyopaque,
) c_int {
    _ = cid;
    _ = mode;
    _ = wait_policy;
    _ = flags;
    _ = tmfd;
    // Minimal SELECT FOR UPDATE: re-fetch the row. We hold no real row lock
    // (that needs a lock table) -- best-effort under multi-backend contention.
    const rowid = ffi.tidToRowid(tid);
    return if (fetchOneIntoSlot(rel, rowid, snapshot, slot)) pg.TM_OK else pg.TM_DELETED;
}

export fn zig_finish_bulk_insert(rel: pg.Relation, options: c_int) void {
    _ = rel;
    _ = options;
}

// --- relation lifecycle -------------------------------------------------

export fn zig_relation_set_new_filelocator(
    rel: pg.Relation,
    newrlocator: ?*const anyopaque,
    persistence: u8,
    freeze_xid: ?*anyopaque,
    minmulti: ?*anyopaque,
) void {
    _ = newrlocator;
    _ = persistence;
    _ = freeze_xid;
    _ = minmulti;
    sqlite.reset(pg.shim_rel_oid(rel));
}

export fn zig_relation_nontransactional_truncate(rel: pg.Relation) void {
    // The fast TRUNCATE path (table created in this same transaction).
    sqlite.reset(pg.shim_rel_oid(rel));
}

export fn zig_relation_copy_data(rel: pg.Relation, newrlocator: ?*const anyopaque) void {
    _ = rel;
    _ = newrlocator;
    // ALTER TABLE SET TABLESPACE: our files are keyed by relation OID (stable
    // across the move), so the data stays put -- nothing to do here.
}

export fn zig_relation_copy_for_cluster(
    old_table: pg.Relation,
    new_table: pg.Relation,
    old_index: pg.Relation,
    use_sort: bool,
    oldest_xmin: pg.Xid,
    xid_cutoff: ?*anyopaque,
    multi_cutoff: ?*anyopaque,
    num_tuples: *f64,
    tups_vacuumed: *f64,
    tups_recently_dead: *f64,
) void {
    _ = old_index;
    _ = use_sort;
    _ = oldest_xmin;
    _ = xid_cutoff;
    _ = multi_cutoff;
    // CLUSTER / VACUUM FULL: stream every live row from old into new (whose
    // storage was created fresh by relation_set_new_filelocator).
    const old_id = pg.shim_rel_oid(old_table);
    const new_id = pg.shim_rel_oid(new_table);
    const xid = pg.shim_current_xid();
    const cid = pg.shim_current_cid(true);

    const rows = sqlite.selectAll(old_id);
    defer sqlite.freeRows(rows);
    var live: f64 = 0;
    var dead: f64 = 0;
    for (rows) |row| {
        if (row.header.xmax != 0) {
            dead += 1;
            continue;
        }
        _ = sqlite.insert(new_id, xid, cid, row.tuple);
        live += 1;
    }
    num_tuples.* = live;
    tups_vacuumed.* = dead;
    tups_recently_dead.* = 0;
}

export fn zig_relation_vacuum(rel: pg.Relation, params: ?*anyopaque, bstrategy: ?*anyopaque) void {
    _ = params;
    _ = bstrategy;
    const oldest = pg.shim_oldest_non_removable_xid(rel);
    _ = sqlite.vacuumDead(pg.shim_rel_oid(rel), oldest);
}

// --- analyze ------------------------------------------------------------

export fn zig_scan_analyze_next_block(scan: pg.Scan, stream: pg.ReadStream) bool {
    // The table is one logical block. We still must *advance* the ReadStream:
    // `read_stream_next_block` drives the sampler counter `acquire_sample_rows`
    // divides by. Skipping it leaves that counter at 0, so ANALYZE extrapolates
    // 0 rows.
    if (!pg.shim_read_stream_next(stream)) return false;
    cursorOf(scan).pos = 0;
    return true;
}

export fn zig_scan_analyze_next_tuple(
    scan: pg.Scan,
    oldest_xmin: pg.Xid,
    liverows: *f64,
    deadrows: *f64,
    slot: pg.Slot,
) bool {
    _ = oldest_xmin;
    const rel_id = pg.shim_rel_oid(pg.shim_scan_rel(scan));
    const cursor = cursorOf(scan);
    cursor.ensureRowsLoaded(rel_id);
    while (cursor.pos < cursor.rows.len) {
        const row = &cursor.rows[cursor.pos];
        cursor.pos += 1;
        if (row.header.xmax == 0) {
            liverows.* += 1;
            ffi.storeRow(slot, rel_id, row);
            return true;
        } else {
            deadrows.* += 1;
        }
    }
    return false;
}

// --- index build --------------------------------------------------------

export fn zig_index_build_range_scan(
    table_rel: pg.Relation,
    index_rel: pg.Relation,
    index_info: pg.IndexInfo,
    allow_sync: bool,
    anyvisible: bool,
    progress: bool,
    start_blockno: pg.BlockNumber,
    numblocks: pg.BlockNumber,
    callback: ?*anyopaque,
    callback_state: ?*anyopaque,
    scan: pg.Scan,
) f64 {
    _ = allow_sync;
    _ = anyvisible;
    _ = progress;
    _ = start_blockno;
    _ = numblocks;
    _ = scan;
    if (callback == null) return 0;

    const table_id = pg.shim_rel_oid(table_rel);
    const n_attrs: usize = @intCast(pg.shim_index_info_natts(index_info));
    const values = alloc.alloc(pg.Datum, n_attrs) catch pg.fail("sqlite_heap_zig: out of memory", .{});
    defer alloc.free(values);
    const isnull = alloc.alloc(bool, n_attrs) catch pg.fail("sqlite_heap_zig: out of memory", .{});
    defer alloc.free(isnull);

    var estate: pg.EState = null;
    var slot: pg.Slot = null;
    pg.shim_index_build_setup(table_rel, &estate, &slot);
    defer pg.shim_index_build_teardown(estate, slot);

    const rows = sqlite.selectAll(table_id);
    defer sqlite.freeRows(rows);

    var reltuples: f64 = 0;
    for (rows) |*row| {
        // Live rows only -- visibility is checked later, at index_fetch time.
        if (row.header.xmax != 0) continue;
        ffi.storeRow(slot, table_id, row);
        pg.shim_index_build_form_datum(index_info, slot, estate, values.ptr, isnull.ptr);
        const bo = ffi.rowidToBlockOff(row.header.rowid);
        pg.shim_index_build_emit(callback, index_rel, bo.blk, bo.off, values.ptr, isnull.ptr, callback_state);
        reltuples += 1;
    }
    return reltuples;
}

export fn zig_index_validate_scan(
    table_rel: pg.Relation,
    index_rel: pg.Relation,
    index_info: pg.IndexInfo,
    snapshot: pg.Snapshot,
    state: ?*anyopaque,
) void {
    _ = table_rel;
    _ = index_rel;
    _ = index_info;
    _ = snapshot;
    _ = state;
    // REINDEX CONCURRENTLY validate pass: `index_build_range_scan` already saw
    // every committed row, so there's nothing to do.
}

// --- misc / planner -----------------------------------------------------

export fn zig_relation_size(rel: pg.Relation, fork: c_int) u64 {
    _ = rel;
    // No real relfile: report the main fork as exactly one block (matching the
    // one logical block `scan_analyze_next_block` yields), every other fork as
    // empty.
    return if (fork == pg.MAIN_FORKNUM) pg.shim_blcksz() else 0;
}

export fn zig_relation_needs_toast_table(rel: pg.Relation) bool {
    _ = rel;
    return false;
}

export fn zig_relation_toast_am(rel: pg.Relation) pg.Oid {
    _ = rel;
    return 0; // InvalidOid
}

export fn zig_relation_fetch_toast_slice(
    toastrel: pg.Relation,
    valueid: pg.Oid,
    attrsize: i32,
    sliceoffset: i32,
    slicelength: i32,
    result: ?*anyopaque,
) void {
    _ = toastrel;
    _ = valueid;
    _ = attrsize;
    _ = sliceoffset;
    _ = slicelength;
    _ = result;
}

export fn zig_relation_estimate_size(
    rel: pg.Relation,
    attr_widths: ?*i32,
    pages: *pg.BlockNumber,
    tuples: *f64,
    allvisfrac: *f64,
) void {
    _ = attr_widths;
    const est = sqlite.estimateSize(pg.shim_rel_oid(rel));
    const p: pg.BlockNumber = @intCast(@max((est.bytes + 8191) / 8192, 1));
    pages.* = p;
    tuples.* = @floatFromInt(est.tuples);
    // No visibility map -- claim all-visible so index-only scans aren't penalized.
    allvisfrac.* = 1.0;
}

// --- bitmap / sample scan -----------------------------------------------

export fn zig_scan_bitmap_next_tuple(
    scan: pg.Scan,
    slot: pg.Slot,
    recheck: *bool,
    lossy_pages: *u64,
    exact_pages: *u64,
) bool {
    const cursor = cursorOf(scan);
    const snapshot = pg.shim_scan_snapshot(scan);
    const rel = pg.shim_scan_rel(scan);
    const rel_id = pg.shim_rel_oid(rel);

    while (true) {
        // Drain any remaining offsets from the current page first.
        while (cursor.bitmap_offset_pos < cursor.bitmap_offsets.items.len) {
            const off = cursor.bitmap_offsets.items[cursor.bitmap_offset_pos];
            cursor.bitmap_offset_pos += 1;
            const rowid = @as(i64, cursor.bitmap_blockno) * ffi.TIDS_PER_BLOCK + off;
            if (fetchOneIntoSlot(rel, rowid, snapshot, slot)) return true;
        }

        // Page exhausted -- pull the next one from the TID bitmap iterator.
        var page: pg.TbmPage = undefined;
        if (!pg.shim_tbm_next(scan, &page)) return false;

        recheck.* = page.recheck;
        if (page.lossy) {
            lossy_pages.* += 1;
        } else {
            exact_pages.* += 1;
        }
        cursor.bitmap_blockno = page.blockno;
        cursor.bitmap_offsets.clearRetainingCapacity();

        if (page.lossy) {
            // Lossy page: enumerate every rowid that maps into this block.
            cursor.ensureRowsLoaded(rel_id);
            for (cursor.rows) |row| {
                const bo = ffi.rowidToBlockOff(row.header.rowid);
                if (bo.blk == cursor.bitmap_blockno) {
                    cursor.bitmap_offsets.append(alloc, bo.off) catch
                        pg.fail("sqlite_heap_zig: out of memory", .{});
                }
            }
        } else {
            const noff: usize = @intCast(page.noffsets);
            cursor.bitmap_offsets.appendSlice(alloc, page.offsets[0..noff]) catch
                pg.fail("sqlite_heap_zig: out of memory", .{});
        }
        cursor.bitmap_offset_pos = 0;
    }
}

export fn zig_scan_sample_next_block(scan: pg.Scan, scanstate: ?*anyopaque) bool {
    _ = scanstate;
    // The whole table is one logical block: yield it once, then done.
    const cursor = cursorOf(scan);
    if (cursor.sample_block_consumed) return false;
    cursor.sample_block_consumed = true;
    cursor.pos = 0;
    return true;
}

export fn zig_scan_sample_next_tuple(scan: pg.Scan, scanstate: ?*anyopaque, slot: pg.Slot) bool {
    _ = scanstate;
    // Yields every live row: TABLESAMPLE returns the whole table rather than
    // the requested fraction -- imprecise, but never empty.
    const snapshot = pg.shim_scan_snapshot(scan);
    const rel_id = pg.shim_rel_oid(pg.shim_scan_rel(scan));
    const cursor = cursorOf(scan);
    cursor.ensureRowsLoaded(rel_id);
    while (cursor.pos < cursor.rows.len) {
        const row = &cursor.rows[cursor.pos];
        cursor.pos += 1;
        if (visibility.rowVisible(&row.header, snapshot)) {
            ffi.storeRow(slot, rel_id, row);
            return true;
        }
    }
    return false;
}
