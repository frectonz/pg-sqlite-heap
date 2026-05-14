//! Table Access Method: scan state, the ~43 `TableAmRoutine` callbacks, and
//! the routine table itself. Each callback wraps the raw pointers Postgres
//! hands it in `ffi::Rel` / `ffi::Slot` and delegates to a safe inner fn.

use crate::{ffi, sqlite, visibility};
use pgrx::pg_sys;
use pgrx::prelude::*;
use std::sync::OnceLock;

// --- Scan state ---

#[repr(C)]
struct SqliteScanState {
    rs_base: pg_sys::TableScanDescData,
    cursor: *mut SqliteCursor,
}

struct SqliteCursor {
    /// Whole relation, loaded lazily by `ensure_rows_loaded` — a seq/sample/
    /// analyze scan needs it, a bitmap-exact scan must not pay for it.
    rows: Vec<sqlite::StoredRow>,
    rows_loaded: bool,
    pos: usize,
    /// `scan_sample_next_block` models the table as one logical block.
    sample_block_consumed: bool,
    /// Offsets extracted from the current TBM page, and our position in them.
    bitmap_blockno: pg_sys::BlockNumber,
    bitmap_offsets: Vec<pg_sys::OffsetNumber>,
    bitmap_offset_pos: usize,
}

impl SqliteCursor {
    fn ensure_rows_loaded(&mut self, rel_id: u32) {
        if !self.rows_loaded {
            self.rows = sqlite::select_all(rel_id);
            self.rows_loaded = true;
        }
    }
}

impl SqliteScanState {
    fn alloc(
        rel: &ffi::Rel<'_>,
        snapshot: pg_sys::Snapshot,
        nkeys: ::core::ffi::c_int,
        key: *mut pg_sys::ScanKeyData,
        pscan: pg_sys::ParallelTableScanDesc,
        flags: u32,
    ) -> *mut SqliteScanState {
        let cursor = Box::into_raw(Box::new(SqliteCursor {
            rows: Vec::new(),
            rows_loaded: false,
            pos: 0,
            sample_block_consumed: false,
            bitmap_blockno: 0,
            bitmap_offsets: Vec::new(),
            bitmap_offset_pos: 0,
        }));
        unsafe {
            let scan = pg_sys::palloc0(std::mem::size_of::<Self>()) as *mut Self;
            (*scan).rs_base.rs_rd = rel.as_ptr();
            (*scan).rs_base.rs_snapshot = snapshot;
            (*scan).rs_base.rs_nkeys = nkeys;
            (*scan).rs_base.rs_key = key;
            (*scan).rs_base.rs_flags = flags;
            (*scan).rs_base.rs_parallel = pscan;
            (*scan).cursor = cursor;
            scan
        }
    }

    /// # Safety
    /// `desc` must come from a previous `alloc` and still be live.
    unsafe fn from_desc<'a>(desc: pg_sys::TableScanDesc) -> &'a mut SqliteScanState {
        unsafe { &mut *(desc as *mut SqliteScanState) }
    }

    fn rel(&self) -> ffi::Rel<'_> {
        unsafe { ffi::Rel::from_raw(self.rs_base.rs_rd) }
    }

    /// Unpack the relation and cursor together — they don't alias.
    fn split(&mut self) -> (ffi::Rel<'_>, &mut SqliteCursor) {
        let rel_ptr = self.rs_base.rs_rd;
        let cursor_ptr = self.cursor;
        unsafe { (ffi::Rel::from_raw(rel_ptr), &mut *cursor_ptr) }
    }

    /// # Safety
    /// `desc` must come from a previous `alloc` and still be live.
    unsafe fn free(desc: pg_sys::TableScanDesc) {
        unsafe {
            let s = desc as *mut Self;
            drop(Box::from_raw((*s).cursor));
            pg_sys::pfree(s as *mut _);
        }
    }
}

// --- TAM callbacks ---

#[pg_guard]
unsafe extern "C-unwind" fn slot_callbacks(
    _rel: pg_sys::Relation,
) -> *const pg_sys::TupleTableSlotOps {
    &raw const pg_sys::TTSOpsHeapTuple
}

#[pg_guard]
unsafe extern "C-unwind" fn parallelscan_estimate(rel: pg_sys::Relation) -> pg_sys::Size {
    unsafe { pg_sys::table_block_parallelscan_estimate(rel) }
}

#[pg_guard]
unsafe extern "C-unwind" fn parallelscan_initialize(
    rel: pg_sys::Relation,
    pscan: pg_sys::ParallelTableScanDesc,
) -> pg_sys::Size {
    unsafe { pg_sys::table_block_parallelscan_initialize(rel, pscan) }
}

#[pg_guard]
unsafe extern "C-unwind" fn parallelscan_reinitialize(
    rel: pg_sys::Relation,
    pscan: pg_sys::ParallelTableScanDesc,
) {
    unsafe { pg_sys::table_block_parallelscan_reinitialize(rel, pscan) }
}

// --- Sequential scan ---

#[pg_guard]
unsafe extern "C-unwind" fn scan_begin(
    rel: pg_sys::Relation,
    snapshot: pg_sys::Snapshot,
    nkeys: ::core::ffi::c_int,
    key: *mut pg_sys::ScanKeyData,
    pscan: pg_sys::ParallelTableScanDesc,
    flags: u32,
) -> pg_sys::TableScanDesc {
    let rel = unsafe { ffi::Rel::from_raw(rel) };
    SqliteScanState::alloc(&rel, snapshot, nkeys, key, pscan, flags) as pg_sys::TableScanDesc
}

