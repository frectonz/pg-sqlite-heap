use pgrx::pg_sys;
use pgrx::{
    register_subxact_callback, register_xact_callback, PgSubXactCallbackEvent,
    PgXactCallbackEvent,
};
use crate::fxhash::{FxHashMap, FxHashSet};
use libsqlite3_sys as sqlite;
use std::cell::{Cell, RefCell};
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_void};
use std::path::PathBuf;
use std::ptr;

/// Panic with a SQLite error message. The panic unwinds (running `RefCell`
/// guard destructors) and `#[pg_guard]` turns it into a Postgres ERROR —
/// deliberately not a `pgrx::error!` longjmp, which would skip those
/// destructors and poison `CONNS`.
#[track_caller]
fn die(msg: impl AsRef<str>) -> ! {
    panic!("sqlite_heap: {}", msg.as_ref());
}

thread_local! {
    static CONNS: RefCell<FxHashMap<u32, RelConn>> =
        RefCell::new(FxHashMap::default());

    /// Relations with an open SQLite transaction in the current Postgres
    /// transaction. Cleared on Commit/Abort.
    static TX_RELS: RefCell<FxHashSet<u32>> = RefCell::new(FxHashSet::default());

    static SQLITE_DIR: RefCell<Option<PathBuf>> = const { RefCell::new(None) };
}

/// A SQLite connection plus its lazy-transaction state and prepared-statement
/// cache.
///
/// The SQLite transaction is opened lazily, on the first *write* (`in_txn`
/// tracks it). A read-only Postgres transaction never opens one: SQLite's
/// per-statement autocommit gives an identical consistent read, and MVCC is
/// decided by [`visibility::row_visible`](crate::visibility) against the
/// Postgres snapshot regardless. The SQLite transaction only ever provides
/// write atomicity.
struct RelConn {
    db: *mut sqlite::sqlite3,
    in_txn: Cell<bool>,
    /// Keyed by SQL text content. Callers pass `&'static str` literals so the
    /// pointers are stable, but content keying lets callers share a statement
    /// even if the same SQL is written in two places.
    cache: RefCell<FxHashMap<&'static str, *mut sqlite::sqlite3_stmt>>,
}

impl RelConn {
    fn new(db: *mut sqlite::sqlite3) -> Self {
        RelConn {
            db,
            in_txn: Cell::new(false),
            cache: RefCell::new(FxHashMap::default()),
        }
    }

    fn errmsg(&self) -> String {
        unsafe {
            CStr::from_ptr(sqlite::sqlite3_errmsg(self.db))
                .to_string_lossy()
                .into_owned()
        }
    }

    /// `sqlite3_exec` with no callback — for DDL, BEGIN/COMMIT, PRAGMA, etc.
    fn exec(&self, sql: &str) {
        if let Err(e) = self.try_exec(sql) {
            die(format!("{sql}: {e}"));
        }
    }

    fn try_exec(&self, sql: &str) -> Result<(), String> {
        let c = CString::new(sql).expect("SQL contains NUL byte");
        unsafe {
            let mut err: *mut c_char = ptr::null_mut();
            let rc = sqlite::sqlite3_exec(
                self.db,
                c.as_ptr(),
                None,
                ptr::null_mut(),
                &mut err,
            );
            if rc == sqlite::SQLITE_OK {
                return Ok(());
            }
            let msg = if err.is_null() {
                "(no message)".to_string()
            } else {
                let s = CStr::from_ptr(err).to_string_lossy().into_owned();
                sqlite::sqlite3_free(err as *mut c_void);
                s
            };
            Err(msg)
        }
    }

    /// Prepare-and-cache a statement keyed by its SQL text. Resets the
    /// statement and clears its bindings before returning, so callers can
    /// immediately bind and step.
    fn prepare_cached(&self, sql: &'static str) -> *mut sqlite::sqlite3_stmt {
        let mut cache = self.cache.borrow_mut();
        if let Some(&stmt) = cache.get(sql) {
            unsafe {
                sqlite::sqlite3_reset(stmt);
                sqlite::sqlite3_clear_bindings(stmt);
            }
            return stmt;
        }
        let mut stmt: *mut sqlite::sqlite3_stmt = ptr::null_mut();
        let rc = unsafe {
            sqlite::sqlite3_prepare_v2(
                self.db,
                sql.as_ptr() as *const c_char,
                sql.len() as c_int,
                &mut stmt,
                ptr::null_mut(),
            )
        };
        if rc != sqlite::SQLITE_OK {
            die(format!("prepare failed for `{sql}`: {}", self.errmsg()));
        }
        cache.insert(sql, stmt);
        stmt
    }

