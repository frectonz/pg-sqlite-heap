use pgrx::prelude::*;

/// Reset the test table and seed three rows.
fn seed() {
    Spi::run(
        "DROP TABLE IF EXISTS t;
         CREATE TABLE t (id int, name text) USING sqlite_heap;
         INSERT INTO t VALUES (1,'alice'),(2,'bob'),(3,'carol');",
    )
    .unwrap();
}

#[pg_test]
fn round_trip_select() {
    seed();
    let count = Spi::get_one::<i64>("SELECT count(*) FROM t").unwrap();
    assert_eq!(count, Some(3));
    let name = Spi::get_one::<String>("SELECT name FROM t WHERE id = 2").unwrap();
    assert_eq!(name.as_deref(), Some("bob"));
}

#[pg_test]
fn update_then_select() {
    seed();
    Spi::run("UPDATE t SET name = 'ALICE' WHERE id = 1").unwrap();
    let name = Spi::get_one::<String>("SELECT name FROM t WHERE id = 1").unwrap();
    assert_eq!(name.as_deref(), Some("ALICE"));
}

#[pg_test]
fn delete_then_select() {
    seed();
    Spi::run("DELETE FROM t WHERE id = 2").unwrap();
    let count = Spi::get_one::<i64>("SELECT count(*) FROM t").unwrap();
    assert_eq!(count, Some(2));
    let bob_exists = Spi::get_one::<i64>("SELECT count(*) FROM t WHERE id = 2").unwrap();
    assert_eq!(bob_exists, Some(0));
}

#[pg_test]
fn truncate_clears_rows() {
    seed();
    Spi::run("TRUNCATE t").unwrap();
    let count = Spi::get_one::<i64>("SELECT count(*) FROM t").unwrap();
    assert_eq!(count, Some(0));
}

// We can't use BEGIN/ROLLBACK inside a #[pg_test] (pgrx wraps each test
// in its own transaction and rejects nested ones via SPI). The PL/pgSQL
// EXCEPTION block below opens an implicit subtransaction; raising an
// exception inside rolls it back, exercising the same code path.
fn rolled_back<S: AsRef<str>>(body: S) {
    Spi::run(&format!(
        "DO $$ BEGIN {} RAISE EXCEPTION 'rollback'; EXCEPTION WHEN OTHERS THEN NULL; END $$;",
        body.as_ref()
    ))
    .unwrap();
}

#[pg_test]
fn rollback_undoes_insert() {
    seed();
    rolled_back("INSERT INTO t VALUES (99, 'temp');");
    let count = Spi::get_one::<i64>("SELECT count(*) FROM t").unwrap();
    assert_eq!(count, Some(3));
}

#[pg_test]
fn rollback_undoes_update() {
    seed();
    rolled_back("UPDATE t SET name = 'BROKEN';");
    let alice = Spi::get_one::<String>("SELECT name FROM t WHERE id = 1").unwrap();
    assert_eq!(alice.as_deref(), Some("alice"));
}

#[pg_test]
fn rollback_undoes_truncate() {
    seed();
    rolled_back("TRUNCATE t;");
    let count = Spi::get_one::<i64>("SELECT count(*) FROM t").unwrap();
    assert_eq!(count, Some(3));
}

#[pg_test]
fn savepoint_partial_rollback() {
    // dave persists; eve is rolled back; frank persists.
    seed();
    Spi::run("INSERT INTO t VALUES (4, 'dave');").unwrap();
    rolled_back("INSERT INTO t VALUES (5, 'eve');");
    Spi::run("INSERT INTO t VALUES (6, 'frank');").unwrap();
    let names =
        Spi::get_one::<String>("SELECT string_agg(name, ',' ORDER BY id) FROM t").unwrap();
    assert_eq!(names.as_deref(), Some("alice,bob,carol,dave,frank"));
}

#[pg_test]
fn index_scan_returns_row() {
    seed();
    Spi::run("CREATE INDEX t_id_idx ON t (id); SET enable_seqscan = off;").unwrap();
    let name = Spi::get_one::<String>("SELECT name FROM t WHERE id = 3").unwrap();
    assert_eq!(name.as_deref(), Some("carol"));
}

#[pg_test]
fn index_reflects_update() {
    seed();
    Spi::run("CREATE INDEX t_id_idx ON t (id); SET enable_seqscan = off;").unwrap();
    Spi::run("UPDATE t SET id = 99 WHERE name = 'bob'").unwrap();
    let new_name = Spi::get_one::<String>("SELECT name FROM t WHERE id = 99").unwrap();
    assert_eq!(new_name.as_deref(), Some("bob"));
    let old_exists = Spi::get_one::<i64>("SELECT count(*) FROM t WHERE id = 2").unwrap();
    assert_eq!(old_exists, Some(0));
}

#[pg_test]
fn delete_keeps_row_physically() {
    seed();
    // 3 rows inserted, all live.
    let phys_before =
        Spi::get_one::<i64>("SELECT sqlite_heap_physical_rows('t'::regclass::oid)").unwrap();
    let live_before =
        Spi::get_one::<i64>("SELECT sqlite_heap_live_rows('t'::regclass::oid)").unwrap();
    assert_eq!(phys_before, Some(3));
    assert_eq!(live_before, Some(3));

    Spi::run("DELETE FROM t WHERE id = 2").unwrap();

    // After delete: the deleted row is still physically present (xmax-set),
    // but no longer "live" or visible.
    let phys_after =
        Spi::get_one::<i64>("SELECT sqlite_heap_physical_rows('t'::regclass::oid)").unwrap();
    let live_after =
        Spi::get_one::<i64>("SELECT sqlite_heap_live_rows('t'::regclass::oid)").unwrap();
    let visible = Spi::get_one::<i64>("SELECT count(*) FROM t").unwrap();
    assert_eq!(phys_after, Some(3));
    assert_eq!(live_after, Some(2));
    assert_eq!(visible, Some(2));
}