#[pg_guard]
unsafe extern "C-unwind" fn scan_end(scan: pg_sys::TableScanDesc) {
    unsafe { SqliteScanState::free(scan) };
}

#[pg_guard]
unsafe extern "C-unwind" fn scan_rescan(
    scan: pg_sys::TableScanDesc,
    _key: *mut pg_sys::ScanKeyData,
    _set_params: bool,
    _allow_strat: bool,
    _allow_sync: bool,
    _allow_pagemode: bool,
) {
    let state = unsafe { SqliteScanState::from_desc(scan) };
    let (_rel, cursor) = state.split();
    cursor.pos = 0;
}

#[pg_guard]
unsafe extern "C-unwind" fn scan_getnextslot(
    scan: pg_sys::TableScanDesc,
    _direction: pg_sys::ScanDirection::Type,
    slot: *mut pg_sys::TupleTableSlot,
) -> bool {
    let state = unsafe { SqliteScanState::from_desc(scan) };
    let snapshot = state.rs_base.rs_snapshot;
    let mut slot = unsafe { ffi::Slot::from_raw(slot) };
    let (rel, cursor) = state.split();
    do_scan_getnext(cursor, snapshot, &rel, &mut slot)
}

fn do_scan_getnext(
    cursor: &mut SqliteCursor,
    snapshot: pg_sys::Snapshot,
    rel: &ffi::Rel<'_>,
    slot: &mut ffi::Slot<'_>,
) -> bool {
    slot.clear();
    cursor.ensure_rows_loaded(rel.oid_u32());
    while cursor.pos < cursor.rows.len() {
        let row = &cursor.rows[cursor.pos];
        cursor.pos += 1;
        if visibility::row_visible(&row.header, snapshot) {
            slot.store_row(rel, row);
            return true;
        }
    }
    false
}

#[pg_guard]
unsafe extern "C-unwind" fn scan_set_tidrange(
    scan: pg_sys::TableScanDesc,
    mintid: pg_sys::ItemPointer,
    maxtid: pg_sys::ItemPointer,
) {
    // Stash the bounds in the scan descriptor for scan_getnextslot_tidrange.
    let state = unsafe { SqliteScanState::from_desc(scan) };
    unsafe {
        state.rs_base.st.tidrange.rs_mintid = *mintid;
        state.rs_base.st.tidrange.rs_maxtid = *maxtid;
    }
    let (_rel, cursor) = state.split();
    cursor.pos = 0;
}

#[pg_guard]
unsafe extern "C-unwind" fn scan_getnextslot_tidrange(
    scan: pg_sys::TableScanDesc,
    _direction: pg_sys::ScanDirection::Type,
    slot: *mut pg_sys::TupleTableSlot,
) -> bool {
    let state = unsafe { SqliteScanState::from_desc(scan) };
    let snapshot = state.rs_base.rs_snapshot;
    let min_rowid = unsafe { ffi::tid_to_rowid(&raw const state.rs_base.st.tidrange.rs_mintid as *mut _) };
    let max_rowid = unsafe { ffi::tid_to_rowid(&raw const state.rs_base.st.tidrange.rs_maxtid as *mut _) };
    let mut slot = unsafe { ffi::Slot::from_raw(slot) };
    let (rel, cursor) = state.split();
    slot.clear();
    cursor.ensure_rows_loaded(rel.oid_u32());
    while cursor.pos < cursor.rows.len() {
        let row = &cursor.rows[cursor.pos];
        cursor.pos += 1;
        if row.rowid < min_rowid || row.rowid > max_rowid {
            continue;
        }
        if !visibility::row_visible(&row.header, snapshot) {
            continue;
        }
        slot.store_row(&rel, row);
        return true;
    }
    false
}

// --- Index access ---

#[pg_guard]
unsafe extern "C-unwind" fn index_fetch_begin(
    rel: pg_sys::Relation,
) -> *mut pg_sys::IndexFetchTableData {
    unsafe {
        let data = pg_sys::palloc0(std::mem::size_of::<pg_sys::IndexFetchTableData>())
            as *mut pg_sys::IndexFetchTableData;
        (*data).rel = rel;
        data
    }
}

#[pg_guard]
unsafe extern "C-unwind" fn index_fetch_reset(_data: *mut pg_sys::IndexFetchTableData) {}

#[pg_guard]
unsafe extern "C-unwind" fn index_fetch_end(data: *mut pg_sys::IndexFetchTableData) {
    unsafe { pg_sys::pfree(data as *mut _) }
}

#[pg_guard]
unsafe extern "C-unwind" fn index_fetch_tuple(
    scan: *mut pg_sys::IndexFetchTableData,
    tid: pg_sys::ItemPointer,
    snapshot: pg_sys::Snapshot,
    slot: *mut pg_sys::TupleTableSlot,
    call_again: *mut bool,
    all_dead: *mut bool,
) -> bool {
    unsafe {
        if !call_again.is_null() {
            *call_again = false;
        }
        if !all_dead.is_null() {
            *all_dead = false;
        }
    }
    let rel = unsafe { ffi::Rel::from_raw((*scan).rel) };
    let mut slot = unsafe { ffi::Slot::from_raw(slot) };
    let rowid = unsafe { ffi::tid_to_rowid(tid) };
    fetch_one_into_slot(&rel, rowid, snapshot, &mut slot)
}

