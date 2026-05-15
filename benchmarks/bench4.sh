#!/usr/bin/env bash
# 4-way bench: heap vs sqlite_heap (Rust) vs sqlite_heap_zig vs sqlite_heap_ll
# (LLVM IR).
#
# Pre-reqs (all installed and pg restarted):
#   cargo pgrx install --release
#   (cd zig && zig build pg-install -Doptimize=ReleaseFast …)
#   (cd llvm-ir/sqlite_heap_ll && ./build.sh)
#   bench DB exists with all three extensions created.

set -euo pipefail

PGRXP=/Users/frectonz/.pgrx/18.3/pgrx-install
PSQL_FAST="$PGRXP/bin/psql -h localhost -p 28818 -d bench -q -t -A"
N=${N:-10000}

bench_op() {
    local name="$1"; shift
    local prep="$1"; shift
    local sql_heap="$1"; shift
    local sql_rust="$1"; shift
    local sql_zig="$1"; shift
    local sql_ll="$1"; shift

    echo
    echo "=== $name ==="
    if [ -n "$prep" ]; then
        hyperfine \
            --warmup 2 --runs 10 \
            --prepare "$PSQL_FAST -c \"$prep\"" \
            --command-name "heap"             "$PSQL_FAST -c \"$sql_heap\"" \
            --command-name "sqlite_heap_rust" "$PSQL_FAST -c \"$sql_rust\"" \
            --command-name "sqlite_heap_zig"  "$PSQL_FAST -c \"$sql_zig\"" \
            --command-name "sqlite_heap_ll"   "$PSQL_FAST -c \"$sql_ll\""
    else
        hyperfine \
            --warmup 2 --runs 10 \
            --command-name "heap"             "$PSQL_FAST -c \"$sql_heap\"" \
            --command-name "sqlite_heap_rust" "$PSQL_FAST -c \"$sql_rust\"" \
            --command-name "sqlite_heap_zig"  "$PSQL_FAST -c \"$sql_zig\"" \
            --command-name "sqlite_heap_ll"   "$PSQL_FAST -c \"$sql_ll\""
    fi
}

echo "Setting up bench DB (N=$N rows per table)…"
$PSQL_FAST <<EOF
DROP TABLE IF EXISTS t_heap;
DROP TABLE IF EXISTS t_rust;
DROP TABLE IF EXISTS t_zig;
DROP TABLE IF EXISTS t_ll;
CREATE TABLE t_heap (id int, name text, value int);
CREATE TABLE t_rust (id int, name text, value int) USING sqlite_heap;
CREATE TABLE t_zig  (id int, name text, value int) USING sqlite_heap_zig;
CREATE TABLE t_ll   (id int, name text, value int) USING sqlite_heap_ll;
EOF

bench_op "Bulk INSERT $N rows (single statement)" \
    "TRUNCATE t_heap; TRUNCATE t_rust; TRUNCATE t_zig; TRUNCATE t_ll;" \
    "INSERT INTO t_heap SELECT g, 'name-'||g, g*2 FROM generate_series(1, $N) g" \
    "INSERT INTO t_rust SELECT g, 'name-'||g, g*2 FROM generate_series(1, $N) g" \
    "INSERT INTO t_zig  SELECT g, 'name-'||g, g*2 FROM generate_series(1, $N) g" \
    "INSERT INTO t_ll   SELECT g, 'name-'||g, g*2 FROM generate_series(1, $N) g"

echo "Re-populating tables and building indexes for read benchmarks…"
$PSQL_FAST <<EOF
TRUNCATE t_heap; TRUNCATE t_rust; TRUNCATE t_zig; TRUNCATE t_ll;
INSERT INTO t_heap SELECT g, 'name-'||g, g*2 FROM generate_series(1, $N) g;
INSERT INTO t_rust SELECT g, 'name-'||g, g*2 FROM generate_series(1, $N) g;
INSERT INTO t_zig  SELECT g, 'name-'||g, g*2 FROM generate_series(1, $N) g;
INSERT INTO t_ll   SELECT g, 'name-'||g, g*2 FROM generate_series(1, $N) g;
CREATE INDEX idx_heap_id ON t_heap (id);
CREATE INDEX idx_rust_id ON t_rust (id);
CREATE INDEX idx_zig_id  ON t_zig  (id);
CREATE INDEX idx_ll_id   ON t_ll   (id);
ANALYZE t_heap;
EOF

