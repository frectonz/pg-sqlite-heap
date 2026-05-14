use pgrx::pg_sys;
use pgrx::{
    register_subxact_callback, register_xact_callback, PgSubXactCallbackEvent,
    PgXactCallbackEvent,
};
use crate::fxhash::{FxHashMap, FxHashSet};
use rusqlite::{params, Connection};
use std::cell::{Cell, RefCell};
use std::path::PathBuf;

/// `.unwrap()` for `rusqlite::Result`: panics with the SQLite error message.
/// The panic unwinds (running `RefCell` guard destructors) and `#[pg_guard]`
/// turns it into a Postgres ERROR — deliberately not a `pgrx::error!` longjmp,
/// which would skip those destructors and poison `CONNS`.
trait SqliteResultExt<T> {
    fn unwrap_sql(self) -> T;
}

impl<T> SqliteResultExt<T> for rusqlite::Result<T> {
    #[track_caller]
    fn unwrap_sql(self) -> T {
        match self {
            Ok(v) => v,
            Err(e) => panic!("sqlite_heap: {e}"),
        }
    }
}

thread_local! {
    static CONNS: RefCell<FxHashMap<u32, RelConn>> =
        RefCell::new(FxHashMap::default());

    /// Relations with an open SQLite transaction in the current Postgres
    /// transaction. Cleared on Commit/Abort.
    static TX_RELS: RefCell<FxHashSet<u32>> = RefCell::new(FxHashSet::default());

    static SQLITE_DIR: RefCell<Option<PathBuf>> = const { RefCell::new(None) };
}

/// A SQLite connection plus its lazy-transaction state.
///
/// The SQLite transaction is opened lazily, on the first *write* (`in_txn`
/// tracks it). A read-only Postgres transaction never opens one: SQLite's
/// per-statement autocommit gives an identical consistent read, and MVCC is
/// decided by [`visibility::row_visible`](crate::visibility) against the
/// Postgres snapshot regardless. The SQLite transaction only ever provides
/// write atomicity.
struct RelConn {
    conn: Connection,
    in_txn: Cell<bool>,
}

impl RelConn {
    fn new(conn: Connection) -> Self {
        RelConn {
            conn,
            in_txn: Cell::new(false),
        }
    }

    /// Open the SQLite transaction lazily — write paths call this, read paths
    /// run under SQLite autocommit.
    fn begin_if_needed(&self) {
        if !self.in_txn.get() {
            self.conn.execute_batch("BEGIN").unwrap_sql();
            self.in_txn.set(true);
        }
    }

    /// Runs at Postgres `PreCommit`. A failed commit here must abort the whole
    /// Postgres transaction — so `unwrap_sql` panics rather than warns.
    fn commit(&self) {
        if !self.in_txn.get() {
            return;
        }
        self.conn.execute_batch("COMMIT").unwrap_sql();
        self.in_txn.set(false);
    }

    /// Runs on the Postgres abort path — unwinding is unsafe here and there's
    /// nothing left to abort, so a failure only warns.
    fn rollback(&self) {
        if !self.in_txn.get() {
            return;
        }
        if let Err(e) = self.conn.execute_batch("ROLLBACK") {
            pgrx::warning!("sqlite_heap: ROLLBACK failed: {e}");
        }
        self.in_txn.set(false);
    }
}

impl std::ops::Deref for RelConn {
    type Target = Connection;
    fn deref(&self) -> &Connection {
        &self.conn
    }
}