fn fetch_one_into_slot(
    rel: &ffi::Rel<'_>,
    rowid: i64,
    snapshot: pg_sys::Snapshot,
    slot: &mut ffi::Slot<'_>,
) -> bool {
    sqlite::fetch_one_ref(rel.oid_u32(), rowid, |header, bytes| {
        if !visibility::row_visible(header, snapshot) {
            return false;
        }
        slot.store_parts(rel, header, bytes);
        true
    })
}

// --- Tuple lifecycle ---

#[pg_guard]
unsafe extern "C-unwind" fn tuple_fetch_row_version(
    rel: pg_sys::Relation,
    tid: pg_sys::ItemPointer,
    snapshot: pg_sys::Snapshot,
    slot: *mut pg_sys::TupleTableSlot,
) -> bool {
    let rel = unsafe { ffi::Rel::from_raw(rel) };
    let mut slot = unsafe { ffi::Slot::from_raw(slot) };
    let rowid = unsafe { ffi::tid_to_rowid(tid) };
    fetch_one_into_slot(&rel, rowid, snapshot, &mut slot)
}

#[pg_guard]
unsafe extern "C-unwind" fn tuple_tid_valid(
    scan: pg_sys::TableScanDesc,
    tid: pg_sys::ItemPointer,
) -> bool {
    let state = unsafe { SqliteScanState::from_desc(scan) };
    let rowid = unsafe { ffi::tid_to_rowid(tid) };
    sqlite::select_one(state.rel().oid_u32(), rowid).is_some()
}

#[pg_guard]
unsafe extern "C-unwind" fn tuple_get_latest_tid(
    _scan: pg_sys::TableScanDesc,
    _tid: pg_sys::ItemPointer,
) {
}

#[pg_guard]
unsafe extern "C-unwind" fn tuple_satisfies_snapshot(
    rel: pg_sys::Relation,
    slot: *mut pg_sys::TupleTableSlot,
    snapshot: pg_sys::Snapshot,
) -> bool {
    let rel = unsafe { ffi::Rel::from_raw(rel) };
    // The slot's `tts_tid` was set when we stored the row; look it back up
    // and re-check visibility under the current snapshot.
    let rowid = unsafe { ffi::tid_to_rowid(&raw mut (*slot).tts_tid) };
    match sqlite::select_one(rel.oid_u32(), rowid) {
        Some(row) => visibility::row_visible(&row, snapshot),
        None => false,
    }
}

#[pg_guard]
unsafe extern "C-unwind" fn index_delete_tuples(
    rel: pg_sys::Relation,
    delstate: *mut pg_sys::TM_IndexDeleteOp,
) -> pg_sys::TransactionId {
    // btree (notably bottom-up deletion) asks which of these index TIDs point
    // to reclaimable rows. Contract: set `status[id].knowndeletable` per entry;
    // if *nothing* is deletable, shrink `ndeltids` to 0 — else btree's
    // `_bt_delitems_delete` hits `Assert(ndeletable > 0 || nupdatable > 0)`.
    let rel = unsafe { ffi::Rel::from_raw(rel) };
    let rel_id = rel.oid_u32();
    let op = unsafe { &mut *delstate };
    let n = op.ndeltids as usize;
    if n == 0 {
        return pg_sys::TransactionId::INVALID;
    }
    let deltids = unsafe { std::slice::from_raw_parts(op.deltids, n) };
    let status = unsafe { std::slice::from_raw_parts_mut(op.status, n) };

    // A row version is reclaimable iff its `xmax` is committed and older than
    // every still-running snapshot — the same bar as VACUUM.
    let oldest = unsafe { pg_sys::GetOldestNonRemovableTransactionId(rel.as_ptr()) };
    let mut latest_removed = pg_sys::TransactionId::INVALID;
    let mut any_deletable = false;

    // One `WHERE rowid IN (…)` query for the whole page, not a query per TID.
    let rowids: Vec<i64> = deltids
        .iter()
        .map(|e| unsafe { ffi::tid_to_rowid(&e.tid as *const _ as *mut _) })
        .collect();
    let xmax_map = sqlite::select_xmax_batch(rel_id, &rowids);

    for (entry, &rowid) in deltids.iter().zip(&rowids) {
        let status_idx = entry.id as usize;
        // `None` ⇒ row physically gone already (VACUUMed) ⇒ index entry stale.
        let xmax = xmax_map.get(&rowid).copied();
        let deletable = match xmax {
            None => true,
            Some(0) => false, // still live
            Some(xmax) => {
                let xmax_t = pg_sys::TransactionId::from(xmax);
                let committed = visibility::did_commit(xmax);
                let old = unsafe { pg_sys::TransactionIdPrecedes(xmax_t, oldest) };
                committed && old
            }
        };
        if deletable {
            status[status_idx].knowndeletable = true;
            any_deletable = true;
            // Track the newest reclaimed xid for the recovery-conflict horizon.
            if let Some(xmax) = xmax {
                let xmax_t = pg_sys::TransactionId::from(xmax);
                if xmax != 0 && unsafe { pg_sys::TransactionIdFollows(xmax_t, latest_removed) } {
                    latest_removed = xmax_t;
                }
            }
        }
    }

    if !any_deletable {
        // Nothing to reclaim — tell btree so via an empty array; it returns
        // early instead of asserting.
        op.ndeltids = 0;
    }
    latest_removed
}