bench_op "SELECT count(*) (full seq scan)" \
    "" \
    "SELECT count(*) FROM t_heap" \
    "SELECT count(*) FROM t_rust" \
    "SELECT count(*) FROM t_zig" \
    "SELECT count(*) FROM t_ll"

bench_op "SELECT * WHERE id = $((N/2)) (B-tree point lookup)" \
    "" \
    "SET enable_seqscan=off; SELECT * FROM t_heap WHERE id = $((N/2))" \
    "SET enable_seqscan=off; SELECT * FROM t_rust WHERE id = $((N/2))" \
    "SET enable_seqscan=off; SELECT * FROM t_zig  WHERE id = $((N/2))" \
    "SET enable_seqscan=off; SELECT * FROM t_ll   WHERE id = $((N/2))"

bench_op "UPDATE single row" \
    "" \
    "UPDATE t_heap SET value = value+1 WHERE id = $((N/2))" \
    "UPDATE t_rust SET value = value+1 WHERE id = $((N/2))" \
    "UPDATE t_zig  SET value = value+1 WHERE id = $((N/2))" \
    "UPDATE t_ll   SET value = value+1 WHERE id = $((N/2))"

bench_op "DELETE then re-INSERT one row (round-trip)" \
    "DELETE FROM t_heap WHERE id = -1; INSERT INTO t_heap VALUES (-1, 'tmp', 0); DELETE FROM t_rust WHERE id = -1; INSERT INTO t_rust VALUES (-1, 'tmp', 0); DELETE FROM t_zig WHERE id = -1; INSERT INTO t_zig VALUES (-1, 'tmp', 0); DELETE FROM t_ll WHERE id = -1; INSERT INTO t_ll VALUES (-1, 'tmp', 0);" \
    "DELETE FROM t_heap WHERE id = -1" \
    "DELETE FROM t_rust WHERE id = -1" \
    "DELETE FROM t_zig  WHERE id = -1" \
    "DELETE FROM t_ll   WHERE id = -1"

echo
echo "=== Storage size after $N rows ==="
heap_bytes=$($PSQL_FAST -c "SELECT pg_relation_size('t_heap')")
db_oid=$($PSQL_FAST -c "SELECT oid FROM pg_database WHERE datname=current_database()")
rust_oid=$($PSQL_FAST -c "SELECT 't_rust'::regclass::oid")
zig_oid=$($PSQL_FAST -c  "SELECT 't_zig'::regclass::oid")
ll_oid=$($PSQL_FAST -c   "SELECT 't_ll'::regclass::oid")
rust_path="/Users/frectonz/.pgrx/data-18/sqlite_heap/${db_oid}/${rust_oid}.sqlite"
zig_path="/Users/frectonz/.pgrx/data-18/sqlite_heap_zig/${db_oid}/${zig_oid}.sqlite"
ll_path="/Users/frectonz/.pgrx/data-18/sqlite_heap_ll/${db_oid}/${ll_oid}.sqlite"
fsize() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo "?"; }
printf "heap:             %s bytes\n" "$heap_bytes"
printf "sqlite_heap_rust: %s bytes  (%s)\n" "$(fsize "$rust_path")" "$rust_path"
printf "sqlite_heap_zig:  %s bytes  (%s)\n" "$(fsize "$zig_path")"  "$zig_path"
printf "sqlite_heap_ll:   %s bytes  (%s)\n" "$(fsize "$ll_path")"   "$ll_path"
