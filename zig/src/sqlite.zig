//! Per-table SQLite backend: connection cache, lazy transactions, schema
//! install/migration, durability, and the CRUD surface the table AM builds on.
//!
//! This is the Zig port of the Rust `sqlite.rs`. The shapes match: one SQLite
//! file per relation under `$PGDATA/sqlite_heap_zig/<dbOid>/<relOid>.sqlite`,
//! a `storage` table holding the MVCC header columns plus the opaque tuple
//! blob, and a `meta` key/value table.

const std = @import("std");
const pg = @import("pg.zig");

const alloc = std.heap.c_allocator;

// --- minimal SQLite C bindings -------------------------------------------
//
// Hand-declared rather than `@cImport`ed: it keeps the SQLite ABI surface
// explicit and sidesteps translate-c entirely.
const sqlite = struct {
    const sqlite3 = opaque {};
    const sqlite3_stmt = opaque {};

    const OK: c_int = 0;
    const ROW: c_int = 100;
    const DONE: c_int = 101;

    // SQLITE_TRANSIENT: tell SQLite to copy bound blobs/text immediately.
    const TRANSIENT: ?*const anyopaque = @ptrFromInt(std.math.maxInt(usize));

    extern fn sqlite3_open(filename: [*:0]const u8, db: *?*sqlite3) c_int;
    extern fn sqlite3_close(db: ?*sqlite3) c_int;
    extern fn sqlite3_exec(
        db: ?*sqlite3,
        sql: [*:0]const u8,
        cb: ?*const anyopaque,
        arg: ?*anyopaque,
        errmsg: ?*?[*:0]u8,
    ) c_int;
    extern fn sqlite3_prepare_v2(
        db: ?*sqlite3,
        sql: [*]const u8,
        nbyte: c_int,
        stmt: *?*sqlite3_stmt,
        tail: ?*?[*:0]const u8,
    ) c_int;
    extern fn sqlite3_step(stmt: ?*sqlite3_stmt) c_int;
    extern fn sqlite3_finalize(stmt: ?*sqlite3_stmt) c_int;
    extern fn sqlite3_reset(stmt: ?*sqlite3_stmt) c_int;
    extern fn sqlite3_clear_bindings(stmt: ?*sqlite3_stmt) c_int;
    extern fn sqlite3_bind_int64(stmt: ?*sqlite3_stmt, idx: c_int, v: i64) c_int;
    extern fn sqlite3_bind_int(stmt: ?*sqlite3_stmt, idx: c_int, v: c_int) c_int;
    extern fn sqlite3_bind_blob(
        stmt: ?*sqlite3_stmt,
        idx: c_int,
        v: ?*const anyopaque,
        n: c_int,
        destructor: ?*const anyopaque,
    ) c_int;
    extern fn sqlite3_bind_text(
        stmt: ?*sqlite3_stmt,
        idx: c_int,
        v: [*]const u8,
        n: c_int,
        destructor: ?*const anyopaque,
    ) c_int;
    extern fn sqlite3_column_int64(stmt: ?*sqlite3_stmt, col: c_int) i64;
    extern fn sqlite3_column_int(stmt: ?*sqlite3_stmt, col: c_int) c_int;
    extern fn sqlite3_column_blob(stmt: ?*sqlite3_stmt, col: c_int) ?*const anyopaque;
    extern fn sqlite3_column_bytes(stmt: ?*sqlite3_stmt, col: c_int) c_int;
    extern fn sqlite3_last_insert_rowid(db: ?*sqlite3) i64;
    extern fn sqlite3_changes(db: ?*sqlite3) c_int;
    extern fn sqlite3_errmsg(db: ?*sqlite3) [*:0]const u8;
};

/// Current on-disk schema, written to each file's `PRAGMA user_version`.
const SCHEMA_VERSION: i32 = 4;

/// A row's MVCC bookkeeping -- enough to decide visibility without the blob.
pub const StoredHeader = struct {
    rowid: i64,
    xmin: u32,
    cmin: u32,
    xmax: u32,
    cmax: u32,
};

/// A stored row: MVCC header plus the opaque tuple bytes (`alloc`-owned).
pub const StoredRow = struct {
    header: StoredHeader,
    tuple: []u8,
};

// --- backend-lifetime state ----------------------------------------------