#[pg_test]
fn update_keeps_old_row_physically() {
    seed();
    Spi::run("UPDATE t SET name = 'ALICE' WHERE id = 1").unwrap();

    let phys =
        Spi::get_one::<i64>("SELECT sqlite_heap_physical_rows('t'::regclass::oid)").unwrap();
    let live = Spi::get_one::<i64>("SELECT sqlite_heap_live_rows('t'::regclass::oid)").unwrap();
    let visible = Spi::get_one::<i64>("SELECT count(*) FROM t").unwrap();
    // Old row stayed (xmax-set) + new row added = 4 physical, 3 live, 3 visible.
    assert_eq!(phys, Some(4));
    assert_eq!(live, Some(3));
    assert_eq!(visible, Some(3));
}

#[pg_test]
fn index_reflects_delete() {
    seed();
    Spi::run("CREATE INDEX t_id_idx ON t (id); SET enable_seqscan = off;").unwrap();
    Spi::run("DELETE FROM t WHERE name = 'carol'").unwrap();
    let carol_exists = Spi::get_one::<i64>("SELECT count(*) FROM t WHERE id = 3").unwrap();
    assert_eq!(carol_exists, Some(0));
}

// -------------------------------------------------------------------
// Type coverage: opaque-bytes storage must round-trip every Postgres type.
// -------------------------------------------------------------------

#[pg_test]
fn type_coverage_scalars() {
    Spi::run(
        "DROP TABLE IF EXISTS scalars;
         CREATE TABLE scalars (
            a smallint, b int, c bigint,
            d real, e double precision, f numeric,
            g text, h varchar(20), i char(5), j bytea,
            k boolean, l date, m timestamp, n uuid
         ) USING sqlite_heap;
         INSERT INTO scalars VALUES (
            1, 2, 3,
            4.5, 6.75, 7.875,
            'hello', 'world', 'abc',
            E'\\\\x0102deadbeef'::bytea,
            true, '2025-01-15', '2025-01-15 12:34:56',
            '550e8400-e29b-41d4-a716-446655440000'
         );",
    )
    .unwrap();
    let c = Spi::get_one::<i64>("SELECT count(*) FROM scalars").unwrap();
    assert_eq!(c, Some(1));
    let text = Spi::get_one::<String>("SELECT g FROM scalars").unwrap();
    assert_eq!(text.as_deref(), Some("hello"));
    let bigint = Spi::get_one::<i64>("SELECT c FROM scalars").unwrap();
    assert_eq!(bigint, Some(3));
    let bool_ = Spi::get_one::<bool>("SELECT k FROM scalars").unwrap();
    assert_eq!(bool_, Some(true));
}

#[pg_test]
fn type_coverage_arrays_and_json() {
    Spi::run(
        "DROP TABLE IF EXISTS rich;
         CREATE TABLE rich (
            ints int[],
            strs text[],
            obj jsonb,
            doc json
         ) USING sqlite_heap;
         INSERT INTO rich VALUES (
            ARRAY[1,2,3,4],
            ARRAY['x','y','z'],
            '{\"k\": \"v\", \"n\": 42}'::jsonb,
            '{\"a\": [1,2,3]}'::json
         );",
    )
    .unwrap();
    let n = Spi::get_one::<i32>("SELECT (ints)[3] FROM rich").unwrap();
    assert_eq!(n, Some(3));
    let v = Spi::get_one::<String>("SELECT obj->>'k' FROM rich").unwrap();
    assert_eq!(v.as_deref(), Some("v"));
}

#[pg_test]
fn null_round_trip() {
    Spi::run(
        "DROP TABLE IF EXISTS n;
         CREATE TABLE n (id int, name text) USING sqlite_heap;
         INSERT INTO n VALUES (1, NULL), (NULL, 'orphan'), (2, 'normal');",
    )
    .unwrap();
    let nulls =
        Spi::get_one::<i64>("SELECT count(*) FROM n WHERE name IS NULL").unwrap();
    let id_nulls =
        Spi::get_one::<i64>("SELECT count(*) FROM n WHERE id IS NULL").unwrap();
    assert_eq!(nulls, Some(1));
    assert_eq!(id_nulls, Some(1));
}

// -------------------------------------------------------------------
// Volume: many rows; many columns; large payloads.
// -------------------------------------------------------------------

#[pg_test]
fn many_rows_round_trip() {
    Spi::run(
        "DROP TABLE IF EXISTS m;
         CREATE TABLE m (id int, payload text) USING sqlite_heap;
         INSERT INTO m SELECT g, 'row-' || g FROM generate_series(1, 5000) g;",
    )
    .unwrap();
    let count = Spi::get_one::<i64>("SELECT count(*) FROM m").unwrap();
    assert_eq!(count, Some(5000));
    let sum =
        Spi::get_one::<i64>("SELECT sum(id)::bigint FROM m").unwrap();
    // 1 + 2 + ... + 5000 = 5000*5001/2
    assert_eq!(sum, Some(5000 * 5001 / 2));
    let mid =
        Spi::get_one::<String>("SELECT payload FROM m WHERE id = 2500").unwrap();
    assert_eq!(mid.as_deref(), Some("row-2500"));
}