#[pg_guard]
unsafe extern "C-unwind" fn tuple_insert(
    rel: pg_sys::Relation,
    slot: *mut pg_sys::TupleTableSlot,
    cid: pg_sys::CommandId,
    _options: ::core::ffi::c_int,
    _bistate: *mut pg_sys::BulkInsertStateData,
) {
    let rel = unsafe { ffi::Rel::from_raw(rel) };
    let mut slot = unsafe { ffi::Slot::from_raw(slot) };
    do_tuple_insert(&rel, &mut slot, cid);
}

fn do_tuple_insert(rel: &ffi::Rel<'_>, slot: &mut ffi::Slot<'_>, cid: pg_sys::CommandId) {
    let tup = slot.copy_heap_tuple();
    let xid = current_xid_u32();
    let rowid = sqlite::insert(rel.oid_u32(), xid, cid, tup.bytes());
    slot.set_inserted_tid(rel, rowid);
}

fn current_xid_u32() -> u32 {
    u32::from(unsafe { pg_sys::GetCurrentTransactionId() })
}

#[pg_guard]
unsafe extern "C-unwind" fn tuple_insert_speculative(
    rel: pg_sys::Relation,
    slot: *mut pg_sys::TupleTableSlot,
    cid: pg_sys::CommandId,
    _options: ::core::ffi::c_int,
    _bistate: *mut pg_sys::BulkInsertStateData,
    _spec_token: u32,
) {
    // Insert like any other row; `tuple_complete_speculative` retracts it if
    // the speculation lost.
    let rel = unsafe { ffi::Rel::from_raw(rel) };
    let mut slot = unsafe { ffi::Slot::from_raw(slot) };
    do_tuple_insert(&rel, &mut slot, cid);
}

#[pg_guard]
unsafe extern "C-unwind" fn tuple_complete_speculative(
    rel: pg_sys::Relation,
    slot: *mut pg_sys::TupleTableSlot,
    _spec_token: u32,
    succeeded: bool,
) {
    if succeeded {
        return;
    }
    // Speculation lost: physically remove the speculative row.
    let rel = unsafe { ffi::Rel::from_raw(rel) };
    let rowid = unsafe { ffi::tid_to_rowid(&raw mut (*slot).tts_tid) };
    sqlite::physical_delete(rel.oid_u32(), rowid);
}

#[pg_guard]
unsafe extern "C-unwind" fn multi_insert(
    rel: pg_sys::Relation,
    slots: *mut *mut pg_sys::TupleTableSlot,
    nslots: ::core::ffi::c_int,
    cid: pg_sys::CommandId,
    _options: ::core::ffi::c_int,
    _bistate: *mut pg_sys::BulkInsertStateData,
) {
    let rel = unsafe { ffi::Rel::from_raw(rel) };
    let slots_slice = unsafe { std::slice::from_raw_parts(slots, nslots as usize) };
    if slots_slice.is_empty() {
        return;
    }

    // Materialize every slot once, then one batched insert rather than N
    // trips through the per-row path.
    let xid = current_xid_u32();
    let owned: Vec<ffi::OwnedHeapTuple> = slots_slice
        .iter()
        .map(|&s| unsafe { ffi::Slot::from_raw(s) }.copy_heap_tuple())
        .collect();
    let byte_slices: Vec<&[u8]> = owned.iter().map(|t| t.bytes()).collect();
    let rowids = sqlite::insert_batch(rel.oid_u32(), xid, cid, &byte_slices);

    // Stamp the assigned TID back so RETURNING / triggers see it.
    for (&slot_ptr, rowid) in slots_slice.iter().zip(rowids) {
        let mut slot = unsafe { ffi::Slot::from_raw(slot_ptr) };
        slot.set_inserted_tid(&rel, rowid);
    }
}

#[pg_guard]
unsafe extern "C-unwind" fn tuple_delete(
    rel: pg_sys::Relation,
    tid: pg_sys::ItemPointer,
    cid: pg_sys::CommandId,
    _snapshot: pg_sys::Snapshot,
    _crosscheck: pg_sys::Snapshot,
    _wait: bool,
    _tmfd: *mut pg_sys::TM_FailureData,
    _changing_part: bool,
) -> pg_sys::TM_Result::Type {
    let rel = unsafe { ffi::Rel::from_raw(rel) };
    let rowid = unsafe { ffi::tid_to_rowid(tid) };
    let xid = current_xid_u32();
    if sqlite::set_xmax(rel.oid_u32(), rowid, xid, cid) == 0 {
        pg_sys::TM_Result::TM_Deleted
    } else {
        pg_sys::TM_Result::TM_Ok
    }
}