/// A SQLite connection plus its lazy-transaction state and prepared-statement
/// cache. The SQLite transaction opens lazily, on the first write.
const RelConn = struct {
    db: *sqlite.sqlite3,
    in_txn: bool = false,
    /// Keyed by the (static) SQL text -- mirrors rusqlite's `prepare_cached`.
    stmt_cache: std.StringHashMapUnmanaged(*sqlite.sqlite3_stmt) = .empty,

    fn beginIfNeeded(self: *RelConn) void {
        if (!self.in_txn) {
            self.execBatch("BEGIN");
            self.in_txn = true;
        }
    }

    /// Runs at PostgreSQL PreCommit. A failed commit must abort the whole
    /// PostgreSQL transaction, so this raises an ERROR rather than a WARNING.
    fn commit(self: *RelConn) void {
        if (!self.in_txn) return;
        self.execBatch("COMMIT");
        self.in_txn = false;
    }

    /// Runs on the PostgreSQL abort path -- there is nothing left to abort, so
    /// a failure only warns.
    fn rollback(self: *RelConn) void {
        if (!self.in_txn) return;
        if (sqlite.sqlite3_exec(self.db, "ROLLBACK", null, null, null) != sqlite.OK) {
            pg.warn("sqlite_heap_zig: ROLLBACK failed: {s}", .{sqlite.sqlite3_errmsg(self.db)});
        }
        self.in_txn = false;
    }

    fn execBatch(self: *RelConn, sql: [*:0]const u8) void {
        if (sqlite.sqlite3_exec(self.db, sql, null, null, null) != sqlite.OK) {
            pg.fail("sqlite_heap_zig: `{s}` failed: {s}", .{ sql, sqlite.sqlite3_errmsg(self.db) });
        }
    }

    /// Look up (or prepare-and-cache) a statement. The returned statement has
    /// been `reset` and had its bindings cleared.
    fn prepareCached(self: *RelConn, sql: [:0]const u8) *sqlite.sqlite3_stmt {
        if (self.stmt_cache.get(sql)) |stmt| {
            _ = sqlite.sqlite3_reset(stmt);
            _ = sqlite.sqlite3_clear_bindings(stmt);
            return stmt;
        }
        var stmt: ?*sqlite.sqlite3_stmt = null;
        if (sqlite.sqlite3_prepare_v2(self.db, sql.ptr, -1, &stmt, null) != sqlite.OK) {
            pg.fail("sqlite_heap_zig: prepare failed: {s}", .{sqlite.sqlite3_errmsg(self.db)});
        }
        self.stmt_cache.put(alloc, sql, stmt.?) catch pg.fail("sqlite_heap_zig: out of memory", .{});
        return stmt.?;
    }
};

var conns: std.AutoHashMapUnmanaged(u32, *RelConn) = .empty;
/// Relations with state to commit/abort in the current PostgreSQL transaction.
var tx_rels: std.AutoHashMapUnmanaged(u32, void) = .empty;
/// Relations whose files should be unlinked when the current transaction
/// commits (deferred so a rolled-back DROP leaves the file intact).
var pending_drops: std.ArrayList(u32) = .empty;
/// `$PGDATA/sqlite_heap_zig/<dbOid>/`, computed once per backend.
var sqlite_dir: ?[:0]u8 = null;
var callbacks_registered: bool = false;

// --- directory / paths ---------------------------------------------------

fn dir() [:0]const u8 {
    if (sqlite_dir) |d| return d;
    const data_dir = std.mem.span(pg.shim_data_dir());
    const db_oid = pg.shim_my_database_id();
    const path = std.fmt.allocPrintSentinel(
        alloc,
        "{s}/sqlite_heap_zig/{d}",
        .{ data_dir, db_oid },
        0,
    ) catch pg.fail("sqlite_heap_zig: out of memory", .{});
    if (pg.shim_mkdir_p(path.ptr) != 0) {
        pg.fail("sqlite_heap_zig: could not create directory {s}", .{path});
    }
    sqlite_dir = path;
    return path;
}

/// On-disk path of the SQLite file backing `rel_id`. Caller owns the result.
fn pathFor(rel_id: u32) [:0]u8 {
    return std.fmt.allocPrintSentinel(
        alloc,
        "{s}/{d}.sqlite",
        .{ dir(), rel_id },
        0,
    ) catch pg.fail("sqlite_heap_zig: out of memory", .{});
}

pub fn filePath(rel_id: u32) [:0]u8 {
    return pathFor(rel_id);
}

// --- schema --------------------------------------------------------------

