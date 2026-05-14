# sqlite_heap

A Postgres extension that stores table data in **SQLite files** instead of
Postgres's built-in heap — while the table still behaves like any other
Postgres table: transactions, MVCC, indexes, joins, `VACUUM`, `ANALYZE`, and
the planner all work.

It's a [Table Access Method](https://www.postgresql.org/docs/current/tableam.html)
written in Rust with [pgrx](https://github.com/pgcentralfoundation/pgrx). Each
table gets its own file at `$PGDATA/sqlite_heap/<db-oid>/<table-oid>.sqlite`.

Supports Postgres **17** and **18**.

## Usage

```sql
CREATE EXTENSION pg_sqlite_heap;

CREATE TABLE t (id int primary key, label text) USING sqlite_heap;
INSERT INTO t VALUES (1, 'a'), (2, 'b');
SELECT * FROM t;          -- ordinary Postgres table from here on
```

## Inspecting the files

The extension exposes SQL functions for poking at what's on disk. Pass a table
name with `::regclass`:

| Function | Returns |
|---|---|
| `sqlite_heap_file_path(regclass)` | path of the table's SQLite file |
| `sqlite_heap_file_size(regclass)` | its size in bytes |
| `sqlite_heap_schema_version(regclass)` | the SQLite `PRAGMA user_version` |
| `sqlite_heap_storage(regclass)` | raw row dump, including the MVCC header columns Postgres hides |
| `sqlite_heap_files()` | every sqlite_heap file in the current database |
| `sqlite_heap_physical_rows(regclass)` | row count including dead versions |
| `sqlite_heap_live_rows(regclass)` | live (`xmax = 0`) row count |

```sql
SELECT * FROM sqlite_heap_storage('t'::regclass);
```

## Tests

```sh
cargo pgrx test                  # 51 in-process tests
./tests/concurrency.sh           # multi-backend stress test (needs a running cluster)
```

## Project layout

| File | What |
|---|---|
| `src/tam.rs` | the `TableAmRoutine` callbacks |
| `src/sqlite.rs` | per-table SQLite backend, lazy transactions, schema migration, durability |
| `src/visibility.rs` | snapshot visibility rules over the stored xmin/xmax |
| `src/ffi.rs` | HeapTuple / slot / TID marshalling |
| `src/lib.rs` | the handler, drop trigger, and inspection functions |