#[pg_guard]
unsafe extern "C-unwind" fn tuple_update(
    rel: pg_sys::Relation,
    otid: pg_sys::ItemPointer,
    slot: *mut pg_sys::TupleTableSlot,
    cid: pg_sys::CommandId,
    _snapshot: pg_sys::Snapshot,
    _crosscheck: pg_sys::Snapshot,
    _wait: bool,
    _tmfd: *mut pg_sys::TM_FailureData,
    _lockmode: *mut pg_sys::LockTupleMode::Type,
    update_indexes: *mut pg_sys::TU_UpdateIndexes::Type,
) -> pg_sys::TM_Result::Type {
    let rel = unsafe { ffi::Rel::from_raw(rel) };
    let mut slot = unsafe { ffi::Slot::from_raw(slot) };
    let old_rowid = unsafe { ffi::tid_to_rowid(otid) };
    let xid = current_xid_u32();
    let tup = slot.copy_heap_tuple();

    // MVCC update: stamp the old row dead, insert the new version at a fresh
    // TID, and have Postgres update every index to point at it.
    let new_rowid =
        sqlite::update_row(rel.oid_u32(), old_rowid, xid, cid, tup.bytes());
    slot.set_inserted_tid(&rel, new_rowid);
    if !update_indexes.is_null() {
        unsafe { *update_indexes = pg_sys::TU_UpdateIndexes::TU_All };
    }
    pg_sys::TM_Result::TM_Ok
}

#[pg_guard]
unsafe extern "C-unwind" fn tuple_lock(
    rel: pg_sys::Relation,
    tid: pg_sys::ItemPointer,
    snapshot: pg_sys::Snapshot,
    slot: *mut pg_sys::TupleTableSlot,
    _cid: pg_sys::CommandId,
    _mode: pg_sys::LockTupleMode::Type,
    _wait_policy: pg_sys::LockWaitPolicy::Type,
    _flags: u8,
    _tmfd: *mut pg_sys::TM_FailureData,
) -> pg_sys::TM_Result::Type {
    // Minimal SELECT FOR UPDATE: re-fetch the row. We hold no real row lock
    // (that needs a lock table) — best-effort under multi-backend contention.
    let rel = unsafe { ffi::Rel::from_raw(rel) };
    let mut slot = unsafe { ffi::Slot::from_raw(slot) };
    let rowid = unsafe { ffi::tid_to_rowid(tid) };
    if fetch_one_into_slot(&rel, rowid, snapshot, &mut slot) {
        pg_sys::TM_Result::TM_Ok
    } else {
        pg_sys::TM_Result::TM_Deleted
    }
}

#[pg_guard]
unsafe extern "C-unwind" fn finish_bulk_insert(
    _rel: pg_sys::Relation,
    _options: ::core::ffi::c_int,
) {
}

// --- Relation lifecycle ---

#[pg_guard]
unsafe extern "C-unwind" fn relation_set_new_filelocator(
    rel: pg_sys::Relation,
    _newrlocator: *const pg_sys::RelFileLocator,
    _persistence: ::core::ffi::c_char,
    _freeze_xid: *mut pg_sys::TransactionId,
    _minmulti: *mut pg_sys::MultiXactId,
) {
    let rel = unsafe { ffi::Rel::from_raw(rel) };
    sqlite::reset(rel.oid_u32());
}

#[pg_guard]
unsafe extern "C-unwind" fn relation_nontransactional_truncate(rel: pg_sys::Relation) {
    // The fast TRUNCATE path (table created in this same transaction).
    let rel = unsafe { ffi::Rel::from_raw(rel) };
    sqlite::reset(rel.oid_u32());
}

#[pg_guard]
unsafe extern "C-unwind" fn relation_copy_data(
    _rel: pg_sys::Relation,
    _newrlocator: *const pg_sys::RelFileLocator,
) {
    // ALTER TABLE SET TABLESPACE: our files are keyed by relation OID (stable
    // across the move), so the data stays put — nothing to do here.
}

#[pg_guard]
unsafe extern "C-unwind" fn relation_copy_for_cluster(
    old_table: pg_sys::Relation,
    new_table: pg_sys::Relation,
    _old_index: pg_sys::Relation,
    _use_sort: bool,
    _oldest_xmin: pg_sys::TransactionId,
    _xid_cutoff: *mut pg_sys::TransactionId,
    _multi_cutoff: *mut pg_sys::MultiXactId,
    num_tuples: *mut f64,
    tups_vacuumed: *mut f64,
    tups_recently_dead: *mut f64,
) {
    // CLUSTER / VACUUM FULL: stream every live row from old into new (whose
    // storage was created fresh by relation_set_new_filelocator).
    let old = unsafe { ffi::Rel::from_raw(old_table) };
    let new = unsafe { ffi::Rel::from_raw(new_table) };
    let xid = current_xid_u32();
    let cid: pg_sys::CommandId = unsafe { pg_sys::GetCurrentCommandId(true) };

    let rows = sqlite::select_all(old.oid_u32());
    let mut live = 0.0f64;
    let mut dead = 0.0f64;
    for row in &rows {
        if row.xmax != 0 {
            dead += 1.0;
            continue;
        }
        sqlite::insert(new.oid_u32(), xid, cid, &row.tuple);
        live += 1.0;
    }
    unsafe {
        *num_tuples = live;
        *tups_vacuumed = dead;
        *tups_recently_dead = 0.0;
    }
}

