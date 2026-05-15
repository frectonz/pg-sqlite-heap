//! HeapTuple / slot / TID marshalling -- the Zig port of `ffi.rs`.
//!
//! The heavy lifting (allocating the HeapTuple, overlaying the MVCC header,
//! storing into the slot) happens in the C shim; this module is just the
//! rowid <-> TID arithmetic and thin call wrappers.

const pg = @import("pg.zig");
const sqlite = @import("sqlite.zig");
const StoredHeader = sqlite.StoredHeader;
const StoredRow = sqlite.StoredRow;

/// Rows per logical "block" when packing a SQLite rowid into a Postgres TID
/// `(block, offset)`. Must stay under `MaxHeapTuplesPerPage` -- the bound
/// PostgreSQL validates index/bitmap-scan offsets against; a naive rowid->TID
/// cast overflows it once a table passes a few hundred rows.
pub const TIDS_PER_BLOCK: i64 = 256;

pub const BlockOff = struct {
    blk: pg.BlockNumber,
    off: pg.OffsetNumber,
};

/// Decode a PostgreSQL `ItemPointer` to a SQLite rowid.
pub fn tidToRowid(tid: pg.ItemPointer) i64 {
    const blk: i64 = pg.shim_itemptr_block(tid);
    const off: i64 = pg.shim_itemptr_offset(tid);
    return blk * TIDS_PER_BLOCK + off;
}

/// Encode a SQLite rowid (1-based) into a `(block, offset)` pair.
pub fn rowidToBlockOff(rowid: i64) BlockOff {
    const zero_based = rowid - 1;
    return .{
        .blk = @intCast(@divFloor(zero_based, TIDS_PER_BLOCK)),
        .off = @intCast(@mod(zero_based, TIDS_PER_BLOCK) + 1),
    };
}

/// Store a `StoredRow` into the slot.
pub fn storeRow(slot: pg.Slot, rel_oid: u32, row: *const StoredRow) void {
    storeParts(slot, rel_oid, &row.header, row.tuple);
}

/// Store a row from a header + borrowed tuple bytes. The shim overlays the
/// xmin/xmax/cmin onto the HeapTupleHeader -- PostgreSQL internals (btree
/// unique-check, EvalPlanQual) read those fields directly.
pub fn storeParts(slot: pg.Slot, rel_oid: u32, header: *const StoredHeader, bytes: []const u8) void {
    const bo = rowidToBlockOff(header.rowid);
    const tup = pg.shim_build_heap_tuple(
        rel_oid,
        bo.blk,
        bo.off,
        bytes.ptr,
        @intCast(bytes.len),
        header.xmin,
        header.xmax,
        header.cmin,
    );
    pg.shim_slot_store_tuple(slot, tup);
}

/// Stamp `tts_tableOid` + `tts_tid` after a successful insert/update.
pub fn setInsertedTid(slot: pg.Slot, rel_oid: u32, rowid: i64) void {
    const bo = rowidToBlockOff(rowid);
    pg.shim_slot_set_tid(slot, rel_oid, bo.blk, bo.off);
}

/// An owned, palloc'd HeapTuple materialized from a slot. Freed via `deinit`.
pub const OwnedHeapTuple = struct {
    tup: pg.HeapTuple,

    pub fn bytes(self: OwnedHeapTuple) []const u8 {
        var len: u32 = 0;
        const ptr = pg.shim_heaptuple_bytes(self.tup, &len);
        return @as([*]const u8, @ptrCast(ptr.?))[0..len];
    }

    pub fn deinit(self: OwnedHeapTuple) void {
        pg.shim_heap_freetuple(self.tup);
    }
};

/// Materialize the slot's current contents as an owned palloc'd tuple.
pub fn copyHeapTuple(slot: pg.Slot) OwnedHeapTuple {
    return .{ .tup = pg.shim_slot_copy_heaptuple(slot) };
}
