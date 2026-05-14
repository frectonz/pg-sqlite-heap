#!/usr/bin/env bash
# Warm-connection benchmark: sqlite_heap vs Postgres default heap.
#
# Unlike bench.sh (hyperfine, fresh psql per op — dominated by process
# startup and SQLite cold-open), this uses pgbench over a persistent
# connection. That isolates per-operation cost, which is what a real
# pooled application sees.
#
# Run from `nix develop --command ./benchmarks/warm.sh` after `cargo pgrx
# install --release` and starting pg18.

set -euo pipefail

PGRXP=/Users/frectonz/.pgrx/18.3/pgrx-install
export PGHOST=localhost PGPORT=28818 PGDATABASE=bench
PSQL="$PGRXP/bin/psql -q -t -A"
PGBENCH="$PGRXP/bin/pgbench"
N=${N:-10000}
TIME=${TIME:-5}        # seconds per pgbench run
CLIENTS=${CLIENTS:-1}

echo "Setting up warm-bench tables (N=$N)…"
$PSQL <<EOF
DROP TABLE IF EXISTS w_heap;
DROP TABLE IF EXISTS w_sqlite;
CREATE TABLE w_heap   (id int, name text, value int);
CREATE TABLE w_sqlite (id int, name text, value int) USING sqlite_heap;
INSERT INTO w_heap   SELECT g, 'name-'||g, g*2 FROM generate_series(1, $N) g;
INSERT INTO w_sqlite SELECT g, 'name-'||g, g*2 FROM generate_series(1, $N) g;
CREATE INDEX idx_w_heap_id   ON w_heap   (id);
CREATE INDEX idx_w_sqlite_id ON w_sqlite (id);
ANALYZE w_heap;
ANALYZE w_sqlite;
EOF

run() {
    local tbl="$1" sql="$2"
    local f; f=$(mktemp)
    printf '%b' "${sql//__T__/$tbl}" > "$f"
    $PGBENCH -n -T "$TIME" -c "$CLIENTS" -f "$f" 2>/dev/null \
        | awk '/^tps/ {print $3}'
    rm -f "$f"
}

bench_pair() {
    local label="$1" sql="$2"
    echo
    echo "=== $label ==="
    local h s
    h=$(run w_heap   "$sql")
    s=$(run w_sqlite "$sql")
    printf '  %-12s %12.1f tps\n' heap "$h"
    printf '  %-12s %12.1f tps\n' sqlite_heap "$s"
    awk -v h="$h" -v s="$s" 'BEGIN {
        if (s > h) printf "  -> sqlite_heap %.2fx faster\n", s/h;
        else       printf "  -> sqlite_heap %.2fx slower\n", h/s;
    }'
}

bench_pair "SELECT point lookup" \
    "\\set id random(1, $N)\nSELECT * FROM __T__ WHERE id = :id;"

bench_pair "INSERT single row" \
    "\\set id random(1, $N)\nINSERT INTO __T__ VALUES (:id, 'x', :id);"

bench_pair "UPDATE single row (indexed col unchanged)" \
    "\\set id random(1, $N)\nUPDATE __T__ SET value = value + 1 WHERE id = :id;"

bench_pair "DELETE single row" \
    "\\set id random(1, $N)\nDELETE FROM __T__ WHERE id = :id;"
