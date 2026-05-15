//! Debug / inspection SQL functions -- the Zig port of the `pg_extern`s in
//! `lib.rs`. Each is a v1-calling-convention function taking a table OID;
//! call them from psql with `'mytable'::regclass`.

const std = @import("std");
const pg = @import("pg.zig");
const sqlite = @import("sqlite.zig");

const alloc = std.heap.c_allocator;

fn argOid(fcinfo: pg.FCInfo) u32 {
    return pg.shim_getarg_oid(fcinfo, 0);
}

/// On-disk path of the SQLite file backing `rel`.
export fn sqlite_heap_zig_file_path(fcinfo: pg.FCInfo) pg.Datum {
    const path = sqlite.filePath(argOid(fcinfo));
    defer alloc.free(path);
    return pg.shim_text_datum(path.ptr);
}

/// Size in bytes of the SQLite file backing `rel` (0 if not created yet).
export fn sqlite_heap_zig_file_size(fcinfo: pg.FCInfo) pg.Datum {
    const path = sqlite.filePath(argOid(fcinfo));
    defer alloc.free(path);
    return pg.shim_int64_datum(pg.shim_file_size(path.ptr));
}

/// The SQLite schema version (`PRAGMA user_version`) of `rel`'s file.
export fn sqlite_heap_zig_schema_version(fcinfo: pg.FCInfo) pg.Datum {
    return pg.shim_int32_datum(sqlite.schemaVersion(argOid(fcinfo)));
}

/// Number of rows physically present in the SQLite file for `rel`, including
/// dead (xmax-set) ones.
export fn sqlite_heap_zig_physical_rows(fcinfo: pg.FCInfo) pg.Datum {
    const rows = sqlite.selectAll(argOid(fcinfo));
    defer sqlite.freeRows(rows);
    return pg.shim_int64_datum(@intCast(rows.len));
}

/// Number of rows currently live (xmax = 0) in the SQLite file for `rel`.
export fn sqlite_heap_zig_live_rows(fcinfo: pg.FCInfo) pg.Datum {
    const rows = sqlite.selectAll(argOid(fcinfo));
    defer sqlite.freeRows(rows);
    var live: i64 = 0;
    for (rows) |row| {
        if (row.header.xmax == 0) live += 1;
    }
    return pg.shim_int64_datum(live);
}

/// Raw dump of the SQLite `storage` table for `rel` -- every physical row
/// version with the MVCC header columns PostgreSQL normally hides.
export fn sqlite_heap_zig_storage(fcinfo: pg.FCInfo) pg.Datum {
    var srf = pg.shim_srf_begin(fcinfo);
    const rows = sqlite.selectAll(argOid(fcinfo));
    defer sqlite.freeRows(rows);

    for (rows) |row| {
        const h = row.header;
        var values = [_]pg.Datum{
            pg.shim_int64_datum(h.rowid),
            pg.shim_int64_datum(@as(i64, h.xmin)),
            pg.shim_int64_datum(@as(i64, h.cmin)),
            pg.shim_int64_datum(@as(i64, h.xmax)),
            pg.shim_int64_datum(@as(i64, h.cmax)),
            pg.shim_int32_datum(@intCast(row.tuple.len)),
            pg.shim_bool_datum(h.xmax == 0),
        };
        var nulls = [_]bool{false} ** 7;
        pg.shim_srf_put(&srf, &values, &nulls);
    }
    return 0;
}

/// Every sqlite_heap_zig file in the current database's storage directory, as
/// `(table_oid, size_bytes)`.
export fn sqlite_heap_zig_files(fcinfo: pg.FCInfo) pg.Datum {
    var srf = pg.shim_srf_begin(fcinfo);
    const files = sqlite.listFiles();
    defer alloc.free(files);

    for (files) |entry| {
        var values = [_]pg.Datum{
            pg.shim_oid_datum(entry.oid),
            pg.shim_int64_datum(@bitCast(entry.bytes)),
        };
        var nulls = [_]bool{ false, false };
        pg.shim_srf_put(&srf, &values, &nulls);
    }
    return 0;
}

/// Called from the `sql_drop` event trigger to unlink the SQLite file that
/// backed a now-dropped table. Safe for any OID -- non-sqlite_heap tables
/// simply have no file at our path.
export fn sqlite_heap_zig_drop_storage(fcinfo: pg.FCInfo) pg.Datum {
    sqlite.dropRelation(argOid(fcinfo));
    return 0;
}