/// Run `f` with the sqlite_heap directory `$PGDATA/sqlite_heap/<dbOid>/`,
/// computed and `create_dir_all`'d once per backend then cached.
fn with_dir<R>(f: impl FnOnce(&std::path::Path) -> R) -> R {
    SQLITE_DIR.with(|d| {
        let mut d = d.borrow_mut();
        let path = d.get_or_insert_with(|| {
            use std::os::unix::ffi::OsStrExt;
            // SAFETY: `DataDir` is set by Postgres at startup before any
            // backend can run extension code, and outlives our use.
            let datadir = unsafe {
                let ptr = pg_sys::DataDir;
                assert!(!ptr.is_null(), "DataDir not initialised");
                std::ffi::CStr::from_ptr(ptr)
            };
            let db_oid: u32 = unsafe { pg_sys::MyDatabaseId }.to_u32();
            let p = PathBuf::from(std::ffi::OsStr::from_bytes(datadir.to_bytes()))
                .join("sqlite_heap")
                .join(db_oid.to_string());
            std::fs::create_dir_all(&p)
                .expect("mkdir sqlite_heap dir under PGDATA");
            p
        });
        f(path)
    })
}

fn path_for(rel_id: u32) -> PathBuf {
    with_dir(|d| d.join(format!("{rel_id}.sqlite")))
}

/// On-disk path of the SQLite file backing `rel_id`. Inspection helper.
pub fn file_path(rel_id: u32) -> PathBuf {
    path_for(rel_id)
}

/// The SQLite `PRAGMA user_version` of `rel_id`'s file — our [`SCHEMA_VERSION`].
pub fn schema_version(rel_id: u32) -> i32 {
    with_conn(rel_id, |conn| {
        conn.query_row("PRAGMA user_version", [], |r| r.get(0))
            .unwrap_or(0)
    })
}

/// Every sqlite_heap file in this database's directory, as `(table_oid, bytes)`.
pub fn list_files() -> Vec<(u32, u64)> {
    with_dir(|dir| {
        let mut out = Vec::new();
        let Ok(entries) = std::fs::read_dir(dir) else {
            return out;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("sqlite") {
                continue;
            }
            let Some(oid) = path
                .file_stem()
                .and_then(|s| s.to_str())
                .and_then(|s| s.parse::<u32>().ok())
            else {
                continue;
            };
            let bytes = entry.metadata().map(|m| m.len()).unwrap_or(0);
            out.push((oid, bytes));
        }
        out.sort_unstable();
        out
    })
}

/// Current on-disk schema, written to each file's `PRAGMA user_version`.
const SCHEMA_VERSION: i32 = 4;

fn open_conn(rel_id: u32) -> Connection {
    let conn = Connection::open(path_for(rel_id)).unwrap_sql();

    // Per-connection PRAGMAs — SQLite resets them to defaults on every open.
    // `synchronous=FULL` is load-bearing: we commit SQLite at Postgres
    // PreCommit, so the SQLite commit must be durable before Postgres's
    // (otherwise an OS crash could leave Postgres committed but SQLite not).
    conn.execute_batch(
        "PRAGMA synchronous=FULL;\
         PRAGMA cache_size=-8192;\
         PRAGMA temp_store=MEMORY;\
         PRAGMA busy_timeout=5000;",
    )
    .unwrap_sql();

    let current: i32 = conn
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .unwrap_or(0);
    if current == 0 {
        install_schema(&conn);
    } else if current > SCHEMA_VERSION {
        panic!(
            "sqlite_heap: on-disk schema v{current} is newer than supported \
             v{SCHEMA_VERSION}; refusing to read"
        );
    } else if current < SCHEMA_VERSION {
        migrate_schema(&conn, current);
    }
    conn
}

fn install_schema(conn: &Connection) {
    conn.execute_batch(&format!(
        "PRAGMA journal_mode=WAL;\
         CREATE TABLE IF NOT EXISTS storage (\
            rowid INTEGER PRIMARY KEY, \
            xmin INTEGER NOT NULL, \
            cmin INTEGER NOT NULL DEFAULT 0, \
            xmax INTEGER NOT NULL DEFAULT 0, \
            cmax INTEGER NOT NULL DEFAULT 0, \
            tuple BLOB NOT NULL\
         );\
         CREATE TABLE IF NOT EXISTS meta (\
            key TEXT PRIMARY KEY, \
            value BLOB NOT NULL\
         );\
         PRAGMA user_version = {SCHEMA_VERSION};"
    ))
    .unwrap_sql();
}