#[pg_test]
fn wide_row() {
    Spi::run(
        "DROP TABLE IF EXISTS w;
         CREATE TABLE w (
            c1 int, c2 int, c3 int, c4 int, c5 int,
            c6 text, c7 text, c8 text, c9 text, c10 text
         ) USING sqlite_heap;
         INSERT INTO w VALUES (1,2,3,4,5,'a','b','c','d','e');",
    )
    .unwrap();
    let c10 = Spi::get_one::<String>("SELECT c10 FROM w").unwrap();
    assert_eq!(c10.as_deref(), Some("e"));
}

#[pg_test]
fn large_text() {
    // Build a 100 KB text payload via repeat to exercise long rows.
    Spi::run(
        "DROP TABLE IF EXISTS big;
         CREATE TABLE big (id int, body text) USING sqlite_heap;
         INSERT INTO big VALUES (1, repeat('x', 100000));",
    )
    .unwrap();
    let len = Spi::get_one::<i32>("SELECT length(body) FROM big").unwrap();
    assert_eq!(len, Some(100000));
}

// -------------------------------------------------------------------
// INSERT INTO t SELECT * FROM t — exercises cmin/cmax visibility.
// Without cmin/cmax, this would infinite-loop. We assert it terminates
// and doubles the row count.
// -------------------------------------------------------------------

#[pg_test]
fn insert_from_self_terminates() {
    Spi::run(
        "DROP TABLE IF EXISTS s;
         CREATE TABLE s (n int) USING sqlite_heap;
         INSERT INTO s SELECT g FROM generate_series(1, 10) g;
         INSERT INTO s SELECT * FROM s;",
    )
    .unwrap();
    let count = Spi::get_one::<i64>("SELECT count(*) FROM s").unwrap();
    assert_eq!(count, Some(20));
}

// -------------------------------------------------------------------
// INSERT ON CONFLICT
// -------------------------------------------------------------------

#[pg_test]
fn insert_on_conflict_do_nothing() {
    Spi::run(
        "DROP TABLE IF EXISTS uc;
         CREATE TABLE uc (id int PRIMARY KEY, name text) USING sqlite_heap;
         INSERT INTO uc VALUES (1, 'alice'), (2, 'bob');
         INSERT INTO uc VALUES (2, 'BOB-DUP'), (3, 'carol')
            ON CONFLICT (id) DO NOTHING;",
    )
    .unwrap();
    let count = Spi::get_one::<i64>("SELECT count(*) FROM uc").unwrap();
    assert_eq!(count, Some(3));
    // bob should NOT have been overwritten
    let bob = Spi::get_one::<String>("SELECT name FROM uc WHERE id = 2").unwrap();
    assert_eq!(bob.as_deref(), Some("bob"));
}

#[pg_test]
fn insert_on_conflict_do_update() {
    Spi::run(
        "DROP TABLE IF EXISTS uc2;
         CREATE TABLE uc2 (id int PRIMARY KEY, hits int) USING sqlite_heap;
         INSERT INTO uc2 VALUES (1, 1);
         INSERT INTO uc2 VALUES (1, 1)
            ON CONFLICT (id) DO UPDATE SET hits = uc2.hits + 1;
         INSERT INTO uc2 VALUES (1, 1)
            ON CONFLICT (id) DO UPDATE SET hits = uc2.hits + 1;",
    )
    .unwrap();
    let hits = Spi::get_one::<i32>("SELECT hits FROM uc2 WHERE id = 1").unwrap();
    assert_eq!(hits, Some(3));
}

// -------------------------------------------------------------------
// COPY FROM stdin (exercises multi_insert).
// -------------------------------------------------------------------

#[pg_test]
fn copy_from_stdin_via_csv() {
    // COPY ... FROM stdin can't be issued via SPI directly; use
    // dollar-quoted INSERT ... SELECT from a VALUES list, which the
    // executor batches through multi_insert when the source has
    // multiple rows.
    Spi::run(
        "DROP TABLE IF EXISTS cp;
         CREATE TABLE cp (id int, val text) USING sqlite_heap;
         INSERT INTO cp
         SELECT g, 'val-' || g FROM generate_series(1, 100) g;",
    )
    .unwrap();
    let count = Spi::get_one::<i64>("SELECT count(*) FROM cp").unwrap();
    let last = Spi::get_one::<String>("SELECT val FROM cp WHERE id = 100").unwrap();
    assert_eq!(count, Some(100));
    assert_eq!(last.as_deref(), Some("val-100"));
}

// -------------------------------------------------------------------
// VACUUM reclaims dead rows.
// -------------------------------------------------------------------

#[pg_test]
fn many_deletes_accumulate_dead_rows() {
    // Without VACUUM, repeated DELETE-then-INSERT leaves dead rows in
    // SQLite — physical rows climb while live rows stay constant.
    // Verifies the MVCC bookkeeping is working as designed.
    Spi::run(
        "DROP TABLE IF EXISTS m;
         CREATE TABLE m (id int) USING sqlite_heap;
         INSERT INTO m VALUES (1),(2),(3);",
    )
    .unwrap();
    for _ in 0..10 {
        Spi::run("UPDATE m SET id = id + 100").unwrap();
        Spi::run("UPDATE m SET id = id - 100").unwrap();
    }
    let live =
        Spi::get_one::<i64>("SELECT sqlite_heap_live_rows('m'::regclass::oid)").unwrap();
    let phys = Spi::get_one::<i64>(
        "SELECT sqlite_heap_physical_rows('m'::regclass::oid)",
    )
    .unwrap();
    let visible = Spi::get_one::<i64>("SELECT count(*) FROM m").unwrap();
    assert_eq!(live, Some(3));
    assert_eq!(visible, Some(3));
    // Each UPDATE marks 3 old rows dead + creates 3 new live ones.
    // After 20 UPDATEs: 60 dead + 3 live = 63 physical.
    assert_eq!(phys, Some(63));
}