#[pg_guard]
unsafe extern "C-unwind" fn relation_vacuum(
    rel: pg_sys::Relation,
    _params: *mut pg_sys::VacuumParams,
    _bstrategy: pg_sys::BufferAccessStrategy,
) {
    let rel = unsafe { ffi::Rel::from_raw(rel) };
    let oldest =
        u32::from(unsafe { pg_sys::GetOldestNonRemovableTransactionId(rel.as_ptr()) });
    sqlite::vacuum_dead(rel.oid_u32(), oldest);
}

#[pg_guard]
unsafe extern "C-unwind" fn scan_analyze_next_block(
    scan: pg_sys::TableScanDesc,
    stream: *mut pg_sys::ReadStream,
) -> bool {
    // The table is one logical block. We still must *advance* the ReadStream
    // — `read_stream_next_block` drives the sampler counter `acquire_sample_rows`
    // divides by, with no buffer I/O. Skipping it left that counter 0, so
    // ANALYZE extrapolated 0 rows and `n_distinct` came out `-Infinity`.
    // `strategy` is an out-parameter: it must point at a real slot, not null
    // (passing null segfaults).
    let mut strategy: pg_sys::BufferAccessStrategy = std::ptr::null_mut();
    let blk = unsafe { pg_sys::read_stream_next_block(stream, &mut strategy) };
    if blk == pg_sys::InvalidBlockNumber {
        return false;
    }
    let state = unsafe { SqliteScanState::from_desc(scan) };
    let (_rel, cursor) = state.split();
    cursor.pos = 0;
    true
}

#[pg_guard]
unsafe extern "C-unwind" fn scan_analyze_next_tuple(
    scan: pg_sys::TableScanDesc,
    _oldest_xmin: pg_sys::TransactionId,
    liverows: *mut f64,
    deadrows: *mut f64,
    slot: *mut pg_sys::TupleTableSlot,
) -> bool {
    let state = unsafe { SqliteScanState::from_desc(scan) };
    let mut slot = unsafe { ffi::Slot::from_raw(slot) };
    let (rel, cursor) = state.split();
    cursor.ensure_rows_loaded(rel.oid_u32());
    while cursor.pos < cursor.rows.len() {
        let row = &cursor.rows[cursor.pos];
        cursor.pos += 1;
        if row.xmax == 0 {
            unsafe { *liverows += 1.0 };
            slot.store_row(&rel, row);
            return true;
        } else {
            unsafe { *deadrows += 1.0 };
        }
    }
    false
}

// --- Index build ---

#[pg_guard]
unsafe extern "C-unwind" fn index_build_range_scan(
    table_rel: pg_sys::Relation,
    index_rel: pg_sys::Relation,
    index_info: *mut pg_sys::IndexInfo,
    _allow_sync: bool,
    _anyvisible: bool,
    _progress: bool,
    _start_blockno: pg_sys::BlockNumber,
    _numblocks: pg_sys::BlockNumber,
    callback: pg_sys::IndexBuildCallback,
    callback_state: *mut ::core::ffi::c_void,
    _scan: pg_sys::TableScanDesc,
) -> f64 {
    let Some(cb) = callback else { return 0.0 };
    let table = unsafe { ffi::Rel::from_raw(table_rel) };
    let index = unsafe { ffi::Rel::from_raw(index_rel) };
    build_index(&table, &index, index_info, cb, callback_state)
}

fn build_index(
    table: &ffi::Rel<'_>,
    index: &ffi::Rel<'_>,
    index_info: *mut pg_sys::IndexInfo,
    cb: unsafe extern "C-unwind" fn(
        pg_sys::Relation,
        pg_sys::ItemPointer,
        *mut pg_sys::Datum,
        *mut bool,
        bool,
        *mut ::core::ffi::c_void,
    ),
    callback_state: *mut ::core::ffi::c_void,
) -> f64 {
    let n_index_attrs = unsafe { (*index_info).ii_NumIndexAttrs } as usize;
    let mut values: Vec<pg_sys::Datum> = vec![pg_sys::Datum::from(0usize); n_index_attrs];
    let mut isnull: Vec<bool> = vec![false; n_index_attrs];

    let estate = unsafe { pg_sys::CreateExecutorState() };
    let econtext = unsafe { pg_sys::MakePerTupleExprContext(estate) };

    let slot_ptr = unsafe {
        pg_sys::MakeSingleTupleTableSlot(table.tuple_desc(), &raw const pg_sys::TTSOpsHeapTuple)
    };
    unsafe { (*econtext).ecxt_scantuple = slot_ptr };
    let mut slot = unsafe { ffi::Slot::from_raw(slot_ptr) };

    let rows = sqlite::select_all(table.oid_u32());
    let mut reltuples = 0.0f64;

    for row in &rows {
        // Live rows only — visibility is checked later, at index_fetch time.
        if row.xmax != 0 {
            continue;
        }
        slot.store_row(table, row);

        let mut tid = pg_sys::ItemPointerData::default();
        ffi::rowid_to_tid(row.rowid, &mut tid);

        unsafe {
            pg_sys::FormIndexDatum(
                index_info,
                slot.as_ptr(),
                estate,
                values.as_mut_ptr(),
                isnull.as_mut_ptr(),
            );
            cb(
                index.as_ptr(),
                &mut tid,
                values.as_mut_ptr(),
                isnull.as_mut_ptr(),
                true,
                callback_state,
            );
        }

        reltuples += 1.0;
    }

    unsafe {
        pg_sys::ExecDropSingleTupleTableSlot(slot_ptr);
        pg_sys::FreeExecutorState(estate);
    }

    reltuples
}