    /// Open the SQLite transaction lazily — write paths call this, read paths
    /// run under SQLite autocommit.
    fn begin_if_needed(&self) {
        if !self.in_txn.get() {
            self.exec("BEGIN");
            self.in_txn.set(true);
        }
    }

    /// Runs at Postgres `PreCommit`. A failed commit here must abort the whole
    /// Postgres transaction — so we `die` rather than warn.
    fn commit(&self) {
        if !self.in_txn.get() {
            return;
        }
        self.exec("COMMIT");
        self.in_txn.set(false);
    }

    /// Runs on the Postgres abort path — unwinding is unsafe here and there's
    /// nothing left to abort, so a failure only warns.
    fn rollback(&self) {
        if !self.in_txn.get() {
            return;
        }
        if let Err(e) = self.try_exec("ROLLBACK") {
            pgrx::warning!("sqlite_heap: ROLLBACK failed: {e}");
        }
        self.in_txn.set(false);
    }
}

impl Drop for RelConn {
    fn drop(&mut self) {
        unsafe {
            for &stmt in self.cache.borrow().values() {
                sqlite::sqlite3_finalize(stmt);
            }
            sqlite::sqlite3_close(self.db);
        }
    }
}

// SAFETY: every connection lives in thread-local storage; we never share them
// across threads. The raw pointer fields are not `Send`/`Sync` by default,
// which already enforces this.

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
                CStr::from_ptr(ptr)
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
    with_conn(rel_id, |conn| read_user_version(conn))
}

