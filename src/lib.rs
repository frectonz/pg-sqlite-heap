// TAM callbacks and `pg_extern`s have signatures dictated by Postgres.
#![allow(clippy::too_many_arguments)]

use pgrx::pg_sys;
use pgrx::prelude::*;

::pgrx::pg_module_magic!(name, version);

mod fxhash;
mod ffi;
mod sqlite;
mod tam;
mod visibility;

// --- Handler (PG v1 calling convention) ---

#[unsafe(no_mangle)]
#[doc(hidden)]
pub extern "C" fn pg_finfo_sqlite_heap_handler() -> &'static pg_sys::Pg_finfo_record {
    const V1: pg_sys::Pg_finfo_record = pg_sys::Pg_finfo_record { api_version: 1 };
    &V1
}

#[pg_guard]
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn sqlite_heap_handler(
    _fcinfo: pg_sys::FunctionCallInfo,
) -> pg_sys::Datum {
    pg_sys::Datum::from(tam::am_routine() as *const pg_sys::TableAmRoutine)
}

// ===========================================================================
// Debug / inspection
//
// These `pg_extern`s expose what sqlite_heap keeps on disk so you can poke at
// it from psql — handy for a demo. They take a table OID; call them with
// `'mytable'::regclass`, e.g. `SELECT * FROM sqlite_heap_storage('t'::regclass);`
// ===========================================================================

/// Number of rows physically present in the SQLite file for `rel`, including
/// dead (xmax-set) ones. Useful for verifying MVCC semantics.
#[pg_extern]
fn sqlite_heap_physical_rows(rel: pg_sys::Oid) -> i64 {
    sqlite::select_all(rel.to_u32()).len() as i64
}

/// Number of rows currently live (xmax = 0) in the SQLite file for `rel`.
#[pg_extern]
fn sqlite_heap_live_rows(rel: pg_sys::Oid) -> i64 {
    sqlite::select_all(rel.to_u32())
        .iter()
        .filter(|r| r.xmax == 0)
        .count() as i64
}

/// On-disk path of the SQLite file backing `rel`.
#[pg_extern]
fn sqlite_heap_file_path(rel: pg_sys::Oid) -> String {
    sqlite::file_path(rel.to_u32())
        .to_string_lossy()
        .into_owned()
}

/// Size in bytes of the SQLite file backing `rel` (0 if not created yet).
#[pg_extern]
fn sqlite_heap_file_size(rel: pg_sys::Oid) -> i64 {
    std::fs::metadata(sqlite::file_path(rel.to_u32()))
        .map(|m| m.len() as i64)
        .unwrap_or(0)
}

/// The SQLite schema version (`PRAGMA user_version`) of `rel`'s file.
#[pg_extern]
fn sqlite_heap_schema_version(rel: pg_sys::Oid) -> i32 {
    sqlite::schema_version(rel.to_u32())
}

/// Raw dump of the SQLite `storage` table for `rel` — every physical row
/// version with the MVCC header columns Postgres normally hides. `live` is
/// `xmax = 0` (no deleter stamped). `tuple_bytes` is the size of the opaque
/// Postgres tuple blob, not its contents.
#[pg_extern]
fn sqlite_heap_storage(
    rel: pg_sys::Oid,
) -> TableIterator<
    'static,
    (
        name!(rowid, i64),
        name!(xmin, i64),
        name!(cmin, i64),
        name!(xmax, i64),
        name!(cmax, i64),
        name!(tuple_bytes, i32),
        name!(live, bool),
    ),
> {
    let rows = sqlite::select_all(rel.to_u32());
    TableIterator::new(rows.into_iter().map(|r| {
        (
            r.rowid,
            r.xmin as i64,
            r.cmin as i64,
            r.xmax as i64,
            r.cmax as i64,
            r.tuple.len() as i32,
            r.xmax == 0,
        )
    }))
}

/// Every sqlite_heap file in the current database's storage directory, as
/// `(table_oid, size_bytes)`. Join `table_oid` to `pg_class.oid` for names.
#[pg_extern]
fn sqlite_heap_files() -> TableIterator<
    'static,
    (name!(table_oid, pg_sys::Oid), name!(size_bytes, i64)),
> {
    TableIterator::new(
        sqlite::list_files()
            .into_iter()
            .map(|(oid, bytes)| (pg_sys::Oid::from_u32(oid), bytes as i64)),
    )
}

/// Called from a `sql_drop` event trigger to unlink the SQLite file that
/// backed a now-dropped table. Safe to call for any OID — non-sqlite_heap
/// tables simply have no file at our path.
#[pg_extern]
fn sqlite_heap_drop_storage(rel: pg_sys::Oid) {
    sqlite::drop_relation(rel.to_u32());
}

// ===========================================================================
// SQL: CREATE FUNCTION + CREATE ACCESS METHOD
// ===========================================================================

extension_sql!(
    r#"
CREATE FUNCTION sqlite_heap_handler(internal)
    RETURNS table_am_handler
    LANGUAGE c
    AS 'MODULE_PATHNAME', 'sqlite_heap_handler';

CREATE ACCESS METHOD sqlite_heap TYPE TABLE HANDLER sqlite_heap_handler;
"#,
    name = "sqlite_heap_access_method",
);

extension_sql!(
    r#"
CREATE OR REPLACE FUNCTION sqlite_heap_drop_handler()
    RETURNS event_trigger
    LANGUAGE plpgsql
AS $$
DECLARE
    obj record;
BEGIN
    FOR obj IN
        SELECT objid FROM pg_event_trigger_dropped_objects()
        WHERE object_type = 'table'
    LOOP
        PERFORM sqlite_heap_drop_storage(obj.objid);
    END LOOP;
END;
$$;

CREATE EVENT TRIGGER sqlite_heap_on_drop
    ON sql_drop
    EXECUTE FUNCTION sqlite_heap_drop_handler();
"#,
    name = "sqlite_heap_drop_trigger",
    requires = [sqlite_heap_drop_storage],
);

// ===========================================================================
// pg_test
// ===========================================================================

// `#[pg_schema]` is a proc macro and can't take a file-module declaration
// (`mod tests;`), so the test code lives in `tests.rs` and is `include!`d
// into an inline module here.
#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    include!("tests.rs");
}

#[cfg(test)]
pub mod pg_test {
    pub fn setup(_options: Vec<&str>) {}
    #[must_use]
    pub fn postgresql_conf_options() -> Vec<&'static str> {
        vec![]
    }
}
