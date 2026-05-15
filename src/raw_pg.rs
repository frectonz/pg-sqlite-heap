//! Direct (no pg_guard) FFI declarations for Postgres entry points that we
//! hit per-tuple. pgrx's auto-generated bindings wrap every Postgres call in
//! `pg_guard_ffi_boundary`, which does a `sigsetjmp` + PG_exception_stack
//! swap on each call. For functions called 10k+ times in a single statement
//! that adds up to most of our overhead.
//!
//! Safety: the outer TAM callback (in `tam.rs`) keeps `#[pg_guard]`, so a
//! Postgres `ereport(ERROR)` raised by any function called here still
//! longjmps to a known catcher. Skipping the per-call wrapper just means
//! Postgres's existing PG_exception_stack handles the unwind directly,
//! which is the canonical pattern Postgres itself uses for internal calls.

use pgrx::pg_sys::{
    BlockNumber, CommandId, HeapTuple, Relation, Size, TransactionId, TupleTableSlot,
};
use std::os::raw::c_void;

#[cfg_attr(target_os = "windows", link(name = "postgres"))]
unsafe extern "C-unwind" {
    // ExecCopySlotHeapTuple and ExecClearTuple are `static inline` in
    // executor/tuptable.h — no real symbol. pgrx ships a C shim that exposes
    // them under `__pgrx_cshim` names; we link to those directly.
    #[link_name = "ExecCopySlotHeapTuple__pgrx_cshim"]
    pub fn ExecCopySlotHeapTuple(slot: *mut TupleTableSlot) -> HeapTuple;
    pub fn ExecStoreHeapTuple(
        tuple: HeapTuple,
        slot: *mut TupleTableSlot,
        shouldFree: bool,
    ) -> *mut TupleTableSlot;
    #[link_name = "ExecClearTuple__pgrx_cshim"]
    pub fn ExecClearTuple(slot: *mut TupleTableSlot) -> *mut TupleTableSlot;

    pub fn GetCurrentTransactionId() -> TransactionId;
    pub fn GetCurrentCommandId(used: bool) -> CommandId;
    pub fn GetOldestNonRemovableTransactionId(rel: Relation) -> TransactionId;

    pub fn TransactionIdIsCurrentTransactionId(xid: TransactionId) -> bool;
    pub fn TransactionIdIsInProgress(xid: TransactionId) -> bool;
    pub fn TransactionIdDidCommit(xid: TransactionId) -> bool;
    pub fn TransactionIdPrecedes(a: TransactionId, b: TransactionId) -> bool;
    pub fn TransactionIdFollows(a: TransactionId, b: TransactionId) -> bool;

    pub fn palloc(size: Size) -> *mut c_void;
    pub fn pfree(ptr: *mut c_void);
    pub fn heap_freetuple(tup: HeapTuple);

    pub fn read_stream_next_block(
        stream: *mut pgrx::pg_sys::ReadStream,
        strategy: *mut pgrx::pg_sys::BufferAccessStrategy,
    ) -> BlockNumber;
}