fn read_user_version(conn: &RelConn) -> i32 {
    let stmt = conn.prepare_cached("PRAGMA user_version");
    unsafe {
        let rc = sqlite::sqlite3_step(stmt);
        if rc == sqlite::SQLITE_ROW {
            sqlite::sqlite3_column_int(stmt, 0)
        } else {
            0
        }
    }
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

fn open_conn(rel_id: u32) -> RelConn {
    let path = path_for(rel_id);
    let path_c = CString::new(path.as_os_str().as_encoded_bytes())
        .expect("path contains NUL byte");
    let mut db: *mut sqlite::sqlite3 = ptr::null_mut();
    let rc = unsafe {
        sqlite::sqlite3_open_v2(
            path_c.as_ptr(),
            &mut db,
            sqlite::SQLITE_OPEN_READWRITE | sqlite::SQLITE_OPEN_CREATE,
            ptr::null(),
        )
    };
    if rc != sqlite::SQLITE_OK {
        let msg = if db.is_null() {
            "open failed (no handle)".to_string()
        } else {
            let m = unsafe {
                CStr::from_ptr(sqlite::sqlite3_errmsg(db))
                    .to_string_lossy()
                    .into_owned()
            };
            unsafe { sqlite::sqlite3_close(db); }
            m
        };
        die(format!("open {}: {}", path.display(), msg));
    }
    let conn = RelConn::new(db);

    // Per-connection PRAGMAs — SQLite resets them to defaults on every open.
    // `synchronous=FULL` is load-bearing: we commit SQLite at Postgres
    // PreCommit, so the SQLite commit must be durable before Postgres's
    // (otherwise an OS crash could leave Postgres committed but SQLite not).
    conn.exec(
        "PRAGMA synchronous=FULL;\
         PRAGMA cache_size=-8192;\
         PRAGMA temp_store=MEMORY;\
         PRAGMA busy_timeout=5000;",
    );

    let current = read_user_version(&conn);
    if current == 0 {
        install_schema(&conn);
    } else if current > SCHEMA_VERSION {
        die(format!(
            "on-disk schema v{current} is newer than supported \
             v{SCHEMA_VERSION}; refusing to read"
        ));
    } else if current < SCHEMA_VERSION {
        migrate_schema(&conn, current);
    }
    conn
}

fn install_schema(conn: &RelConn) {
    conn.exec(&format!(
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
    ));
}

/// Bring an on-disk file at version `from` up to [`SCHEMA_VERSION`].
fn migrate_schema(conn: &RelConn, from: i32) {
    if from < 2 {
        conn.exec("DROP INDEX IF EXISTS storage_dead;");
    }
    if from == 3 {
        conn.exec("ALTER TABLE storage DROP COLUMN prev;");
    }
    conn.exec(&format!("PRAGMA user_version = {SCHEMA_VERSION};"));
}

// ---- low-level statement helpers ------------------------------------------

#[inline]
unsafe fn bind_u32(stmt: *mut sqlite::sqlite3_stmt, idx: c_int, v: u32) {
    // `xmin` etc. are unsigned but fit in i64; bind via `int` (i32) to match
    // the original rusqlite encoding (and the Zig impl's `@bitCast`).
    sqlite::sqlite3_bind_int(stmt, idx, v as c_int);
}

#[inline]
unsafe fn bind_i64(stmt: *mut sqlite::sqlite3_stmt, idx: c_int, v: i64) {
    sqlite::sqlite3_bind_int64(stmt, idx, v);
}

#[inline]
unsafe fn bind_blob(
    conn: &RelConn,
    stmt: *mut sqlite::sqlite3_stmt,
    idx: c_int,
    bytes: &[u8],
) {
    let rc = sqlite::sqlite3_bind_blob(
        stmt,
        idx,
        bytes.as_ptr() as *const c_void,
        bytes.len() as c_int,
        sqlite::SQLITE_TRANSIENT(),
    );
    if rc != sqlite::SQLITE_OK {
        die(format!("bind_blob failed: {}", conn.errmsg()));
    }
}

#[inline]
unsafe fn bind_text(
    conn: &RelConn,
    stmt: *mut sqlite::sqlite3_stmt,
    idx: c_int,
    s: &str,
) {
    let rc = sqlite::sqlite3_bind_text(
        stmt,
        idx,
        s.as_ptr() as *const c_char,
        s.len() as c_int,
        sqlite::SQLITE_TRANSIENT(),
    );
    if rc != sqlite::SQLITE_OK {
        die(format!("bind_text failed: {}", conn.errmsg()));
    }
}

#[inline]
unsafe fn step_done(conn: &RelConn, stmt: *mut sqlite::sqlite3_stmt) {
    if sqlite::sqlite3_step(stmt) != sqlite::SQLITE_DONE {
        die(format!("step failed: {}", conn.errmsg()));
    }
}

#[inline]
unsafe fn step_row(conn: &RelConn, stmt: *mut sqlite::sqlite3_stmt) -> bool {
    match sqlite::sqlite3_step(stmt) {
        sqlite::SQLITE_ROW => true,
        sqlite::SQLITE_DONE => false,
        _ => die(format!("step failed: {}", conn.errmsg())),
    }
}

#[inline]
unsafe fn col_blob<'a>(stmt: *mut sqlite::sqlite3_stmt, idx: c_int) -> &'a [u8] {
    let n = sqlite::sqlite3_column_bytes(stmt, idx);
    if n <= 0 {
        return &[];
    }
    let p = sqlite::sqlite3_column_blob(stmt, idx) as *const u8;
    std::slice::from_raw_parts(p, n as usize)
}

#[inline]
unsafe fn col_i64(stmt: *mut sqlite::sqlite3_stmt, idx: c_int) -> i64 {
    sqlite::sqlite3_column_int64(stmt, idx)
}

#[inline]
unsafe fn col_u32(stmt: *mut sqlite::sqlite3_stmt, idx: c_int) -> u32 {
    sqlite::sqlite3_column_int(stmt, idx) as u32
}

#[inline]
unsafe fn header_from(stmt: *mut sqlite::sqlite3_stmt) -> StoredHeader {
    StoredHeader {
        rowid: col_i64(stmt, 0),
        xmin: col_u32(stmt, 1),
        cmin: col_u32(stmt, 2),
        xmax: col_u32(stmt, 3),
        cmax: col_u32(stmt, 4),
    }
}

// ---- public CRUD ----------------------------------------------------------

/// Read a meta key. None if the key isn't set.
pub fn meta_get(rel_id: u32, key: &str) -> Option<Vec<u8>> {
    with_conn(rel_id, |conn| {
        let stmt = conn.prepare_cached("SELECT value FROM meta WHERE key = ?1");
        unsafe {
            bind_text(conn, stmt, 1, key);
            if !step_row(conn, stmt) {
                return None;
            }
            let blob = col_blob(stmt, 0);
            Some(blob.to_vec())
        }
    })
}

/// Upsert a meta key.
pub fn meta_set(rel_id: u32, key: &str, value: &[u8]) {
    with_conn(rel_id, |conn| {
        conn.begin_if_needed();
        let stmt = conn.prepare_cached(
            "INSERT INTO meta (key, value) VALUES (?1, ?2) \
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        );
        unsafe {
            bind_text(conn, stmt, 1, key);
            bind_blob(conn, stmt, 2, value);
            step_done(conn, stmt);
        }
    });
}

/// Empty the relation's storage (CREATE TABLE, TRUNCATE, …).
pub fn reset(rel_id: u32) {
    with_conn(rel_id, |conn| {
        conn.begin_if_needed();
        conn.exec("DELETE FROM storage;");
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
                    .or_insert_with(|| open_conn(rel_id));
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
                        if let Err(e) = conn.try_exec(stmt) {
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
                        conn.try_exec(&format!("SAVEPOINT sp_{my_subid};"))
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

pub fn insert(rel_id: u32, xmin: u32, cmin: u32, bytes: &[u8]) -> i64 {
    with_conn(rel_id, |conn| {
        conn.begin_if_needed();
        let stmt = conn
            .prepare_cached("INSERT INTO storage (xmin, cmin, tuple) VALUES (?1, ?2, ?3)");
        unsafe {
            bind_u32(stmt, 1, xmin);
            bind_u32(stmt, 2, cmin);
            bind_blob(conn, stmt, 3, bytes);
            step_done(conn, stmt);
            sqlite::sqlite3_last_insert_rowid(conn.db)
        }
    })
}

/// Insert many tuples through one cached statement. Hot path for COPY and
/// `INSERT ... SELECT`.
pub fn insert_batch(rel_id: u32, xmin: u32, cmin: u32, tuples: &[&[u8]]) -> Vec<i64> {
    with_conn(rel_id, |conn| {
        conn.begin_if_needed();
        let stmt = conn
            .prepare_cached("INSERT INTO storage (xmin, cmin, tuple) VALUES (?1, ?2, ?3)");
        let mut rowids = Vec::with_capacity(tuples.len());
        unsafe {
            // xmin/cmin are constant for the whole batch — bind once.
            bind_u32(stmt, 1, xmin);
            bind_u32(stmt, 2, cmin);
            for bytes in tuples {
                bind_blob(conn, stmt, 3, bytes);
                step_done(conn, stmt);
                rowids.push(sqlite::sqlite3_last_insert_rowid(conn.db));
                sqlite::sqlite3_reset(stmt);
            }
        }
        rowids
    })
}

/// Every physical row version, for a sequential scan. `visibility::row_visible`
/// filters them down to what a given snapshot should see.
pub fn select_all(rel_id: u32) -> Vec<StoredRow> {
    with_conn(rel_id, |conn| {
        let stmt = conn.prepare_cached(
            "SELECT rowid, xmin, cmin, xmax, cmax, tuple FROM storage ORDER BY rowid",
        );
        let mut out = Vec::new();
        unsafe {
            while step_row(conn, stmt) {
                let blob = col_blob(stmt, 5);
                out.push(StoredRow {
                    header: header_from(stmt),
                    tuple: blob.to_vec(),
                });
            }
        }
        out
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
        // SQL string depends on rowids.len(); we can't share it across batch
        // sizes via prepare_cached, but `INSERT ... SELECT` and btree-bottom-up
        // calls hit the same size repeatedly so caching by content is still a
        // win.
        let mut sql = String::from("SELECT rowid, xmax FROM storage WHERE rowid IN (");
        for i in 0..rowids.len() {
            if i > 0 {
                sql.push(',');
            }
            sql.push('?');
        }
        sql.push(')');
        // Leak the SQL into a 'static so prepare_cached can key on it. The
        // unique-per-batch-size leak is bounded (at most a few sizes).
        let sql_static: &'static str = Box::leak(sql.into_boxed_str());
        let stmt = conn.prepare_cached(sql_static);
        let mut map =
            FxHashMap::with_capacity_and_hasher(rowids.len(), Default::default());
        unsafe {
            for (i, &rid) in rowids.iter().enumerate() {
                bind_i64(stmt, (i as c_int) + 1, rid);
            }
            while step_row(conn, stmt) {
                let rid = col_i64(stmt, 0);
                let xmax = col_u32(stmt, 1);
                map.insert(rid, xmax);
            }
        }
        map
    })
}

pub fn select_one(rel_id: u32, rowid: i64) -> Option<StoredRow> {
    with_conn(rel_id, |conn| {
        let stmt = conn.prepare_cached(
            "SELECT rowid, xmin, cmin, xmax, cmax, tuple FROM storage WHERE rowid = ?1",
        );
        unsafe {
            bind_i64(stmt, 1, rowid);
            if !step_row(conn, stmt) {
                return None;
            }
            let blob = col_blob(stmt, 5);
            Some(StoredRow {
                header: header_from(stmt),
                tuple: blob.to_vec(),
            })
        }
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
        let stmt = conn.prepare_cached(
            "SELECT rowid, xmin, cmin, xmax, cmax, tuple FROM storage WHERE rowid = ?1",
        );
        unsafe {
            bind_i64(stmt, 1, rowid);
            if !step_row(conn, stmt) {
                return false;
            }
            let header = header_from(stmt);
            let blob = col_blob(stmt, 5);
            f(&header, blob)
        }
    })
}

/// Mark a row deleted by setting its xmax/cmax. Returns rows affected (0 if the
/// rowid doesn't exist or was already marked).
pub fn set_xmax(rel_id: u32, rowid: i64, xmax: u32, cmax: u32) -> usize {
    with_conn(rel_id, |conn| {
        conn.begin_if_needed();
        let stmt = conn.prepare_cached(
            "UPDATE storage SET xmax = ?1, cmax = ?2 WHERE rowid = ?3 AND xmax = 0",
        );
        unsafe {
            bind_u32(stmt, 1, xmax);
            bind_u32(stmt, 2, cmax);
            bind_i64(stmt, 3, rowid);
            step_done(conn, stmt);
            sqlite::sqlite3_changes(conn.db) as usize
        }
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
        let upd = conn.prepare_cached(
            "UPDATE storage SET xmax = ?1, cmax = ?2 WHERE rowid = ?3 AND xmax = 0",
        );
        unsafe {
            bind_u32(upd, 1, xid);
            bind_u32(upd, 2, cid);
            bind_i64(upd, 3, old_rowid);
            step_done(conn, upd);
        }
        let ins = conn.prepare_cached(
            "INSERT INTO storage (xmin, cmin, tuple) VALUES (?1, ?2, ?3)",
        );
        unsafe {
            bind_u32(ins, 1, xid);
            bind_u32(ins, 2, cid);
            bind_blob(conn, ins, 3, new_bytes);
            step_done(conn, ins);
            sqlite::sqlite3_last_insert_rowid(conn.db)
        }
    })
}

/// Physically remove a row by rowid — retracts a speculative insert that lost
/// a conflict.
pub fn physical_delete(rel_id: u32, rowid: i64) -> usize {
    with_conn(rel_id, |conn| {
        conn.begin_if_needed();
        let stmt = conn.prepare_cached("DELETE FROM storage WHERE rowid = ?1");
        unsafe {
            bind_i64(stmt, 1, rowid);
            step_done(conn, stmt);
            sqlite::sqlite3_changes(conn.db) as usize
        }
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
        let stmt = conn
            .prepare_cached("DELETE FROM storage WHERE xmax != 0 AND xmax < ?1");
        unsafe {
            bind_u32(stmt, 1, oldest_xmin);
            step_done(conn, stmt);
            sqlite::sqlite3_changes(conn.db) as usize
        }
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
        let stmt = conn.prepare_cached("SELECT count(*) FROM storage");
        unsafe {
            if step_row(conn, stmt) {
                col_i64(stmt, 0)
            } else {
                0
            }
        }
    });
    (bytes, tuples)
}