fn openConn(rel_id: u32) *RelConn {
    const path = pathFor(rel_id);
    defer alloc.free(path);

    var db: ?*sqlite.sqlite3 = null;
    if (sqlite.sqlite3_open(path.ptr, &db) != sqlite.OK) {
        pg.fail("sqlite_heap_zig: could not open {s}", .{path});
    }
    const handle = db.?;

    // Per-connection PRAGMAs -- SQLite resets them on every open.
    // `synchronous=FULL` is load-bearing: the SQLite commit at PostgreSQL
    // PreCommit must be durable before PostgreSQL's own commit record.
    if (sqlite.sqlite3_exec(handle,
        "PRAGMA synchronous=FULL;" ++
            "PRAGMA cache_size=-8192;" ++
            "PRAGMA temp_store=MEMORY;" ++
            "PRAGMA busy_timeout=5000;", null, null, null) != sqlite.OK)
    {
        pg.fail("sqlite_heap_zig: PRAGMA setup failed: {s}", .{sqlite.sqlite3_errmsg(handle)});
    }

    const rc = alloc.create(RelConn) catch pg.fail("sqlite_heap_zig: out of memory", .{});
    rc.* = .{ .db = handle };

    const current = userVersion(rc);
    if (current == 0) {
        installSchema(rc);
    } else if (current > SCHEMA_VERSION) {
        pg.fail(
            "sqlite_heap_zig: on-disk schema v{d} is newer than supported v{d}; refusing to read",
            .{ current, SCHEMA_VERSION },
        );
    } else if (current < SCHEMA_VERSION) {
        migrateSchema(rc, current);
    }
    return rc;
}

fn userVersion(rc: *RelConn) i32 {
    const stmt = rc.prepareCached("PRAGMA user_version");
    const version: i32 = if (sqlite.sqlite3_step(stmt) == sqlite.ROW)
        @intCast(sqlite.sqlite3_column_int(stmt, 0))
    else
        0;
    // Reset so the statement does not keep an implicit read transaction open
    // (which would, among other things, block `PRAGMA journal_mode=WAL`).
    _ = sqlite.sqlite3_reset(stmt);
    return version;
}

fn installSchema(rc: *RelConn) void {
    var buf: [512]u8 = undefined;
    const sql = std.fmt.bufPrintZ(&buf,
        "PRAGMA journal_mode=WAL;" ++
            "CREATE TABLE IF NOT EXISTS storage (" ++
            "rowid INTEGER PRIMARY KEY, " ++
            "xmin INTEGER NOT NULL, " ++
            "cmin INTEGER NOT NULL DEFAULT 0, " ++
            "xmax INTEGER NOT NULL DEFAULT 0, " ++
            "cmax INTEGER NOT NULL DEFAULT 0, " ++
            "tuple BLOB NOT NULL);" ++
            "CREATE TABLE IF NOT EXISTS meta (" ++
            "key TEXT PRIMARY KEY, value BLOB NOT NULL);" ++
            "PRAGMA user_version = {d};", .{SCHEMA_VERSION}) catch unreachable;
    rc.execBatch(sql.ptr);
}

/// Bring an on-disk file at version `from` up to `SCHEMA_VERSION`.
fn migrateSchema(rc: *RelConn, from: i32) void {
    if (from < 2) {
        rc.execBatch("DROP INDEX IF EXISTS storage_dead;");
    }
    if (from == 3) {
        rc.execBatch("ALTER TABLE storage DROP COLUMN prev;");
    }
    var buf: [64]u8 = undefined;
    const sql = std.fmt.bufPrintZ(&buf, "PRAGMA user_version = {d};", .{SCHEMA_VERSION}) catch unreachable;
    rc.execBatch(sql.ptr);
}

/// The SQLite `PRAGMA user_version` of `rel_id`'s file.
pub fn schemaVersion(rel_id: u32) i32 {
    return userVersion(connFor(rel_id));
}

// --- connection registration & transaction lifecycle --------------------

fn connFor(rel_id: u32) *RelConn {
    ensureInXact(rel_id);
    return conns.get(rel_id).?;
}

fn ensureInXact(rel_id: u32) void {
    if (!callbacks_registered) {
        pg.shim_register_xact_callbacks();
        callbacks_registered = true;
    }

    if (conns.get(rel_id) == null) {
        const rc = openConn(rel_id);
        conns.put(alloc, rel_id, rc) catch pg.fail("sqlite_heap_zig: out of memory", .{});
    }
    tx_rels.put(alloc, rel_id, {}) catch pg.fail("sqlite_heap_zig: out of memory", .{});
}