#[pg_guard]
unsafe extern "C-unwind" fn index_validate_scan(
    _table_rel: pg_sys::Relation,
    _index_rel: pg_sys::Relation,
    _index_info: *mut pg_sys::IndexInfo,
    _snapshot: pg_sys::Snapshot,
    _state: *mut pg_sys::ValidateIndexState,
) {
    // REINDEX CONCURRENTLY validate pass: `index_build_range_scan` already saw
    // every committed row, so there's nothing to do. (Limitation: multi-writer
    // REINDEX CONCURRENTLY may miss rows committed mid-build.)
}

#[pg_guard]
unsafe extern "C-unwind" fn relation_size(
    _rel: pg_sys::Relation,
    fork: pg_sys::ForkNumber::Type,
) -> u64 {
    // No real relfile: report the main fork as exactly one block (matching
    // the one logical block `scan_analyze_next_block` yields, so ANALYZE's
    // row-count maths works out), every other fork as empty.
    if fork == pg_sys::ForkNumber::MAIN_FORKNUM {
        pg_sys::BLCKSZ as u64
    } else {
        0
    }
}

#[pg_guard]
unsafe extern "C-unwind" fn relation_needs_toast_table(_rel: pg_sys::Relation) -> bool {
    false
}

#[pg_guard]
unsafe extern "C-unwind" fn relation_toast_am(_rel: pg_sys::Relation) -> pg_sys::Oid {
    pg_sys::Oid::INVALID
}

#[pg_guard]
unsafe extern "C-unwind" fn relation_fetch_toast_slice(
    _toastrel: pg_sys::Relation,
    _valueid: pg_sys::Oid,
    _attrsize: i32,
    _sliceoffset: i32,
    _slicelength: i32,
    _result: *mut pg_sys::varlena,
) {
}

#[pg_guard]
unsafe extern "C-unwind" fn relation_estimate_size(
    rel: pg_sys::Relation,
    _attr_widths: *mut i32,
    pages: *mut pg_sys::BlockNumber,
    tuples: *mut f64,
    allvisfrac: *mut f64,
) {
    let rel = unsafe { ffi::Rel::from_raw(rel) };
    let oid = rel.oid_u32();
    let (bytes, t) = sqlite::estimate_size(oid);
    let p = (bytes.div_ceil(8192)).max(1) as pg_sys::BlockNumber;
    unsafe {
        *pages = p;
        *tuples = t as f64;
        // No visibility map — claim all-visible so index-only scans aren't penalized.
        *allvisfrac = 1.0;
    }
}

#[pg_guard]
unsafe extern "C-unwind" fn scan_bitmap_next_tuple(
    scan: pg_sys::TableScanDesc,
    slot: *mut pg_sys::TupleTableSlot,
    recheck: *mut bool,
    lossy_pages: *mut u64,
    exact_pages: *mut u64,
) -> bool {
    /// Maximum tuples per Postgres page (matches `MaxHeapTuplesPerPage`).
    const MAX_OFFSETS: u32 = 1024;

    let state = unsafe { SqliteScanState::from_desc(scan) };
    let snapshot = state.rs_base.rs_snapshot;
    let rel_ptr: pg_sys::Relation = state.rs_base.rs_rd;
    let tbm_iter: *mut pg_sys::TBMIterator =
        &raw mut state.rs_base.st.rs_tbmiterator;
    let cursor = unsafe { &mut *state.cursor };
    let rel = unsafe { ffi::Rel::from_raw(rel_ptr) };
    let mut slot = unsafe { ffi::Slot::from_raw(slot) };

    loop {
        // Drain any remaining offsets from the current page first.
        while cursor.bitmap_offset_pos < cursor.bitmap_offsets.len() {
            let off = cursor.bitmap_offsets[cursor.bitmap_offset_pos];
            cursor.bitmap_offset_pos += 1;
            let mut tid = pg_sys::ItemPointerData::default();
            pgrx::itemptr::item_pointer_set_all(&mut tid, cursor.bitmap_blockno, off);
            let rowid = unsafe { ffi::tid_to_rowid(&mut tid) };
            if fetch_one_into_slot(&rel, rowid, snapshot, &mut slot) {
                return true;
            }
        }

        // Page exhausted — pull the next one from the TID bitmap iterator.
        let mut result = pg_sys::TBMIterateResult::default();
        let has_more = unsafe { pg_sys::tbm_iterate(tbm_iter, &mut result) };
        if !has_more {
            return false;
        }
        unsafe {
            *recheck = result.recheck;
            if result.lossy {
                *lossy_pages += 1;
            } else {
                *exact_pages += 1;
            }
        }
        cursor.bitmap_blockno = result.blockno;

        if result.lossy {
            // Lossy page: enumerate every rowid that maps into this block.
            cursor.ensure_rows_loaded(rel.oid_u32());
            cursor.bitmap_offsets.clear();
            for row in &cursor.rows {
                let mut tid = pg_sys::ItemPointerData::default();
                ffi::rowid_to_tid(row.rowid, &mut tid);
                let blk = unsafe { pgrx::itemptr::item_pointer_get_block_number(&tid) };
                let off = unsafe { pgrx::itemptr::item_pointer_get_offset_number(&tid) };
                if blk == cursor.bitmap_blockno {
                    cursor.bitmap_offsets.push(off);
                }
            }
        } else {
            cursor.bitmap_offsets.resize(MAX_OFFSETS as usize, 0);
            let n = unsafe {
                pg_sys::tbm_extract_page_tuple(
                    &mut result,
                    cursor.bitmap_offsets.as_mut_ptr(),
                    MAX_OFFSETS,
                )
            };
            cursor.bitmap_offsets.truncate(n as usize);
        }
        cursor.bitmap_offset_pos = 0;
    }
}

