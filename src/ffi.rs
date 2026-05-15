use pgrx::pg_sys;
use crate::raw_pg;

/// Borrowed view of a Postgres `RelationData`.
#[derive(Copy, Clone)]
pub struct Rel<'a>(&'a pg_sys::RelationData);

impl<'a> Rel<'a> {
    /// # Safety
    /// `rel` must point to a valid `RelationData` for at least `'a`, and
    /// no other code may mutate it during that lifetime.
    pub unsafe fn from_raw(rel: pg_sys::Relation) -> Self {
        debug_assert!(!rel.is_null(), "Relation must be non-null");
        Self(unsafe { &*rel })
    }

    pub fn oid(&self) -> pg_sys::Oid {
        self.0.rd_id
    }

    pub fn oid_u32(&self) -> u32 {
        self.0.rd_id.to_u32()
    }

    pub fn tuple_desc(&self) -> pg_sys::TupleDesc {
        self.0.rd_att
    }

    /// Recover the raw pointer for FFI calls that need it.
    pub fn as_ptr(&self) -> pg_sys::Relation {
        (self.0 as *const pg_sys::RelationData) as pg_sys::Relation
    }
}

/// Borrowed view of a `TupleTableSlot`.
pub struct Slot<'a>(&'a mut pg_sys::TupleTableSlot);

impl<'a> Slot<'a> {
    /// # Safety
    /// `slot` must point to a valid `TupleTableSlot` for `'a`, and we must
    /// have unique access for that lifetime (no aliased writers).
    pub unsafe fn from_raw(slot: *mut pg_sys::TupleTableSlot) -> Self {
        debug_assert!(!slot.is_null(), "Slot must be non-null");
        Self(unsafe { &mut *slot })
    }

    pub fn clear(&mut self) {
        unsafe { raw_pg::ExecClearTuple(self.0) };
    }

    /// Materialize the slot's current contents as an owned palloc'd tuple.
    /// The returned `OwnedHeapTuple` frees itself on drop.
    pub fn copy_heap_tuple(&mut self) -> OwnedHeapTuple {
        OwnedHeapTuple(unsafe { raw_pg::ExecCopySlotHeapTuple(self.0) })
    }

    /// Store a `StoredRow` into the slot.
    pub fn store_row(&mut self, rel: &Rel<'_>, row: &crate::sqlite::StoredRow) {
        let tup = build_heap_tuple_from_parts(rel, &row.header, &row.tuple);
        unsafe { raw_pg::ExecStoreHeapTuple(tup, self.0, true) };
    }

    /// Store a row from a header + borrowed tuple bytes — the single-copy
    /// path, where `bytes` points straight into SQLite's page cache.
    pub fn store_parts(
        &mut self,
        rel: &Rel<'_>,
        header: &crate::sqlite::StoredHeader,
        bytes: &[u8],
    ) {
        let tup = build_heap_tuple_from_parts(rel, header, bytes);
        unsafe { raw_pg::ExecStoreHeapTuple(tup, self.0, true) };
    }

    /// Stamp `tts_tableOid` + `tts_tid` after a successful insert/update.
    pub fn set_inserted_tid(&mut self, rel: &Rel<'_>, rowid: i64) {
        self.0.tts_tableOid = rel.oid();
        rowid_to_tid(rowid, &mut self.0.tts_tid);
    }

    pub fn as_ptr(&mut self) -> *mut pg_sys::TupleTableSlot {
        self.0
    }
}

/// RAII wrapper for a palloc'd `HeapTuple`, freed on drop via
/// `heap_freetuple`. `Deref`s to the underlying tuple bytes.
pub struct OwnedHeapTuple(pg_sys::HeapTuple);

impl OwnedHeapTuple {
    /// Borrow the underlying tuple bytes for the lifetime of `self`.
    pub fn bytes(&self) -> &[u8] {
        self
    }
}