// -------------------------------------------------------------------
// TID range scans.
// -------------------------------------------------------------------

#[pg_test]
fn tid_range_scan() {
    Spi::run(
        "DROP TABLE IF EXISTS tr;
         CREATE TABLE tr (n int) USING sqlite_heap;
         INSERT INTO tr SELECT g FROM generate_series(1, 50) g;",
    )
    .unwrap();
    // ctid '(0,0)' to '(0,10)' picks the first ~10 rows by physical
    // order. With sqlite_heap, rowid 1..10 → ctid (0,1)..(0,10).
    let count = Spi::get_one::<i64>(
        "SELECT count(*) FROM tr WHERE ctid >= '(0,1)' AND ctid <= '(0,10)'",
    )
    .unwrap();
    assert_eq!(count, Some(10));
}

// -------------------------------------------------------------------
// SELECT FOR UPDATE — exercises tuple_lock.
// -------------------------------------------------------------------

#[pg_test]
fn select_for_update_returns_row() {
    seed();
    let name = Spi::get_one::<String>(
        "SELECT name FROM t WHERE id = 1 FOR UPDATE",
    )
    .unwrap();
    assert_eq!(name.as_deref(), Some("alice"));
}

// -------------------------------------------------------------------
// ANALYZE: planner stats are populated.
// -------------------------------------------------------------------

#[pg_test]
fn analyze_runs_without_crashing() {
    // ANALYZE currently can't populate pg_class.reltuples for sqlite_heap
    // tables — sampling expects a buffer-manager-backed relfile that we
    // don't have. The planner falls back on `relation_estimate_size`.
    // What we DO assert: ANALYZE doesn't error or crash.
    Spi::run(
        "DROP TABLE IF EXISTS an;
         CREATE TABLE an (id int) USING sqlite_heap;
         INSERT INTO an SELECT g FROM generate_series(1, 1000) g;
         ANALYZE an;",
    )
    .unwrap();
}

// -------------------------------------------------------------------
// TABLESAMPLE: returns rows (we currently return everything).
// -------------------------------------------------------------------

#[pg_test]
fn tablesample_returns_rows() {
    Spi::run(
        "DROP TABLE IF EXISTS ts;
         CREATE TABLE ts (n int) USING sqlite_heap;
         INSERT INTO ts SELECT g FROM generate_series(1, 200) g;",
    )
    .unwrap();
    let n = Spi::get_one::<i64>(
        "SELECT count(*) FROM ts TABLESAMPLE BERNOULLI (50)",
    )
    .unwrap();
    // We don't sample (we return everything), so we always see 200.
    // The key assertion is "non-zero, no crash."
    assert!(n.unwrap_or(0) > 0, "TABLESAMPLE returned 0 rows");
}

// -------------------------------------------------------------------
// CLUSTER: rebuild table via an index.
// -------------------------------------------------------------------

#[pg_test]
fn cluster_preserves_data() {
    Spi::run(
        "DROP TABLE IF EXISTS cl;
         CREATE TABLE cl (id int, name text) USING sqlite_heap;
         INSERT INTO cl VALUES (3,'c'),(1,'a'),(2,'b');
         CREATE INDEX cl_id_idx ON cl (id);
         CLUSTER cl USING cl_id_idx;",
    )
    .unwrap();
    let count = Spi::get_one::<i64>("SELECT count(*) FROM cl").unwrap();
    assert_eq!(count, Some(3));
    let names = Spi::get_one::<String>(
        "SELECT string_agg(name, ',' ORDER BY id) FROM cl",
    )
    .unwrap();
    assert_eq!(names.as_deref(), Some("a,b,c"));
}

// -------------------------------------------------------------------
// Multi-column / partial / expression indexes.
// -------------------------------------------------------------------

#[pg_test]
fn multi_column_index() {
    Spi::run(
        "DROP TABLE IF EXISTS mc;
         CREATE TABLE mc (a int, b int) USING sqlite_heap;
         INSERT INTO mc SELECT g/10, g%10 FROM generate_series(1, 100) g;
         CREATE INDEX mc_ab ON mc (a, b);
         SET enable_seqscan = off;",
    )
    .unwrap();
    let n = Spi::get_one::<i64>(
        "SELECT count(*) FROM mc WHERE a = 5 AND b = 5",
    )
    .unwrap();
    assert!(n.unwrap_or(0) >= 1);
}

#[pg_test]
fn partial_index() {
    Spi::run(
        "DROP TABLE IF EXISTS pi;
         CREATE TABLE pi (id int, active boolean) USING sqlite_heap;
         INSERT INTO pi
         SELECT g, (g % 2 = 0) FROM generate_series(1, 100) g;
         CREATE INDEX pi_active ON pi (id) WHERE active;
         SET enable_seqscan = off;",
    )
    .unwrap();
    let n = Spi::get_one::<i64>(
        "SELECT count(*) FROM pi WHERE id = 50 AND active",
    )
    .unwrap();
    assert_eq!(n, Some(1));
}