/// Bring an on-disk file at version `from` up to [`SCHEMA_VERSION`].
fn migrate_schema(conn: &Connection, from: i32) {
    if from < 2 {
        conn.execute_batch("DROP INDEX IF EXISTS storage_dead;")
            .unwrap_sql();
    }
    if from == 3 {
        conn.execute_batch("ALTER TABLE storage DROP COLUMN prev;")
            .unwrap_sql();
    }
    conn.execute_batch(&format!("PRAGMA user_version = {SCHEMA_VERSION};"))
        .unwrap_sql();
}

/// Read a meta key. None if the key isn't set.
pub fn meta_get(rel_id: u32, key: &str) -> Option<Vec<u8>> {
    with_conn(rel_id, |conn| {
        conn.prepare_cached("SELECT value FROM meta WHERE key = ?1")
            .unwrap_sql()
            .query_row(params![key], |r| r.get::<_, Vec<u8>>(0))
            .ok()
    })
}

/// Upsert a meta key.
pub fn meta_set(rel_id: u32, key: &str, value: &[u8]) {
    with_conn(rel_id, |conn| {
        conn.begin_if_needed();
        conn.prepare_cached(
            "INSERT INTO meta (key, value) VALUES (?1, ?2) \
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        )
        .unwrap_sql()
        .execute(params![key, value])
        .unwrap_sql();
    });
}

/// Empty the relation's storage (CREATE TABLE, TRUNCATE, …).
pub fn reset(rel_id: u32) {
    with_conn(rel_id, |conn| {
        conn.begin_if_needed();
        conn.execute_batch("DELETE FROM storage;").unwrap_sql();
    });
}

/// Reclaim a relation's file at commit time — deferring the unlink means a
/// rolled-back DROP leaves the file intact.
pub fn drop_relation(rel_id: u32) {
    register_xact_callback(PgXactCallbackEvent::Commit, move || unlink_storage(rel_id));
}

fn unlink_storage(rel_id: u32) {
    CONNS.with(|c| {
        c.borrow_mut().remove(&rel_id);
    });
    TX_RELS.with(|t| {
        t.borrow_mut().remove(&rel_id);
    });
    let base = path_for(rel_id);
    let _ = std::fs::remove_file(&base);
    let _ = std::fs::remove_file(base.with_extension("sqlite-wal"));
    let _ = std::fs::remove_file(base.with_extension("sqlite-shm"));
}

/// Run `f` with the open connection for `rel_id`, registering it with the
/// current Postgres transaction. Does not open a SQLite transaction — write
/// paths call `begin_if_needed` themselves.
fn with_conn<R>(rel_id: u32, f: impl FnOnce(&RelConn) -> R) -> R {
    ensure_in_xact(rel_id);
    CONNS.with(|c| {
        let c = c.borrow();
        let conn = c.get(&rel_id).expect("connection should be cached");
        f(conn)
    })
}

fn ensure_in_xact(rel_id: u32) {
    TX_RELS.with(|tx| {
        let mut tx = tx.borrow_mut();
        let first_relation_in_xact = tx.is_empty();
        let new_relation = tx.insert(rel_id);

        if new_relation {
            CONNS.with(|c| {
                c.borrow_mut()
                    .entry(rel_id)
                    .or_insert_with(|| RelConn::new(open_conn(rel_id)));
            });
        }

        if first_relation_in_xact {
            // Commit SQLite at `PreCommit` — before Postgres writes its commit
            // record. The only crash window then leaves SQLite *ahead*, which
            // self-heals: those rows' xmin shows as aborted in Postgres's CLOG
            // so `visibility::row_visible` hides them. The reverse ordering
            // would leave committed-but-missing data.
            register_xact_callback(PgXactCallbackEvent::PreCommit, on_precommit);
            register_xact_callback(PgXactCallbackEvent::Abort, on_abort);
            register_subxact_callback(PgSubXactCallbackEvent::StartSub, on_sub_start);
            register_subxact_callback(PgSubXactCallbackEvent::CommitSub, on_sub_commit);
            register_subxact_callback(PgSubXactCallbackEvent::AbortSub, on_sub_abort);
        }
    });
}

fn run_on_txn_conns(stmt: &str) {
    TX_RELS.with(|tx| {
        let rels = tx.borrow();
        CONNS.with(|c| {
            let c = c.borrow();
            for rel_id in rels.iter() {
                if let Some(conn) = c.get(rel_id) {
                    if conn.in_txn.get() {
                        if let Err(e) = conn.execute_batch(stmt) {
                            pgrx::warning!("sqlite_heap: `{stmt}` failed: {e}");
                        }
                    }
                }
            }
        });
    });
}

fn on_sub_start(my_subid: pg_sys::SubTransactionId, _parent: pg_sys::SubTransactionId) {
    // A savepoint needs an enclosing transaction; force one open on every
    // touched relation so writes inside the subxact are savepointed.
    TX_RELS.with(|tx| {
        let rels = tx.borrow();
        CONNS.with(|c| {
            let c = c.borrow();
            for rel_id in rels.iter() {
                if let Some(conn) = c.get(rel_id) {
                    conn.begin_if_needed();
                    if let Err(e) =
                        conn.execute_batch(&format!("SAVEPOINT sp_{my_subid};"))
                    {
                        pgrx::warning!("sqlite_heap: savepoint failed: {e}");
                    }
                }
            }
        });
    });
}

fn on_sub_commit(my_subid: pg_sys::SubTransactionId, _parent: pg_sys::SubTransactionId) {
    run_on_txn_conns(&format!("RELEASE SAVEPOINT sp_{my_subid};"));
}

fn on_sub_abort(my_subid: pg_sys::SubTransactionId, _parent: pg_sys::SubTransactionId) {
    run_on_txn_conns(&format!("ROLLBACK TO SAVEPOINT sp_{my_subid};"));
}

fn on_precommit() {
    TX_RELS.with(|tx| {
        let rels = std::mem::take(&mut *tx.borrow_mut());
        CONNS.with(|c| {
            let c = c.borrow();
            for rel_id in rels {
                if let Some(conn) = c.get(&rel_id) {
                    conn.commit();
                }
            }
        });
    });
}

fn on_abort() {
    TX_RELS.with(|tx| {
        let rels = std::mem::take(&mut *tx.borrow_mut());
        CONNS.with(|c| {
            let c = c.borrow();
            for rel_id in rels {
                if let Some(conn) = c.get(&rel_id) {
                    conn.rollback();
                }
            }
        });
    });
}

/// A stored row: MVCC header plus the opaque tuple bytes.
pub struct StoredRow {
    pub header: StoredHeader,
    pub tuple: Vec<u8>,
}

impl std::ops::Deref for StoredRow {
    type Target = StoredHeader;
    fn deref(&self) -> &StoredHeader {
        &self.header
    }
}

/// A row's MVCC bookkeeping — enough to decide visibility without the BLOB.
#[derive(Clone, Copy)]
pub struct StoredHeader {
    pub rowid: i64,
    pub xmin: u32,
    pub cmin: u32,
    pub xmax: u32,
    pub cmax: u32,
}

impl StoredHeader {
    /// Decode from a row whose first five columns are
    /// `rowid, xmin, cmin, xmax, cmax` — the shared row-query layout.
    fn from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Self> {
        Ok(StoredHeader {
            rowid: row.get(0)?,
            xmin: row.get(1)?,
            cmin: row.get(2)?,
            xmax: row.get(3)?,
            cmax: row.get(4)?,
        })
    }
}

pub fn insert(rel_id: u32, xmin: u32, cmin: u32, bytes: &[u8]) -> i64 {
    with_conn(rel_id, |conn| {
        conn.begin_if_needed();
        conn.prepare_cached("INSERT INTO storage (xmin, cmin, tuple) VALUES (?1, ?2, ?3)")
            .unwrap_sql()
            .execute(params![xmin, cmin, bytes])
            .unwrap_sql();
        conn.last_insert_rowid()
    })
}

/// Insert many tuples through one cached statement. Hot path for COPY and
/// `INSERT ... SELECT`.
pub fn insert_batch(rel_id: u32, xmin: u32, cmin: u32, tuples: &[&[u8]]) -> Vec<i64> {
    with_conn(rel_id, |conn| {
        conn.begin_if_needed();
        let mut stmt = conn
            .prepare_cached("INSERT INTO storage (xmin, cmin, tuple) VALUES (?1, ?2, ?3)")
            .unwrap_sql();
        let mut rowids = Vec::with_capacity(tuples.len());
        for bytes in tuples {
            stmt.execute(params![xmin, cmin, bytes]).unwrap_sql();
            rowids.push(conn.last_insert_rowid());
        }
        rowids
    })
}

/// Every physical row version, for a sequential scan. `visibility::row_visible`
/// filters them down to what a given snapshot should see.
pub fn select_all(rel_id: u32) -> Vec<StoredRow> {
    with_conn(rel_id, |conn| {
        conn.prepare_cached(
            "SELECT rowid, xmin, cmin, xmax, cmax, tuple \
             FROM storage ORDER BY rowid",
        )
        .unwrap_sql()
        .query_map([], |row| {
            Ok(StoredRow {
                header: StoredHeader::from_row(row)?,
                tuple: row.get(5)?,
            })
        })
        .unwrap_sql()
        .collect::<rusqlite::Result<Vec<_>>>()
        .unwrap_sql()
    })
}

/// The `xmax` of many rowids in one `WHERE rowid IN (…)` query — a rowid
/// absent from the result is not physically present. Lets btree bottom-up
/// deletion check a whole leaf page in one query instead of N.
pub fn select_xmax_batch(rel_id: u32, rowids: &[i64]) -> FxHashMap<i64, u32> {
    if rowids.is_empty() {
        return FxHashMap::default();
    }
    with_conn(rel_id, |conn| {
        let mut sql =
            String::from("SELECT rowid, xmax FROM storage WHERE rowid IN (");
        for i in 0..rowids.len() {
            if i > 0 {
                sql.push(',');
            }
            sql.push('?');
        }
        sql.push(')');
        let mut stmt = conn.prepare_cached(&sql).unwrap_sql();
        let mut map =
            FxHashMap::with_capacity_and_hasher(rowids.len(), Default::default());
        let rows = stmt
            .query_map(rusqlite::params_from_iter(rowids), |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, u32>(1)?))
            })
            .unwrap_sql();
        for row in rows {
            let (rid, xmax) = row.unwrap_sql();
            map.insert(rid, xmax);
        }
        map
    })
}