impl std::ops::Deref for OwnedHeapTuple {
    type Target = [u8];
    fn deref(&self) -> &[u8] {
        unsafe {
            std::slice::from_raw_parts((*self.0).t_data as *const u8, (*self.0).t_len as usize)
        }
    }
}

impl Drop for OwnedHeapTuple {
    fn drop(&mut self) {
        unsafe { raw_pg::heap_freetuple(self.0) };
    }
}

/// Rows per logical "block" when packing a SQLite rowid into a Postgres TID
/// `(block, offset)`. Must stay under `MaxHeapTuplesPerPage` (~226-291) — the
/// bound Postgres validates index/bitmap-scan offsets against; a naive
/// rowid→TID cast overflows it once a table passes a few hundred rows.
const TIDS_PER_BLOCK: i64 = 256;

/// Decode a Postgres `ItemPointer` to a SQLite rowid.
/// # Safety
/// `tid` must be a valid, non-null pointer at the time of the call.
pub unsafe fn tid_to_rowid(tid: pg_sys::ItemPointer) -> i64 {
    let blk = unsafe { pgrx::itemptr::item_pointer_get_block_number(tid) } as i64;
    let off = unsafe { pgrx::itemptr::item_pointer_get_offset_number(tid) } as i64;
    blk * TIDS_PER_BLOCK + off
}

/// Encode a SQLite rowid (1-based) into the given `ItemPointer`.
pub fn rowid_to_tid(rowid: i64, tid: &mut pg_sys::ItemPointerData) {
    debug_assert!(rowid >= 1, "rowids are 1-based in SQLite");
    let blk = ((rowid - 1) / TIDS_PER_BLOCK) as pg_sys::BlockNumber;
    let off = (((rowid - 1) % TIDS_PER_BLOCK) + 1) as pg_sys::OffsetNumber;
    pgrx::itemptr::item_pointer_set_all(tid, blk, off);
}

/// `MAXALIGN(sizeof(HeapTupleData))` — offset at which the tuple bytes
/// start in a `heap_form_tuple`-style single allocation.
const HEAPTUPLESIZE: usize =
    (std::mem::size_of::<pg_sys::HeapTupleData>() + 7) & !7;

/// Allocate a `HeapTuple` as `[HeapTupleData][tuple bytes]` in one `palloc`,
/// matching `heap_form_tuple`'s layout — `heap_freetuple` `pfree`s only the
/// one pointer, so a separate `t_data` alloc would leak.
fn build_heap_tuple(rel: &Rel<'_>, rowid: i64, bytes: &[u8]) -> pg_sys::HeapTuple {
    let len = bytes.len();
    unsafe {
        let raw = raw_pg::palloc(HEAPTUPLESIZE + len) as *mut u8;
        let tup = raw as *mut pg_sys::HeapTupleData;
        let data = raw.add(HEAPTUPLESIZE);
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), data, len);
        (*tup).t_len = len as u32;
        rowid_to_tid(rowid, &mut (*tup).t_self);
        (*tup).t_tableOid = rel.oid();
        (*tup).t_data = data as *mut pg_sys::HeapTupleHeaderData;
        tup
    }
}

/// Build a `HeapTuple`, overlaying our xmin/xmax/cmin onto the
/// `HeapTupleHeader` — Postgres internals (btree unique-check, `EvalPlanQual`)
/// read those fields directly.
pub(crate) fn build_heap_tuple_from_parts(
    rel: &Rel<'_>,
    header: &crate::sqlite::StoredHeader,
    bytes: &[u8],
) -> pg_sys::HeapTuple {
    let tup = build_heap_tuple(rel, header.rowid, bytes);
    unsafe {
        let h = (*tup).t_data;
        (*h).t_choice.t_heap.t_xmin = pg_sys::TransactionId::from(header.xmin);
        (*h).t_choice.t_heap.t_xmax = pg_sys::TransactionId::from(header.xmax);
        (*h).t_choice.t_heap.t_field3.t_cid = pg_sys::CommandId::from(header.cmin);
    }
    tup
}