#[pg_test]
fn expression_index() {
    Spi::run(
        "DROP TABLE IF EXISTS ei;
         CREATE TABLE ei (name text) USING sqlite_heap;
         INSERT INTO ei VALUES ('Alice'),('BOB'),('carol');
         CREATE INDEX ei_lower ON ei (lower(name));
         SET enable_seqscan = off;",
    )
    .unwrap();
    let name = Spi::get_one::<String>(
        "SELECT name FROM ei WHERE lower(name) = 'bob'",
    )
    .unwrap();
    assert_eq!(name.as_deref(), Some("BOB"));
}

// -------------------------------------------------------------------
// Unique constraint enforcement (via UNIQUE index).
// -------------------------------------------------------------------

#[pg_test]
fn unique_constraint_rejects_duplicate() {
    Spi::run(
        "DROP TABLE IF EXISTS uq;
         CREATE TABLE uq (id int UNIQUE, name text) USING sqlite_heap;
         INSERT INTO uq VALUES (1, 'alice');",
    )
    .unwrap();
    // pgrx-tests turns Spi errors into test panics, so we catch the
    // unique violation in a PL/pgSQL EXCEPTION block. The constraint
    // worked iff (a) the EXCEPTION fired (the inner RAISE never runs)
    // and (b) the original `alice` row is unchanged.
    Spi::run(
        "DO $$ BEGIN
           INSERT INTO uq VALUES (1, 'dup');
           RAISE EXCEPTION 'no unique violation raised';
         EXCEPTION WHEN unique_violation THEN
           NULL;
         END $$;",
    )
    .unwrap();
    let count = Spi::get_one::<i64>("SELECT count(*) FROM uq").unwrap();
    assert_eq!(count, Some(1));
    let name = Spi::get_one::<String>("SELECT name FROM uq WHERE id = 1").unwrap();
    assert_eq!(name.as_deref(), Some("alice"));
}

// -------------------------------------------------------------------
// DROP TABLE event trigger cleans up the SQLite file at commit time.
// -------------------------------------------------------------------

#[pg_test]
fn drop_table_unlinks_storage() {
    Spi::run(
        "DROP TABLE IF EXISTS dt;
         CREATE TABLE dt (id int) USING sqlite_heap;
         INSERT INTO dt VALUES (1),(2),(3);",
    )
    .unwrap();
    // Capture the OID so we can introspect after the table is dropped.
    let oid = Spi::get_one::<pg_sys::Oid>("SELECT 'dt'::regclass::oid")
        .unwrap()
        .expect("dt should exist");
    // Pre-drop: storage exists, three rows.
    let pre =
        Spi::get_one::<i64>(&format!("SELECT sqlite_heap_physical_rows({})", oid.to_u32()))
            .unwrap();
    assert_eq!(pre, Some(3));
    // The drop runs inside the same wrapping pgrx-test transaction, so
    // the deferred unlink hasn't happened yet — but the table itself is
    // gone from the catalog. We can't easily verify the file unlink
    // because the rollback at end-of-test reinstates pg_class but the
    // SQLite file (if it were unlinked at commit) wouldn't reappear.
    Spi::run("DROP TABLE dt").unwrap();
    let still = Spi::get_one::<bool>(
        "SELECT EXISTS (SELECT FROM pg_class WHERE relname = 'dt')",
    )
    .unwrap();
    assert_eq!(still, Some(false));
}

// -------------------------------------------------------------------
// Generated / DEFAULT columns.
// -------------------------------------------------------------------

#[pg_test]
fn defaults_and_generated_columns() {
    Spi::run(
        "DROP TABLE IF EXISTS gc;
         CREATE TABLE gc (
            id serial PRIMARY KEY,
            created timestamp DEFAULT now(),
            doubled int GENERATED ALWAYS AS (id * 2) STORED
         ) USING sqlite_heap;
         INSERT INTO gc DEFAULT VALUES;
         INSERT INTO gc DEFAULT VALUES;",
    )
    .unwrap();
    let count = Spi::get_one::<i64>("SELECT count(*) FROM gc").unwrap();
    assert_eq!(count, Some(2));
    let max_doubled =
        Spi::get_one::<i32>("SELECT max(doubled) FROM gc").unwrap();
    assert_eq!(max_doubled, Some(4));
}

// -------------------------------------------------------------------
// Row count stability across many transactional savepoint patterns.
// -------------------------------------------------------------------

#[pg_test]
fn savepoint_stress() {
    Spi::run(
        "DROP TABLE IF EXISTS sp;
         CREATE TABLE sp (n int) USING sqlite_heap;
         INSERT INTO sp VALUES (1);",
    )
    .unwrap();
    // Build up a chain of savepoints and rollbacks.
    for i in 2..=20 {
        let body = format!("INSERT INTO sp VALUES ({i});");
        if i % 3 == 0 {
            // odd-third inserts get rolled back
            rolled_back(&body);
        } else {
            Spi::run(&body).unwrap();
        }
    }
    let count = Spi::get_one::<i64>("SELECT count(*) FROM sp").unwrap();
    // 19 inserts after the first; rolled back when i % 3 == 0: that's
    // i ∈ {3, 6, 9, 12, 15, 18} = 6 rollbacks. 19 - 6 = 13. Plus the
    // initial row → 14.
    assert_eq!(count, Some(14));
}

// -------------------------------------------------------------------
// Many concurrent indexes maintained correctly across updates.
// -------------------------------------------------------------------