fn runOnTxnConns(sql: [*:0]const u8) void {
    var it = tx_rels.keyIterator();
    while (it.next()) |rel_id| {
        if (conns.get(rel_id.*)) |rc| {
            if (rc.in_txn) {
                if (sqlite.sqlite3_exec(rc.db, sql, null, null, null) != sqlite.OK) {
                    pg.warn("sqlite_heap_zig: `{s}` failed: {s}", .{ sql, sqlite.sqlite3_errmsg(rc.db) });
                }
            }
        }
    }
}

/// Commit SQLite at PostgreSQL PreCommit -- before PostgreSQL writes its own
/// commit record. The only crash window then leaves SQLite *ahead*, which
/// self-heals: those rows' xmin shows as aborted in CLOG so visibility hides
/// them. The reverse ordering would leave committed-but-missing data.
pub fn onPrecommit() void {
    var it = tx_rels.keyIterator();
    while (it.next()) |rel_id| {
        if (conns.get(rel_id.*)) |rc| rc.commit();
    }
    tx_rels.clearRetainingCapacity();
}

/// Runs after PostgreSQL's commit record is durable: reclaim the files of
/// tables dropped in this transaction.
pub fn onCommit() void {
    for (pending_drops.items) |rel_id| unlinkStorage(rel_id);
    pending_drops.clearRetainingCapacity();
}

pub fn onAbort() void {
    var it = tx_rels.keyIterator();
    while (it.next()) |rel_id| {
        if (conns.get(rel_id.*)) |rc| rc.rollback();
    }
    tx_rels.clearRetainingCapacity();
    // A rolled-back DROP must leave the file intact -- just forget the intent.
    pending_drops.clearRetainingCapacity();
}

/// A savepoint needs an enclosing transaction; force one open on every touched
/// relation so writes inside the subxact are savepointed.
pub fn onSubStart(my_subid: u32) void {
    var buf: [48]u8 = undefined;
    const sql = std.fmt.bufPrintZ(&buf, "SAVEPOINT sp_{d};", .{my_subid}) catch unreachable;
    var it = tx_rels.keyIterator();
    while (it.next()) |rel_id| {
        if (conns.get(rel_id.*)) |rc| {
            rc.beginIfNeeded();
            if (sqlite.sqlite3_exec(rc.db, sql.ptr, null, null, null) != sqlite.OK) {
                pg.warn("sqlite_heap_zig: savepoint failed: {s}", .{sqlite.sqlite3_errmsg(rc.db)});
            }
        }
    }
}

pub fn onSubCommit(my_subid: u32) void {
    var buf: [56]u8 = undefined;
    const sql = std.fmt.bufPrintZ(&buf, "RELEASE SAVEPOINT sp_{d};", .{my_subid}) catch unreachable;
    runOnTxnConns(sql.ptr);
}

pub fn onSubAbort(my_subid: u32) void {
    var buf: [64]u8 = undefined;
    const sql = std.fmt.bufPrintZ(&buf, "ROLLBACK TO SAVEPOINT sp_{d};", .{my_subid}) catch unreachable;
    runOnTxnConns(sql.ptr);
}

// --- drop ----------------------------------------------------------------

/// Reclaim a relation's file at commit time.
pub fn dropRelation(rel_id: u32) void {
    pending_drops.append(alloc, rel_id) catch pg.fail("sqlite_heap_zig: out of memory", .{});
}

fn unlinkStorage(rel_id: u32) void {
    if (conns.fetchRemove(rel_id)) |kv| {
        _ = sqlite.sqlite3_close(kv.value.db);
        var sit = kv.value.stmt_cache.valueIterator();
        while (sit.next()) |stmt| _ = sqlite.sqlite3_finalize(stmt.*);
        kv.value.stmt_cache.deinit(alloc);
        alloc.destroy(kv.value);
    }
    _ = tx_rels.remove(rel_id);

    const base = pathFor(rel_id);
    defer alloc.free(base);
    pg.shim_unlink(base.ptr);

    // SQLite's WAL and shared-memory sidecar files.
    var buf: [4096]u8 = undefined;
    if (std.fmt.bufPrintZ(&buf, "{s}-wal", .{base})) |wal| {
        pg.shim_unlink(wal.ptr);
    } else |_| {}
    if (std.fmt.bufPrintZ(&buf, "{s}-shm", .{base})) |shm| {
        pg.shim_unlink(shm.ptr);
    } else |_| {}
}