#[pg_guard]
unsafe extern "C-unwind" fn scan_sample_next_block(
    scan: pg_sys::TableScanDesc,
    _scanstate: *mut pg_sys::SampleScanState,
) -> bool {
    // The whole table is one logical block: yield it once, then done.
    let state = unsafe { SqliteScanState::from_desc(scan) };
    let (_rel, cursor) = state.split();
    if cursor.sample_block_consumed {
        false
    } else {
        cursor.sample_block_consumed = true;
        cursor.pos = 0;
        true
    }
}

#[pg_guard]
unsafe extern "C-unwind" fn scan_sample_next_tuple(
    scan: pg_sys::TableScanDesc,
    _scanstate: *mut pg_sys::SampleScanState,
    slot: *mut pg_sys::TupleTableSlot,
) -> bool {
    // Yields every live row: TABLESAMPLE returns the whole table rather than
    // the requested fraction — imprecise, but never empty.
    let state = unsafe { SqliteScanState::from_desc(scan) };
    let snapshot = state.rs_base.rs_snapshot;
    let mut slot = unsafe { ffi::Slot::from_raw(slot) };
    let (rel, cursor) = state.split();
    cursor.ensure_rows_loaded(rel.oid_u32());
    while cursor.pos < cursor.rows.len() {
        let row = &cursor.rows[cursor.pos];
        cursor.pos += 1;
        if visibility::row_visible(&row.header, snapshot) {
            slot.store_row(&rel, row);
            return true;
        }
    }
    false
}

// --- TableAmRoutine wiring ---

static AM_ROUTINE: OnceLock<pg_sys::TableAmRoutine> = OnceLock::new();

pub(crate) fn am_routine() -> &'static pg_sys::TableAmRoutine {
    AM_ROUTINE.get_or_init(|| pg_sys::TableAmRoutine {
        type_: pg_sys::NodeTag::T_TableAmRoutine,
        slot_callbacks: Some(slot_callbacks),

        scan_begin: Some(scan_begin),
        scan_end: Some(scan_end),
        scan_rescan: Some(scan_rescan),
        scan_getnextslot: Some(scan_getnextslot),
        scan_set_tidrange: Some(scan_set_tidrange),
        scan_getnextslot_tidrange: Some(scan_getnextslot_tidrange),

        parallelscan_estimate: Some(parallelscan_estimate),
        parallelscan_initialize: Some(parallelscan_initialize),
        parallelscan_reinitialize: Some(parallelscan_reinitialize),

        index_fetch_begin: Some(index_fetch_begin),
        index_fetch_reset: Some(index_fetch_reset),
        index_fetch_end: Some(index_fetch_end),
        index_fetch_tuple: Some(index_fetch_tuple),

        tuple_fetch_row_version: Some(tuple_fetch_row_version),
        tuple_tid_valid: Some(tuple_tid_valid),
        tuple_get_latest_tid: Some(tuple_get_latest_tid),
        tuple_satisfies_snapshot: Some(tuple_satisfies_snapshot),
        index_delete_tuples: Some(index_delete_tuples),

        tuple_insert: Some(tuple_insert),
        tuple_insert_speculative: Some(tuple_insert_speculative),
        tuple_complete_speculative: Some(tuple_complete_speculative),
        multi_insert: Some(multi_insert),
        tuple_delete: Some(tuple_delete),
        tuple_update: Some(tuple_update),
        tuple_lock: Some(tuple_lock),
        finish_bulk_insert: Some(finish_bulk_insert),

        relation_set_new_filelocator: Some(relation_set_new_filelocator),
        relation_nontransactional_truncate: Some(relation_nontransactional_truncate),
        relation_copy_data: Some(relation_copy_data),
        relation_copy_for_cluster: Some(relation_copy_for_cluster),
        relation_vacuum: Some(relation_vacuum),

        scan_analyze_next_block: Some(scan_analyze_next_block),
        scan_analyze_next_tuple: Some(scan_analyze_next_tuple),
        index_build_range_scan: Some(index_build_range_scan),
        index_validate_scan: Some(index_validate_scan),

        relation_size: Some(relation_size),
        relation_needs_toast_table: Some(relation_needs_toast_table),
        relation_toast_am: Some(relation_toast_am),
        relation_fetch_toast_slice: Some(relation_fetch_toast_slice),
        relation_estimate_size: Some(relation_estimate_size),

        scan_bitmap_next_tuple: Some(scan_bitmap_next_tuple),
        scan_sample_next_block: Some(scan_sample_next_block),
        scan_sample_next_tuple: Some(scan_sample_next_tuple),
    })
}