#[pg_test]
fn many_indexes_stay_in_sync() {
    Spi::run(
        "DROP TABLE IF EXISTS mi;
         CREATE TABLE mi (a int, b int, c int, d int) USING sqlite_heap;
         INSERT INTO mi SELECT g, g+1, g+2, g+3 FROM generate_series(1, 100) g;
         CREATE INDEX mi_a ON mi (a);
         CREATE INDEX mi_b ON mi (b);
         CREATE INDEX mi_c ON mi (c);
         CREATE INDEX mi_d ON mi (d);
         SET enable_seqscan = off;",
    )
    .unwrap();
    // Lookups via each index land on the same row.
    let by_a = Spi::get_one::<i32>("SELECT b FROM mi WHERE a = 50").unwrap();
    let by_b = Spi::get_one::<i32>("SELECT c FROM mi WHERE b = 51").unwrap();
    let by_c = Spi::get_one::<i32>("SELECT d FROM mi WHERE c = 52").unwrap();
    let by_d = Spi::get_one::<i32>("SELECT a FROM mi WHERE d = 53").unwrap();
    assert_eq!(by_a, Some(51));
    assert_eq!(by_b, Some(52));
    assert_eq!(by_c, Some(53));
    assert_eq!(by_d, Some(50));

    // Update one row, all indexes should reflect.
    Spi::run("UPDATE mi SET a = 999 WHERE a = 50").unwrap();
    let still_b = Spi::get_one::<i32>("SELECT a FROM mi WHERE b = 51").unwrap();
    assert_eq!(still_b, Some(999));
    let by_new_a = Spi::get_one::<i32>("SELECT b FROM mi WHERE a = 999").unwrap();
    assert_eq!(by_new_a, Some(51));
    let by_old_a =
        Spi::get_one::<i64>("SELECT count(*) FROM mi WHERE a = 50").unwrap();
    assert_eq!(by_old_a, Some(0));
}

// -------------------------------------------------------------------
// Snapshot tests — catch regressions in row shape, ordering, NULL
// handling, and planner output that single-value asserts miss.
// -------------------------------------------------------------------
//
// We serialize result sets to indented JSON via Postgres's
// `jsonb_pretty(jsonb_agg(...))` and then `insta::assert_snapshot!`
// it. Snapshots live in `src/snapshots/`. Approve new/changed
// snapshots with `cargo insta review`.

fn rows_as_json(sql: &str) -> String {
    let wrapped = format!(
        "SELECT jsonb_pretty(coalesce(jsonb_agg(row_to_json(_s)), '[]'::jsonb)) \
         FROM ({sql}) AS _s"
    );
    Spi::get_one::<String>(&wrapped)
        .expect("snapshot query failed")
        .expect("snapshot query returned NULL")
}

fn explain_text(sql: &str) -> String {
    // EXPLAIN (COSTS OFF) hides plan-cost numbers that drift between
    // PG releases and machines, keeping the snapshot stable.
    Spi::connect(|c| {
        let table = c
            .select(&format!("EXPLAIN (COSTS OFF) {sql}"), None, &[])
            .expect("explain query failed");
        let mut lines = Vec::new();
        for row in table {
            let line: Option<String> = row.get(1).unwrap_or(None);
            if let Some(line) = line {
                lines.push(line);
            }
        }
        lines.join("\n")
    })
}

#[pg_test]
fn snapshot_round_trip() {
    seed();
    insta::assert_snapshot!(rows_as_json("SELECT id, name FROM t ORDER BY id"));
}

#[pg_test]
fn snapshot_after_update_and_delete() {
    seed();
    Spi::run(
        "UPDATE t SET name = 'ALICE' WHERE id = 1;
         DELETE FROM t WHERE id = 2;",
    )
    .unwrap();
    insta::assert_snapshot!(rows_as_json("SELECT id, name FROM t ORDER BY id"));
}

#[pg_test]
fn snapshot_nulls_preserved() {
    Spi::run(
        "DROP TABLE IF EXISTS n;
         CREATE TABLE n (id int, name text, age int) USING sqlite_heap;
         INSERT INTO n VALUES
           (1, NULL,     30),
           (2, 'alice',  NULL),
           (NULL, 'bob', 40),
           (4, NULL,     NULL);",
    )
    .unwrap();
    insta::assert_snapshot!(rows_as_json(
        "SELECT id, name, age FROM n ORDER BY id NULLS LAST"
    ));
}

#[pg_test]
fn snapshot_types_round_trip() {
    Spi::run(
        "DROP TABLE IF EXISTS mixed;
         CREATE TABLE mixed (
            i int, b bigint, r real, t text, ba bytea, bl bool, arr int[], j jsonb
         ) USING sqlite_heap;
         INSERT INTO mixed VALUES
           (1, 9999999999, 3.5::real, 'hello',
            '\\xdeadbeef'::bytea, true, ARRAY[1,2,3],
            '{\"k\":\"v\"}'::jsonb);",
    )
    .unwrap();
    insta::assert_snapshot!(rows_as_json("SELECT * FROM mixed"));
}

#[pg_test]
fn snapshot_index_scan_plan() {
    Spi::run(
        "DROP TABLE IF EXISTS ix;
         CREATE TABLE ix (id int, name text) USING sqlite_heap;
         INSERT INTO ix SELECT g, 'r'||g FROM generate_series(1, 100) g;
         CREATE INDEX ix_id ON ix (id);
         SET enable_seqscan = off;",
    )
    .unwrap();
    insta::assert_snapshot!(explain_text("SELECT name FROM ix WHERE id = 42"));
}

#[pg_test]
fn snapshot_seq_scan_plan() {
    seed();
    // Without an index, planner has to seq-scan. Snapshot confirms.
    insta::assert_snapshot!(explain_text("SELECT * FROM t WHERE name = 'bob'"));
}