// --- row decoding --------------------------------------------------------

/// Decode `rowid, xmin, cmin, xmax, cmax` from the first five columns -- the
/// shared row-query layout.
fn headerFromStmt(stmt: *sqlite.sqlite3_stmt) StoredHeader {
    return .{
        .rowid = sqlite.sqlite3_column_int64(stmt, 0),
        .xmin = @bitCast(sqlite.sqlite3_column_int(stmt, 1)),
        .cmin = @bitCast(sqlite.sqlite3_column_int(stmt, 2)),
        .xmax = @bitCast(sqlite.sqlite3_column_int(stmt, 3)),
        .cmax = @bitCast(sqlite.sqlite3_column_int(stmt, 4)),
    };
}

fn blobColumn(stmt: *sqlite.sqlite3_stmt, col: c_int) []const u8 {
    const n: usize = @intCast(sqlite.sqlite3_column_bytes(stmt, col));
    if (n == 0) return &[_]u8{};
    const ptr = sqlite.sqlite3_column_blob(stmt, col) orelse return &[_]u8{};
    return @as([*]const u8, @ptrCast(ptr))[0..n];
}

// --- CRUD ----------------------------------------------------------------

const SELECT_COLS = "SELECT rowid, xmin, cmin, xmax, cmax, tuple FROM storage";

pub fn insert(rel_id: u32, xmin: u32, cmin: u32, bytes: []const u8) i64 {
    const rc = connFor(rel_id);
    rc.beginIfNeeded();
    const stmt = rc.prepareCached("INSERT INTO storage (xmin, cmin, tuple) VALUES (?1, ?2, ?3)");
    bindInsert(rc, stmt, xmin, cmin, bytes);
    stepDone(rc, stmt);
    return sqlite.sqlite3_last_insert_rowid(rc.db);
}

/// Insert many tuples through one cached statement -- the hot path for COPY
/// and `INSERT ... SELECT`. The returned rowid slice is `alloc`-owned.
pub fn insertBatch(rel_id: u32, xmin: u32, cmin: u32, tuples: []const []const u8) []i64 {
    const rc = connFor(rel_id);
    rc.beginIfNeeded();
    const stmt = rc.prepareCached("INSERT INTO storage (xmin, cmin, tuple) VALUES (?1, ?2, ?3)");
    const rowids = alloc.alloc(i64, tuples.len) catch pg.fail("sqlite_heap_zig: out of memory", .{});
    for (tuples, 0..) |bytes, i| {
        _ = sqlite.sqlite3_reset(stmt);
        bindInsert(rc, stmt, xmin, cmin, bytes);
        stepDone(rc, stmt);
        rowids[i] = sqlite.sqlite3_last_insert_rowid(rc.db);
    }
    return rowids;
}

fn bindInsert(rc: *RelConn, stmt: *sqlite.sqlite3_stmt, xmin: u32, cmin: u32, bytes: []const u8) void {
    _ = sqlite.sqlite3_bind_int(stmt, 1, @bitCast(xmin));
    _ = sqlite.sqlite3_bind_int(stmt, 2, @bitCast(cmin));
    const rc_bind = sqlite.sqlite3_bind_blob(stmt, 3, bytes.ptr, @intCast(bytes.len), sqlite.TRANSIENT);
    if (rc_bind != sqlite.OK) pg.fail("sqlite_heap_zig: bind failed: {s}", .{sqlite.sqlite3_errmsg(rc.db)});
}

fn stepDone(rc: *RelConn, stmt: *sqlite.sqlite3_stmt) void {
    if (sqlite.sqlite3_step(stmt) != sqlite.DONE) {
        pg.fail("sqlite_heap_zig: step failed: {s}", .{sqlite.sqlite3_errmsg(rc.db)});
    }
}

/// Every physical row version, for a sequential scan. The caller frees the
/// result with `freeRows`.
pub fn selectAll(rel_id: u32) []StoredRow {
    const rc = connFor(rel_id);
    const stmt = rc.prepareCached(SELECT_COLS ++ " ORDER BY rowid");
    var rows: std.ArrayList(StoredRow) = .empty;
    while (true) {
        const step = sqlite.sqlite3_step(stmt);
        if (step == sqlite.DONE) break;
        if (step != sqlite.ROW) {
            pg.fail("sqlite_heap_zig: scan failed: {s}", .{sqlite.sqlite3_errmsg(rc.db)});
        }
        const blob = blobColumn(stmt, 5);
        const tuple = alloc.dupe(u8, blob) catch pg.fail("sqlite_heap_zig: out of memory", .{});
        rows.append(alloc, .{ .header = headerFromStmt(stmt), .tuple = tuple }) catch
            pg.fail("sqlite_heap_zig: out of memory", .{});
    }
    return rows.toOwnedSlice(alloc) catch pg.fail("sqlite_heap_zig: out of memory", .{});
}