pub fn select_one(rel_id: u32, rowid: i64) -> Option<StoredRow> {
    with_conn(rel_id, |conn| {
        conn.prepare_cached(
            "SELECT rowid, xmin, cmin, xmax, cmax, tuple \
             FROM storage WHERE rowid = ?1",
        )
        .unwrap_sql()
        .query_row(params![rowid], |row| {
            Ok(StoredRow {
                header: StoredHeader::from_row(row)?,
                tuple: row.get(5)?,
            })
        })
        .ok()
    })
}

/// Fetch one row by rowid, passing `f` its header + a borrowed view of the
/// BLOB straight from SQLite's page cache (so the index-fetch path copies the
/// bytes only once, into the palloc'd HeapTuple). Returns `f`'s result, or
/// `false` if the row doesn't exist.
pub fn fetch_one_ref(
    rel_id: u32,
    rowid: i64,
    f: impl FnOnce(&StoredHeader, &[u8]) -> bool,
) -> bool {
    with_conn(rel_id, |conn| {
        let mut stmt = conn
            .prepare_cached(
                "SELECT rowid, xmin, cmin, xmax, cmax, tuple \
                 FROM storage WHERE rowid = ?1",
            )
            .unwrap_sql();
        let mut rows = stmt.query(params![rowid]).unwrap_sql();
        let Some(row) = rows.next().unwrap_sql() else {
            return false;
        };
        let header = StoredHeader::from_row(row).unwrap_sql();
        let blob = row
            .get_ref(5)
            .unwrap_sql()
            .as_blob()
            .expect("storage.tuple is declared BLOB NOT NULL");
        f(&header, blob)
    })
}

