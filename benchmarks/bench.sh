#!/usr/bin/env bash
# Compare sqlite_heap vs Postgres default heap on common workloads.
# Run from `nix develop --command ./benchmarks/bench.sh` after starting pg18.
#
# IMPORTANT: install the extension with `cargo pgrx install --release` first.
# The debug build carries Rust's `precondition_check` instrumentation on every
# pointer op and roughly triples the apparent overhead — benchmarking it is
# meaningless.
#
# Each benchmark uses hyperfine with `--warmup 2 --runs 10`. Reported times
# are wall-clock (includes psql startup ~10-20ms) so absolute numbers
# overstate per-op cost. With per-op cost under ~5ms hyperfine itself warns
# it can't calibrate that finely — for per-operation cost use `warm.sh`
# (pgbench over a persistent connection), which is the meaningful number for
# a pooled application. This script mostly measures the cold SQLite-file
# open, which a real connection pool pays once.

set -euo pipefail

PGRXP=/Users/frectonz/.pgrx/18.3/pgrx-install
PSQL_FAST="$PGRXP/bin/psql -h localhost -p 28818 -d bench -q -t -A"
N=${N:-10000}

silent() { "$@" >/dev/null 2>&1 || true; }

bench_op() {
    local name="$1"; shift
    local prep="$1"; shift
    local sql_heap="$1"; shift
    local sql_sqlite="$1"; shift

    echo
    echo "=== $name ==="
    if [ -n "$prep" ]; then
        hyperfine \
            --warmup 2 --runs 10 \
            --prepare "$PSQL_FAST -c \"$prep\"" \
            --command-name "heap"        "$PSQL_FAST -c \"$sql_heap\"" \
            --command-name "sqlite_heap" "$PSQL_FAST -c \"$sql_sqlite\""
    else
        hyperfine \
            --warmup 2 --runs 10 \
            --command-name "heap"        "$PSQL_FAST -c \"$sql_heap\"" \
            --command-name "sqlite_heap" "$PSQL_FAST -c \"$sql_sqlite\""
    fi
}

echo "Setting up bench DB (N=$N rows per table)…"
$PSQL_FAST <<EOF
DROP TABLE IF EXISTS t_heap;
DROP TABLE IF EXISTS t_sqlite;
CREATE TABLE t_heap   (id int, name text, value int);
CREATE TABLE t_sqlite (id int, name text, value int) USING sqlite_heap;
EOF

bench_op "Bulk INSERT $N rows (single statement)" \
    "TRUNCATE t_heap; TRUNCATE t_sqlite;" \
    "INSERT INTO t_heap   SELECT g, 'name-'||g, g*2 FROM generate_series(1, $N) g" \
    "INSERT INTO t_sqlite SELECT g, 'name-'||g, g*2 FROM generate_series(1, $N) g"

echo "Re-populating tables and building indexes for read benchmarks…"
$PSQL_FAST <<EOF
TRUNCATE t_heap; TRUNCATE t_sqlite;
INSERT INTO t_heap   SELECT g, 'name-'||g, g*2 FROM generate_series(1, $N) g;
INSERT INTO t_sqlite SELECT g, 'name-'||g, g*2 FROM generate_series(1, $N) g;
CREATE INDEX idx_heap_id   ON t_heap   (id);
CREATE INDEX idx_sqlite_id ON t_sqlite (id);
ANALYZE t_heap;
EOF

bench_op "SELECT count(*) (full seq scan)" \
    "" \
    "SELECT count(*) FROM t_heap"   \
    "SELECT count(*) FROM t_sqlite"

bench_op "SELECT * WHERE id = $((N/2)) (B-tree point lookup)" \
    "" \
    "SET enable_seqscan=off; SELECT * FROM t_heap   WHERE id = $((N/2))" \
    "SET enable_seqscan=off; SELECT * FROM t_sqlite WHERE id = $((N/2))"

bench_op "UPDATE single row" \
    "" \
    "UPDATE t_heap   SET value = value+1 WHERE id = $((N/2))" \
    "UPDATE t_sqlite SET value = value+1 WHERE id = $((N/2))"

bench_op "DELETE then re-INSERT one row (round-trip)" \
    "INSERT INTO t_heap   VALUES (-1, 'tmp', 0) ON CONFLICT DO NOTHING; INSERT INTO t_sqlite VALUES (-1, 'tmp', 0) ON CONFLICT DO NOTHING;" \
    "DELETE FROM t_heap   WHERE id = -1" \
    "DELETE FROM t_sqlite WHERE id = -1"

# Storage size: how much disk does the same data take?
echo
echo "=== Storage size after $N rows ==="
heap_bytes=$($PSQL_FAST -c "SELECT pg_relation_size('t_heap')")
db_oid=$($PSQL_FAST -c "SELECT oid FROM pg_database WHERE datname=current_database()")
t_oid=$($PSQL_FAST -c "SELECT 't_sqlite'::regclass::oid")
sqlite_path="/Users/frectonz/.pgrx/data-18/sqlite_heap/${db_oid}/${t_oid}.sqlite"
sqlite_bytes=$(stat -f%z "$sqlite_path" 2>/dev/null || stat -c%s "$sqlite_path" 2>/dev/null || echo "?")
printf "heap:        %s bytes\n" "$heap_bytes"
printf "sqlite_heap: %s bytes  (%s)\n" "$sqlite_bytes" "$sqlite_path"