pub fn freeRows(rows: []StoredRow) void {
    for (rows) |row| alloc.free(row.tuple);
    alloc.free(rows);
}

pub fn selectOne(rel_id: u32, rowid: i64) ?StoredRow {
    const rc = connFor(rel_id);
    const stmt = rc.prepareCached(SELECT_COLS ++ " WHERE rowid = ?1");
    _ = sqlite.sqlite3_bind_int64(stmt, 1, rowid);
    const step = sqlite.sqlite3_step(stmt);
    if (step == sqlite.DONE) return null;
    if (step != sqlite.ROW) {
        pg.fail("sqlite_heap_zig: select_one failed: {s}", .{sqlite.sqlite3_errmsg(rc.db)});
    }
    const blob = blobColumn(stmt, 5);
    const tuple = alloc.dupe(u8, blob) catch pg.fail("sqlite_heap_zig: out of memory", .{});
    const row = StoredRow{ .header = headerFromStmt(stmt), .tuple = tuple };
    _ = sqlite.sqlite3_reset(stmt);
    return row;
}

/// Fetch one row by rowid, handing `ctx`'s callback the header and a borrowed
/// view of the blob straight from SQLite's page cache. Returns the callback's
/// result, or `false` if the row does not exist.
pub fn fetchOneRef(
    rel_id: u32,
    rowid: i64,
    ctx: anytype,
    comptime f: fn (@TypeOf(ctx), *const StoredHeader, []const u8) bool,
) bool {
    const rc = connFor(rel_id);
    const stmt = rc.prepareCached(SELECT_COLS ++ " WHERE rowid = ?1");
    _ = sqlite.sqlite3_bind_int64(stmt, 1, rowid);
    const step = sqlite.sqlite3_step(stmt);
    if (step == sqlite.DONE) return false;
    if (step != sqlite.ROW) {
        pg.fail("sqlite_heap_zig: fetch_one failed: {s}", .{sqlite.sqlite3_errmsg(rc.db)});
    }
    const header = headerFromStmt(stmt);
    const blob = blobColumn(stmt, 5);
    const result = f(ctx, &header, blob);
    // The callback is done with the borrowed blob; release the implicit
    // read transaction the unfinished statement is holding.
    _ = sqlite.sqlite3_reset(stmt);
    return result;
}

/// The `xmax` of many rowids in one `WHERE rowid IN (...)` query. A rowid
/// absent from the result is not physically present. The returned map is
/// `alloc`-owned; caller `deinit`s it.
pub fn selectXmaxBatch(rel_id: u32, rowids: []const i64) std.AutoHashMapUnmanaged(i64, u32) {
    var map: std.AutoHashMapUnmanaged(i64, u32) = .empty;
    if (rowids.len == 0) return map;

    const rc = connFor(rel_id);

    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(alloc);
    sql.appendSlice(alloc, "SELECT rowid, xmax FROM storage WHERE rowid IN (") catch
        pg.fail("sqlite_heap_zig: out of memory", .{});
    for (0..rowids.len) |i| {
        if (i > 0) sql.append(alloc, ',') catch pg.fail("sqlite_heap_zig: out of memory", .{});
        sql.append(alloc, '?') catch pg.fail("sqlite_heap_zig: out of memory", .{});
    }
    sql.appendSlice(alloc, ")") catch pg.fail("sqlite_heap_zig: out of memory", .{});
    sql.append(alloc, 0) catch pg.fail("sqlite_heap_zig: out of memory", .{});

    var stmt: ?*sqlite.sqlite3_stmt = null;
    if (sqlite.sqlite3_prepare_v2(rc.db, sql.items.ptr, -1, &stmt, null) != sqlite.OK) {
        pg.fail("sqlite_heap_zig: prepare failed: {s}", .{sqlite.sqlite3_errmsg(rc.db)});
    }
    defer _ = sqlite.sqlite3_finalize(stmt);

    for (rowids, 0..) |rid, i| {
        _ = sqlite.sqlite3_bind_int64(stmt, @intCast(i + 1), rid);
    }
    map.ensureTotalCapacity(alloc, @intCast(rowids.len)) catch pg.fail("sqlite_heap_zig: out of memory", .{});
    while (true) {
        const step = sqlite.sqlite3_step(stmt);
        if (step == sqlite.DONE) break;
        if (step != sqlite.ROW) {
            pg.fail("sqlite_heap_zig: xmax batch failed: {s}", .{sqlite.sqlite3_errmsg(rc.db)});
        }
        const rid = sqlite.sqlite3_column_int64(stmt, 0);
        const xmax: u32 = @bitCast(sqlite.sqlite3_column_int(stmt, 1));
        map.put(alloc, rid, xmax) catch pg.fail("sqlite_heap_zig: out of memory", .{});
    }
    return map;
}