/// Mark a row deleted by setting its xmax/cmax. Returns rows affected (0 if the
/// rowid doesn't exist or was already marked).
pub fn set_xmax(rel_id: u32, rowid: i64, xmax: u32, cmax: u32) -> usize {
    with_conn(rel_id, |conn| {
        conn.begin_if_needed();
        conn.prepare_cached(
            "UPDATE storage SET xmax = ?1, cmax = ?2 WHERE rowid = ?3 AND xmax = 0",
        )
        .unwrap_sql()
        .execute(params![xmax, cmax, rowid])
        .unwrap_sql()
    })
}

/// An UPDATE is MVCC delete-old + insert-new: stamp the old row dead and
/// insert the new version at a fresh rowid. Returns the new rowid.
pub fn update_row(
    rel_id: u32,
    old_rowid: i64,
    xid: u32,
    cid: u32,
    new_bytes: &[u8],
) -> i64 {
    with_conn(rel_id, |conn| {
        conn.begin_if_needed();
        conn.prepare_cached(
            "UPDATE storage SET xmax = ?1, cmax = ?2 WHERE rowid = ?3 AND xmax = 0",
        )
        .unwrap_sql()
        .execute(params![xid, cid, old_rowid])
        .unwrap_sql();
        conn.prepare_cached("INSERT INTO storage (xmin, cmin, tuple) VALUES (?1, ?2, ?3)")
            .unwrap_sql()
            .execute(params![xid, cid, new_bytes])
            .unwrap_sql();
        conn.last_insert_rowid()
    })
}

