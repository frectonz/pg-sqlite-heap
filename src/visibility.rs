use crate::raw_pg;
use crate::sqlite::StoredHeader;
use pgrx::pg_sys;

/// Did `xid` commit? `xid == 0` (or an unknown in-progress xid) counts as
/// not-yet-committed.
pub(crate) fn did_commit(xid: u32) -> bool {
    if xid == 0 {
        return false;
    }
    unsafe { raw_pg::TransactionIdDidCommit(pg_sys::TransactionId::from(xid)) }
}

/// Three-valued visibility verdict for an xid relative to a snapshot.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
enum XidView {
    /// Our own transaction — caller must still check cmin/cmax vs curcid.
    OurOwnXact,
    CommittedAndVisible,
    /// Aborted, in-progress, or committed after this snapshot.
    NotVisible,
}

/// Is this row visible under `snapshot`? Dispatches by snapshot kind.
pub fn row_visible(row: &StoredHeader, snapshot: pg_sys::Snapshot) -> bool {
    let snap = unsafe { &*snapshot };
    match snap.snapshot_type {
        pg_sys::SnapshotType::SNAPSHOT_ANY => true,
        pg_sys::SnapshotType::SNAPSHOT_SELF => visible_self(row),
        pg_sys::SnapshotType::SNAPSHOT_DIRTY => visible_dirty(row, snapshot),
        pg_sys::SnapshotType::SNAPSHOT_NON_VACUUMABLE => visible_non_vacuumable(row),
        // MVCC, HISTORIC_MVCC, TOAST → MVCC rules.
        _ => visible_mvcc(row, snapshot),
    }
}

/// Standard MVCC: visible if `xmin` is committed-and-visible and `xmax`
/// (if any) is not yet committed-and-visible.
fn visible_mvcc(row: &StoredHeader, snapshot: pg_sys::Snapshot) -> bool {
    let snap = unsafe { &*snapshot };
    let curcid: u32 = snap.curcid;

    match xid_view(row.xmin, snapshot) {
        XidView::NotVisible => return false,
        XidView::OurOwnXact => {
            if row.cmin >= curcid {
                return false;
            }
        }
        XidView::CommittedAndVisible => {}
    }
    if row.xmax == 0 {
        return true;
    }
    match xid_view(row.xmax, snapshot) {
        XidView::NotVisible => true,
        XidView::OurOwnXact => row.cmax >= curcid,
        XidView::CommittedAndVisible => false,
    }
}

/// SnapshotSelf: visible if our own xact (any command) wrote it and no
/// finished xact has deleted it.
fn visible_self(row: &StoredHeader) -> bool {
    let xmin = pg_sys::TransactionId::from(row.xmin);
    let inserted_by_me = unsafe { raw_pg::TransactionIdIsCurrentTransactionId(xmin) };
    if !inserted_by_me && !did_commit(row.xmin) {
        return false;
    }
    if row.xmax == 0 {
        return true;
    }
    let xmax = pg_sys::TransactionId::from(row.xmax);
    let deleted_by_me = unsafe { raw_pg::TransactionIdIsCurrentTransactionId(xmax) };
    !(deleted_by_me || did_commit(row.xmax))
}

/// SnapshotDirty: includes in-progress rows. Mirrors heap's
/// `HeapTupleSatisfiesDirty` contract — it *mutates* the snapshot
/// (`xmin`/`xmax`/`speculativeToken`) to report the in-progress xid back to
/// the caller (btree's `_bt_check_unique` reads it). These fields must be
/// reset at entry, or the unique-check path loops.
fn visible_dirty(row: &StoredHeader, snapshot: pg_sys::Snapshot) -> bool {
    unsafe {
        (*snapshot).xmin = pg_sys::TransactionId::INVALID;
        (*snapshot).xmax = pg_sys::TransactionId::INVALID;
        (*snapshot).speculativeToken = 0;
    }

    let xmin = pg_sys::TransactionId::from(row.xmin);
    if unsafe { raw_pg::TransactionIdIsCurrentTransactionId(xmin) } {
        // Inserted by us — fall through to xmax handling.
    } else if unsafe { raw_pg::TransactionIdIsInProgress(xmin) } {
        unsafe { (*snapshot).xmin = xmin };
        // Still considered visible to a dirty snapshot.
    } else if !did_commit(row.xmin) {
        return false;
    }

    if row.xmax == 0 {
        return true;
    }
    let xmax = pg_sys::TransactionId::from(row.xmax);
    if unsafe { raw_pg::TransactionIdIsCurrentTransactionId(xmax) } {
        return false; // we already deleted it ourselves
    }
    if unsafe { raw_pg::TransactionIdIsInProgress(xmax) } {
        unsafe { (*snapshot).xmax = xmax };
        return true; // deleter not committed yet
    }
    if did_commit(row.xmax) {
        return false; // deletion is visible
    }
    true // xmax aborted → still live
}

/// SNAPSHOT_NON_VACUUMABLE: still live, or its deleter hasn't committed.
fn visible_non_vacuumable(row: &StoredHeader) -> bool {
    if row.xmax == 0 {
        return true;
    }
    !did_commit(row.xmax)
}

fn xid_view(xid: u32, snapshot: pg_sys::Snapshot) -> XidView {
    let xid_t = pg_sys::TransactionId::from(xid);
    if unsafe { raw_pg::TransactionIdIsCurrentTransactionId(xid_t) } {
        return XidView::OurOwnXact;
    }
    if !did_commit(xid) {
        return XidView::NotVisible;
    }
    let snap = unsafe { &*snapshot };
    if unsafe { raw_pg::TransactionIdPrecedes(xid_t, snap.xmin) } {
        return XidView::CommittedAndVisible;
    }
    if !unsafe { raw_pg::TransactionIdPrecedes(xid_t, snap.xmax) } {
        return XidView::NotVisible;
    }
    for i in 0..snap.xcnt as usize {
        let in_progress = unsafe { *snap.xip.add(i) };
        if xid_t == in_progress {
            return XidView::NotVisible;
        }
    }
    XidView::CommittedAndVisible
}