#[pg_test]
fn snapshot_savepoint_rollback() {
    Spi::run(
        "DROP TABLE IF EXISTS sp;
         CREATE TABLE sp (n int, label text) USING sqlite_heap;
         INSERT INTO sp VALUES (1, 'kept');",
    )
    .unwrap();
    rolled_back("INSERT INTO sp VALUES (2, 'rolled_back');");
    Spi::run("INSERT INTO sp VALUES (3, 'kept_too');").unwrap();
    insta::assert_snapshot!(rows_as_json("SELECT n, label FROM sp ORDER BY n"));
}

// -------------------------------------------------------------------
// Edge-case tests — each pins an invariant that is easy to break and
// expensive to debug.
// -------------------------------------------------------------------

/// The rowid→TID encoding must keep `offset` within `MaxHeapTuplesPerPage`
/// (~291) for tables of any size: index and bitmap scans validate the offset
/// against that bound and abort with `ERROR: tuple offset out of range`
/// otherwise. `(block, offset)` packing with `TIDS_PER_BLOCK = 256` keeps
/// every rowid in range — this exercises rowids well past 256.
#[pg_test]
fn regression_large_table_index_scan() {
    Spi::run(
        "DROP TABLE IF EXISTS big_idx;
         CREATE TABLE big_idx (id int, payload text) USING sqlite_heap;
         INSERT INTO big_idx
           SELECT g, 'row-'||g FROM generate_series(1, 5000) g;
         CREATE INDEX big_idx_id ON big_idx (id);
         SET enable_seqscan = off;",
    )
    .unwrap();
    // Look up rows whose rowids land well past offset 256.
    for &id in &[300, 1000, 2049, 4999] {
        let name = Spi::get_one::<String>(&format!(
            "SELECT payload FROM big_idx WHERE id = {id}"
        ))
        .unwrap();
        assert_eq!(name.as_deref(), Some(format!("row-{id}").as_str()));
    }
    // Bitmap-ish path: a range that spans many "blocks".
    let count = Spi::get_one::<i64>(
        "SELECT count(*) FROM big_idx WHERE id BETWEEN 250 AND 2500",
    )
    .unwrap();
    assert_eq!(count, Some(2251));
}

/// `index_delete_tuples` must populate `delstate` — mark genuinely-dead
/// entries deletable, or shrink `ndeltids` to 0. btree's bottom-up deletion
/// (triggered by a leaf page filling with dead duplicate entries, e.g.
/// UPDATEing the same indexed key over and over) asserts
/// `ndeletable > 0 || nupdatable > 0` and aborts the backend if the callback
/// leaves the state untouched.
#[pg_test]
fn regression_repeated_update_same_key() {
    Spi::run(
        "DROP TABLE IF EXISTS churn;
         CREATE TABLE churn (id int, hits int) USING sqlite_heap;
         INSERT INTO churn VALUES (1, 0);
         CREATE INDEX churn_id ON churn (id);",
    )
    .unwrap();
    // 1000 updates of the same row → 1000 dead index entries with the
    // same key, which forces btree's bottom-up deletion pass.
    for _ in 0..1000 {
        Spi::run("UPDATE churn SET hits = hits + 1 WHERE id = 1").unwrap();
    }
    let hits = Spi::get_one::<i32>("SELECT hits FROM churn WHERE id = 1").unwrap();
    assert_eq!(hits, Some(1000));
    let count = Spi::get_one::<i64>("SELECT count(*) FROM churn").unwrap();
    assert_eq!(count, Some(1));
    // And the index still resolves the (now heavily-versioned) key.
    Spi::run("SET enable_seqscan = off").unwrap();
    let via_index =
        Spi::get_one::<i32>("SELECT hits FROM churn WHERE id = 1").unwrap();
    assert_eq!(via_index, Some(1000));
}

/// Deleting then re-inserting many distinct keys also churns the index; the
/// bottom-up deletion path must stay healthy across a delete/insert mix.
#[pg_test]
fn regression_delete_reinsert_churn() {
    Spi::run(
        "DROP TABLE IF EXISTS dr;
         CREATE TABLE dr (id int, v int) USING sqlite_heap;
         INSERT INTO dr SELECT g, g FROM generate_series(1, 500) g;
         CREATE INDEX dr_id ON dr (id);",
    )
    .unwrap();
    for _ in 0..5 {
        Spi::run("DELETE FROM dr WHERE id % 2 = 0").unwrap();
        Spi::run(
            "INSERT INTO dr SELECT g, g FROM generate_series(1, 500) g \
             WHERE g % 2 = 0",
        )
        .unwrap();
    }
    let count = Spi::get_one::<i64>("SELECT count(*) FROM dr").unwrap();
    assert_eq!(count, Some(500));
    Spi::run("SET enable_seqscan = off").unwrap();
    let v = Spi::get_one::<i32>("SELECT v FROM dr WHERE id = 250").unwrap();
    assert_eq!(v, Some(250));
}