/// Physically remove a row by rowid — retracts a speculative insert that lost
/// a conflict.
pub fn physical_delete(rel_id: u32, rowid: i64) -> usize {
    with_conn(rel_id, |conn| {
        conn.begin_if_needed();
        conn.prepare_cached("DELETE FROM storage WHERE rowid = ?1")
            .unwrap_sql()
            .execute(params![rowid])
            .unwrap_sql()
    })
}

const META_LAST_VACUUM_XMIN: &str = "last_vacuum_xmin";

/// Physically remove rows whose `xmax` is committed and globally visible.
/// Skipped if a prior VACUUM already reached this `oldest_xmin` (a meta-table
/// watermark).
pub fn vacuum_dead(rel_id: u32, oldest_xmin: u32) -> usize {
    let last = meta_get(rel_id, META_LAST_VACUUM_XMIN)
        .and_then(|b| <[u8; 4]>::try_from(b.as_slice()).ok())
        .map(u32::from_le_bytes)
        .unwrap_or(0);
    if oldest_xmin <= last {
        return 0;
    }
    let removed = with_conn(rel_id, |conn| {
        conn.begin_if_needed();
        conn.prepare_cached("DELETE FROM storage WHERE xmax != 0 AND xmax < ?1")
            .unwrap_sql()
            .execute(params![oldest_xmin])
            .unwrap_sql()
    });
    meta_set(rel_id, META_LAST_VACUUM_XMIN, &oldest_xmin.to_le_bytes());
    removed
}

/// Planner size estimate `(file_bytes, tuple_count)`, backing the
/// `relation_estimate_size` callback. A plain `stat` + `count(*)` — the
/// planner mostly leans on `ANALYZE`'s statistics anyway.
pub fn estimate_size(rel_id: u32) -> (u64, i64) {
    let bytes = std::fs::metadata(path_for(rel_id))
        .map(|m| m.len())
        .unwrap_or(0);
    let tuples = with_conn(rel_id, |conn| {
        conn.prepare_cached("SELECT count(*) FROM storage")
            .unwrap_sql()
            .query_row([], |r| r.get::<_, i64>(0))
            .unwrap_or(0)
    });
    (bytes, tuples)
}