/// Mark a row deleted by setting its xmax/cmax. Returns rows affected (0 if the
/// rowid does not exist or was already marked).
pub fn setXmax(rel_id: u32, rowid: i64, xmax: u32, cmax: u32) usize {
    const rc = connFor(rel_id);
    rc.beginIfNeeded();
    const stmt = rc.prepareCached("UPDATE storage SET xmax = ?1, cmax = ?2 WHERE rowid = ?3 AND xmax = 0");
    _ = sqlite.sqlite3_bind_int(stmt, 1, @bitCast(xmax));
    _ = sqlite.sqlite3_bind_int(stmt, 2, @bitCast(cmax));
    _ = sqlite.sqlite3_bind_int64(stmt, 3, rowid);
    stepDone(rc, stmt);
    return @intCast(sqlite.sqlite3_changes(rc.db));
}

/// An UPDATE is MVCC delete-old + insert-new: stamp the old row dead and insert
/// the new version at a fresh rowid. Returns the new rowid.
pub fn updateRow(rel_id: u32, old_rowid: i64, xid: u32, cid: u32, new_bytes: []const u8) i64 {
    const rc = connFor(rel_id);
    rc.beginIfNeeded();

    const del = rc.prepareCached("UPDATE storage SET xmax = ?1, cmax = ?2 WHERE rowid = ?3 AND xmax = 0");
    _ = sqlite.sqlite3_bind_int(del, 1, @bitCast(xid));
    _ = sqlite.sqlite3_bind_int(del, 2, @bitCast(cid));
    _ = sqlite.sqlite3_bind_int64(del, 3, old_rowid);
    stepDone(rc, del);

    const ins = rc.prepareCached("INSERT INTO storage (xmin, cmin, tuple) VALUES (?1, ?2, ?3)");
    bindInsert(rc, ins, xid, cid, new_bytes);
    stepDone(rc, ins);
    return sqlite.sqlite3_last_insert_rowid(rc.db);
}

/// Physically remove a row by rowid -- retracts a speculative insert that lost
/// a conflict.
pub fn physicalDelete(rel_id: u32, rowid: i64) usize {
    const rc = connFor(rel_id);
    rc.beginIfNeeded();
    const stmt = rc.prepareCached("DELETE FROM storage WHERE rowid = ?1");
    _ = sqlite.sqlite3_bind_int64(stmt, 1, rowid);
    stepDone(rc, stmt);
    return @intCast(sqlite.sqlite3_changes(rc.db));
}

const META_LAST_VACUUM_XMIN = "last_vacuum_xmin";

/// Physically remove rows whose `xmax` is committed and globally visible.
/// Skipped if a prior VACUUM already reached this `oldest_xmin`.
pub fn vacuumDead(rel_id: u32, oldest_xmin: u32) usize {
    const last: u32 = blk: {
        const v = metaGet(rel_id, META_LAST_VACUUM_XMIN) orelse break :blk 0;
        defer alloc.free(v);
        if (v.len != 4) break :blk 0;
        break :blk std.mem.readInt(u32, v[0..4], .little);
    };
    if (oldest_xmin <= last) return 0;

    const rc = connFor(rel_id);
    rc.beginIfNeeded();
    const stmt = rc.prepareCached("DELETE FROM storage WHERE xmax != 0 AND xmax < ?1");
    _ = sqlite.sqlite3_bind_int(stmt, 1, @bitCast(oldest_xmin));
    stepDone(rc, stmt);
    const removed: usize = @intCast(sqlite.sqlite3_changes(rc.db));

    var le: [4]u8 = undefined;
    std.mem.writeInt(u32, &le, oldest_xmin, .little);
    metaSet(rel_id, META_LAST_VACUUM_XMIN, &le);
    return removed;
}