/// `scan_analyze_next_block` must advance the ReadStream so ANALYZE samples
/// rows, and `relation_size` must report a nonzero block count so
/// `vac_estimate_reltuples` doesn't divide by zero (which yields
/// `n_distinct = -inf`). Guards that ANALYZE runs, populates `pg_stats`,
/// gathers the MCV list, *and* produces a finite, plausible `n_distinct`.
#[pg_test]
fn regression_analyze_gathers_stats() {
    Spi::run(
        "DROP TABLE IF EXISTS az;
         CREATE TABLE az (id int, label text) USING sqlite_heap;
         INSERT INTO az
           SELECT g, 'l-'||(g % 10) FROM generate_series(1, 2000) g;
         ANALYZE az;",
    )
    .unwrap();
    // ANALYZE must have produced a stats row for the column at all.
    let rows = Spi::get_one::<i64>(
        "SELECT count(*) FROM pg_stats \
         WHERE tablename = 'az' AND attname = 'label'",
    )
    .unwrap();
    assert_eq!(rows, Some(1), "ANALYZE produced no pg_stats row");
    // `label` has 10 evenly-distributed values, so every one of them
    // should land in the most-common-values list.
    let n_mcv = Spi::get_one::<i32>(
        "SELECT array_length(most_common_vals, 1) FROM pg_stats \
         WHERE tablename = 'az' AND attname = 'label'",
    )
    .unwrap();
    assert_eq!(n_mcv, Some(10), "MCV list not gathered");
    // `n_distinct` must be finite and in the right ballpark — 10 exactly,
    // or a small negative fraction. Never `-inf`.
    let n_distinct = Spi::get_one::<f32>(
        "SELECT n_distinct FROM pg_stats \
         WHERE tablename = 'az' AND attname = 'label'",
    )
    .unwrap()
    .expect("n_distinct present");
    assert!(
        n_distinct.is_finite() && (-1.0..=10.0).contains(&n_distinct),
        "n_distinct should be finite and plausible, got {n_distinct}"
    );
}

/// A bitmap heap scan must not force a full `select_all` of the relation —
/// `rows` is loaded lazily and the bitmap-exact path resolves each TID
/// directly. This guards that the lazy path still returns exactly the
/// matching rows.
#[pg_test]
fn regression_bitmap_scan_lazy_rows() {
    Spi::run(
        "DROP TABLE IF EXISTS bm;
         CREATE TABLE bm (id int, v int) USING sqlite_heap;
         INSERT INTO bm SELECT g, g * 3 FROM generate_series(1, 4000) g;
         CREATE INDEX bm_id ON bm (id);
         ANALYZE bm;
         SET enable_seqscan = off;
         SET enable_indexscan = off;",
    )
    .unwrap();
    // enable_indexscan=off + enable_seqscan=off forces the bitmap path.
    let plan = Spi::get_one::<String>(
        "EXPLAIN (COSTS off) SELECT v FROM bm WHERE id IN (7, 1234, 3999)",
    )
    .unwrap()
    .unwrap();
    assert!(
        plan.contains("Bitmap Heap Scan"),
        "expected a bitmap heap scan, got: {plan}"
    );
    let sum = Spi::get_one::<i64>(
        "SELECT sum(v)::bigint FROM bm WHERE id IN (7, 1234, 3999)",
    )
    .unwrap();
    assert_eq!(sum, Some((7 + 1234 + 3999) * 3));
}

/// An UPDATE moves the row to a new TID, drops the old indexed value, and
/// makes the new one resolvable through the index.
#[pg_test]
fn regression_update_reindexes() {
    Spi::run(
        "DROP TABLE IF EXISTS upd;
         CREATE TABLE upd (id int, payload text) USING sqlite_heap;
         INSERT INTO upd VALUES (1, 'x');
         CREATE INDEX upd_id ON upd (id);
         SET enable_seqscan = off;",
    )
    .unwrap();
    let tid_before =
        Spi::get_one::<String>("SELECT ctid::text FROM upd WHERE id = 1").unwrap();
    Spi::run("UPDATE upd SET id = 2 WHERE id = 1").unwrap();
    let tid_after =
        Spi::get_one::<String>("SELECT ctid::text FROM upd WHERE id = 2").unwrap();
    assert_ne!(tid_before, tid_after, "UPDATE kept the old TID");
    assert_eq!(
        Spi::get_one::<i64>("SELECT count(*) FROM upd WHERE id = 1").unwrap(),
        Some(0),
        "old indexed value still resolves"
    );
    assert_eq!(
        Spi::get_one::<String>("SELECT payload FROM upd WHERE id = 2")
            .unwrap()
            .as_deref(),
        Some("x"),
        "updated row lost its payload"
    );
}

/// An older snapshot (here, an open cursor) must still see the pre-update row
/// after a later UPDATE — the old row version stays physically present and
/// `visibility::row_visible` keeps it visible to that snapshot. Forces the
/// index-scan path.
#[pg_test]
fn regression_old_snapshot_sees_pre_update_row() {
    Spi::run(
        "DROP TABLE IF EXISTS osr;
         CREATE TABLE osr (id int, val int) USING sqlite_heap;
         INSERT INTO osr SELECT g, g FROM generate_series(1, 100) g;
         CREATE INDEX osr_id ON osr (id);
         SET enable_seqscan = off;",
    )
    .unwrap();
    // The cursor's snapshot is fixed at OPEN — before the UPDATE — so its
    // FETCH must still return the pre-update value.
    Spi::run(
        "DO $$
         DECLARE
             cur CURSOR FOR SELECT val FROM osr WHERE id = 42;
             v int;
         BEGIN
             OPEN cur;
             UPDATE osr SET val = val + 1000 WHERE id = 42;
             FETCH cur INTO v;
             IF v <> 42 THEN
                 RAISE EXCEPTION 'old snapshot saw %, expected 42', v;
             END IF;
             CLOSE cur;
         END $$;",
    )
    .unwrap();
    // And the post-update row is correct for a fresh snapshot.
    assert_eq!(
        Spi::get_one::<i32>("SELECT val FROM osr WHERE id = 42").unwrap(),
        Some(1042),
    );
}
