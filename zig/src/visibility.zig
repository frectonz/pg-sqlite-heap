//! Snapshot visibility rules over the stored xmin/xmax -- the Zig port of
//! `visibility.rs`. Every PostgreSQL transaction-state query goes through the
//! `shim_xid_*` / `shim_snap_*` wrappers.

const pg = @import("pg.zig");
const StoredHeader = @import("sqlite.zig").StoredHeader;

/// Did `xid` commit? `xid == 0` (or an unknown in-progress xid) counts as
/// not-yet-committed.
pub fn didCommit(xid: u32) bool {
    if (xid == 0) return false;
    return pg.shim_xid_did_commit(xid);
}

/// Three-valued visibility verdict for an xid relative to a snapshot.
const XidView = enum {
    /// Our own transaction -- caller must still check cmin/cmax vs curcid.
    our_own_xact,
    committed_and_visible,
    /// Aborted, in-progress, or committed after this snapshot.
    not_visible,
};

/// Is this row visible under `snapshot`? Dispatches by snapshot kind.
pub fn rowVisible(row: *const StoredHeader, snapshot: pg.Snapshot) bool {
    return switch (pg.shim_snapshot_type(snapshot)) {
        pg.SNAPSHOT_ANY => true,
        pg.SNAPSHOT_SELF => visibleSelf(row),
        pg.SNAPSHOT_DIRTY => visibleDirty(row, snapshot),
        pg.SNAPSHOT_NON_VACUUMABLE => visibleNonVacuumable(row),
        // MVCC, HISTORIC_MVCC, TOAST -> MVCC rules.
        else => visibleMvcc(row, snapshot),
    };
}

/// Standard MVCC: visible if `xmin` is committed-and-visible and `xmax` (if
/// any) is not yet committed-and-visible.
fn visibleMvcc(row: *const StoredHeader, snapshot: pg.Snapshot) bool {
    const curcid = pg.shim_snap_curcid(snapshot);

    switch (xidView(row.xmin, snapshot)) {
        .not_visible => return false,
        .our_own_xact => if (row.cmin >= curcid) return false,
        .committed_and_visible => {},
    }
    if (row.xmax == 0) return true;
    return switch (xidView(row.xmax, snapshot)) {
        .not_visible => true,
        .our_own_xact => row.cmax >= curcid,
        .committed_and_visible => false,
    };
}

/// SnapshotSelf: visible if our own xact (any command) wrote it and no
/// finished xact has deleted it.
fn visibleSelf(row: *const StoredHeader) bool {
    const inserted_by_me = pg.shim_xid_is_current(row.xmin);
    if (!inserted_by_me and !didCommit(row.xmin)) return false;
    if (row.xmax == 0) return true;
    const deleted_by_me = pg.shim_xid_is_current(row.xmax);
    return !(deleted_by_me or didCommit(row.xmax));
}

/// SnapshotDirty: includes in-progress rows. Mirrors heap's
/// `HeapTupleSatisfiesDirty` contract -- it *mutates* the snapshot
/// (xmin/xmax/speculativeToken) to report the in-progress xid back to the
/// caller (btree's `_bt_check_unique` reads it). Those fields must be reset at
/// entry, or the unique-check path loops.
fn visibleDirty(row: *const StoredHeader, snapshot: pg.Snapshot) bool {
    pg.shim_snap_reset_dirty_out(snapshot);

    if (pg.shim_xid_is_current(row.xmin)) {
        // Inserted by us -- fall through to xmax handling.
    } else if (pg.shim_xid_in_progress(row.xmin)) {
        pg.shim_snap_set_xmin(snapshot, row.xmin);
        // Still considered visible to a dirty snapshot.
    } else if (!didCommit(row.xmin)) {
        return false;
    }

    if (row.xmax == 0) return true;
    if (pg.shim_xid_is_current(row.xmax)) return false; // we deleted it ourselves
    if (pg.shim_xid_in_progress(row.xmax)) {
        pg.shim_snap_set_xmax(snapshot, row.xmax);
        return true; // deleter not committed yet
    }
    if (didCommit(row.xmax)) return false; // deletion is visible
    return true; // xmax aborted -> still live
}

/// SNAPSHOT_NON_VACUUMABLE: still live, or its deleter has not committed.
fn visibleNonVacuumable(row: *const StoredHeader) bool {
    if (row.xmax == 0) return true;
    return !didCommit(row.xmax);
}

fn xidView(xid: u32, snapshot: pg.Snapshot) XidView {
    if (pg.shim_xid_is_current(xid)) return .our_own_xact;
    if (!didCommit(xid)) return .not_visible;

    const snap_xmin = pg.shim_snap_xmin(snapshot);
    if (pg.shim_xid_precedes(xid, snap_xmin)) return .committed_and_visible;
    const snap_xmax = pg.shim_snap_xmax(snapshot);
    if (!pg.shim_xid_precedes(xid, snap_xmax)) return .not_visible;

    const xcnt = pg.shim_snap_xcnt(snapshot);
    var i: u32 = 0;
    while (i < xcnt) : (i += 1) {
        if (xid == pg.shim_snap_xip(snapshot, i)) return .not_visible;
    }
    return .committed_and_visible;
}