/// Planner size estimate `(file_bytes, tuple_count)`.
pub fn estimateSize(rel_id: u32) struct { bytes: u64, tuples: i64 } {
    const path = pathFor(rel_id);
    defer alloc.free(path);
    const bytes: u64 = @intCast(pg.shim_file_size(path.ptr));

    const rc = connFor(rel_id);
    const stmt = rc.prepareCached("SELECT count(*) FROM storage");
    const tuples: i64 = if (sqlite.sqlite3_step(stmt) == sqlite.ROW)
        sqlite.sqlite3_column_int64(stmt, 0)
    else
        0;
    _ = sqlite.sqlite3_reset(stmt);
    return .{ .bytes = bytes, .tuples = tuples };
}

/// Empty the relation's storage (CREATE TABLE, TRUNCATE, ...).
pub fn reset(rel_id: u32) void {
    const rc = connFor(rel_id);
    rc.beginIfNeeded();
    rc.execBatch("DELETE FROM storage;");
}

// --- meta ----------------------------------------------------------------

/// Read a meta key. The result, if present, is `alloc`-owned.
pub fn metaGet(rel_id: u32, key: []const u8) ?[]u8 {
    const rc = connFor(rel_id);
    const stmt = rc.prepareCached("SELECT value FROM meta WHERE key = ?1");
    _ = sqlite.sqlite3_bind_text(stmt, 1, key.ptr, @intCast(key.len), sqlite.TRANSIENT);
    if (sqlite.sqlite3_step(stmt) != sqlite.ROW) {
        _ = sqlite.sqlite3_reset(stmt);
        return null;
    }
    const blob = blobColumn(stmt, 0);
    const value = alloc.dupe(u8, blob) catch pg.fail("sqlite_heap_zig: out of memory", .{});
    _ = sqlite.sqlite3_reset(stmt);
    return value;
}

/// Upsert a meta key.
pub fn metaSet(rel_id: u32, key: []const u8, value: []const u8) void {
    const rc = connFor(rel_id);
    rc.beginIfNeeded();
    const stmt = rc.prepareCached(
        "INSERT INTO meta (key, value) VALUES (?1, ?2) " ++
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
    );
    _ = sqlite.sqlite3_bind_text(stmt, 1, key.ptr, @intCast(key.len), sqlite.TRANSIENT);
    _ = sqlite.sqlite3_bind_blob(stmt, 2, value.ptr, @intCast(value.len), sqlite.TRANSIENT);
    stepDone(rc, stmt);
}

// --- file listing --------------------------------------------------------

pub const FileEntry = struct { oid: u32, bytes: u64 };

const ListCtx = struct {
    list: *std.ArrayList(FileEntry),
    dir_path: []const u8,
};

fn listDirCallback(ctx_opaque: ?*anyopaque, name_z: [*:0]const u8) callconv(.c) void {
    const ctx: *ListCtx = @ptrCast(@alignCast(ctx_opaque.?));
    const name = std.mem.span(name_z);
    if (!std.mem.endsWith(u8, name, ".sqlite")) return;
    const stem = name[0 .. name.len - ".sqlite".len];
    const oid = std.fmt.parseInt(u32, stem, 10) catch return;

    var buf: [4096]u8 = undefined;
    const full = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ ctx.dir_path, name }) catch return;
    const bytes: u64 = @intCast(pg.shim_file_size(full.ptr));
    ctx.list.append(alloc, .{ .oid = oid, .bytes = bytes }) catch
        pg.fail("sqlite_heap_zig: out of memory", .{});
}

/// Every sqlite_heap_zig file in this database's directory. The returned slice
/// is `alloc`-owned and sorted by oid.
pub fn listFiles() []FileEntry {
    const d = dir();
    var list: std.ArrayList(FileEntry) = .empty;
    var ctx = ListCtx{ .list = &list, .dir_path = d };
    pg.shim_list_dir(d.ptr, listDirCallback, &ctx);
    const slice = list.toOwnedSlice(alloc) catch pg.fail("sqlite_heap_zig: out of memory", .{});
    std.mem.sort(FileEntry, slice, {}, struct {
        fn lt(_: void, a: FileEntry, b: FileEntry) bool {
            return a.oid < b.oid;
        }
    }.lt);
    return slice;
}
