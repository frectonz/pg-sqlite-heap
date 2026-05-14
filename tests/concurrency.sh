#!/usr/bin/env bash
# Multi-backend concurrency / correctness stress test for sqlite_heap.
#
# The pgrx `#[pg_test]` harness runs every test inside a single
# transaction-scoped backend, so it cannot exercise *cross-backend*
# behaviour: concurrent writers serialising on SQLite's single-writer WAL
# lock, readers seeing consistent snapshots while a writer commits, MVCC
# isolation across real connections. This script does, by driving many real
# `psql` connections at once and asserting the table stays consistent.
#
# Run from `nix develop --command ./tests/concurrency.sh` against a running
# pg18 cluster with the extension installed (`cargo pgrx install --release`).

set -euo pipefail

PGRXP=/Users/frectonz/.pgrx/18.3/pgrx-install
export PGHOST=localhost PGPORT=28818 PGDATABASE=bench
PSQL="$PGRXP/bin/psql -q -t -A -v ON_ERROR_STOP=1"

WORKERS=${WORKERS:-8}      # concurrent backends
ROWS=${ROWS:-500}         # rows each worker inserts
ROUNDS=${ROUNDS:-20}      # update rounds per worker

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok: $*"; }

echo "Setup ($WORKERS workers, $ROWS rows each)…"
$PSQL <<EOF
DROP TABLE IF EXISTS conc;
CREATE TABLE conc (id int, worker int, n int) USING sqlite_heap;
CREATE INDEX conc_worker ON conc (worker);
EOF

# --- Phase 1: concurrent INSERT -------------------------------------------
# Every worker inserts its own ROWS rows, all at once. SQLite is
# single-writer, so the backends serialise on the WAL lock (busy_timeout) —
# none should error, none should lose rows.
echo
echo "=== Phase 1: $WORKERS concurrent INSERT backends ==="
for w in $(seq 1 "$WORKERS"); do
    $PSQL -c "INSERT INTO conc SELECT g, $w, 0 FROM generate_series(1, $ROWS) g" &
done
wait

total=$($PSQL -c "SELECT count(*) FROM conc")
[ "$total" -eq $((WORKERS * ROWS)) ] \
    || fail "Phase 1: expected $((WORKERS * ROWS)) rows, got $total"
ok "all $total rows present, no lost inserts"

distinct_workers=$($PSQL -c "SELECT count(DISTINCT worker) FROM conc")
[ "$distinct_workers" -eq "$WORKERS" ] \
    || fail "Phase 1: expected $WORKERS workers, got $distinct_workers"
ok "every worker's batch committed"

# --- Phase 2: concurrent UPDATE -------------------------------------------
# Each worker repeatedly bumps `n` on *its own* rows. Disjoint row sets, so
# the only contention is the SQLite write lock — the final value of every
# row must be exactly ROUNDS (no lost updates, no double-applies).
echo
echo "=== Phase 2: $WORKERS concurrent UPDATE backends, $ROUNDS rounds each ==="
for w in $(seq 1 "$WORKERS"); do
    (
        for _ in $(seq 1 "$ROUNDS"); do
            $PSQL -c "UPDATE conc SET n = n + 1 WHERE worker = $w"
        done
    ) &
done
wait

bad=$($PSQL -c "SELECT count(*) FROM conc WHERE n <> $ROUNDS")
[ "$bad" -eq 0 ] \
    || fail "Phase 2: $bad rows have n <> $ROUNDS (lost or double-applied updates)"
ok "every row bumped exactly $ROUNDS times"

# --- Phase 3: concurrent mixed DELETE / INSERT churn ----------------------
# Each worker deletes then re-inserts its rows a few times. Stresses the
# MVCC dead-row path and rowid recycling under contention.
echo
echo "=== Phase 3: $WORKERS concurrent DELETE+reINSERT backends ==="
for w in $(seq 1 "$WORKERS"); do
    (
        for _ in $(seq 1 5); do
            $PSQL -c "DELETE FROM conc WHERE worker = $w"
            $PSQL -c "INSERT INTO conc SELECT g, $w, $ROUNDS FROM generate_series(1, $ROWS) g"
        done
    ) &
done
wait

total=$($PSQL -c "SELECT count(*) FROM conc")
[ "$total" -eq $((WORKERS * ROWS)) ] \
    || fail "Phase 3: expected $((WORKERS * ROWS)) rows, got $total"
ok "table consistent after churn"

# --- Phase 4: readers concurrent with a writer ----------------------------
# A long writer runs while many readers poll. Each reader's count must be a
# *consistent* snapshot — never a torn in-between value. The writer moves
# every row from worker 1's set to worker -1, so a reader sees either the
# pre-state or the post-state count for those, never garbage.
echo
echo "=== Phase 4: readers concurrent with a writer ==="
before=$($PSQL -c "SELECT count(*) FROM conc")
(
    # one big writer transaction
    $PSQL -c "BEGIN; UPDATE conc SET worker = -1 WHERE worker = 1; \
              SELECT pg_sleep(0.5); COMMIT;"
) &
writer=$!
reader_bad=0
for _ in $(seq 1 50); do
    c=$($PSQL -c "SELECT count(*) FROM conc")
    [ "$c" -eq "$before" ] || reader_bad=$((reader_bad + 1))
done
wait "$writer"
[ "$reader_bad" -eq 0 ] \
    || fail "Phase 4: $reader_bad readers saw an inconsistent row count"
ok "readers always saw a consistent snapshot during the writer"

after=$($PSQL -c "SELECT count(*) FROM conc")
[ "$after" -eq "$before" ] || fail "Phase 4: row count changed ($before -> $after)"
ok "writer committed cleanly, count preserved"

# --- Phase 5: REPEATABLE READ snapshot vs concurrent updates --------------
# A long REPEATABLE READ transaction snapshots worker 2's rows, then while it
# holds that snapshot another backend updates every one of them (bumping
# `n`). The RR transaction's re-read must still return the *original* sum —
# proving an old cross-backend snapshot still sees the pre-update rows via
# MVCC visibility (the old rows stay in SQLite until vacuumed).
echo
echo "=== Phase 5: REPEATABLE READ snapshot vs concurrent updates ==="
base_sum=$($PSQL -c "SELECT coalesce(sum(n),0) FROM conc WHERE worker = 2")
rr_out=$(mktemp)
(
    $PSQL <<SQL > "$rr_out"
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT coalesce(sum(n),0) FROM conc WHERE worker = 2;
SELECT pg_sleep(1);
SELECT coalesce(sum(n),0) FROM conc WHERE worker = 2;
COMMIT;
SQL
) &
rr=$!
sleep 0.2
for _ in $(seq 1 10); do
    $PSQL -c "UPDATE conc SET n = n + 1 WHERE worker = 2"
done
wait "$rr"
mapfile -t rr_sums < <(grep -E '^-?[0-9]+$' "$rr_out")
rm -f "$rr_out"
[ "${rr_sums[0]:-x}" = "$base_sum" ] && [ "${rr_sums[1]:-x}" = "$base_sum" ] \
    || fail "Phase 5: RR snapshot drifted (baseline $base_sum, saw ${rr_sums[*]})"
ok "REPEATABLE READ snapshot stable across concurrent updates"
post=$($PSQL -c "SELECT coalesce(sum(n),0) FROM conc WHERE worker = 2")
[ "$post" -eq $((base_sum + 10 * ROWS)) ] \
    || fail "Phase 5: post-update sum wrong (expected $((base_sum + 10 * ROWS)), got $post)"
ok "concurrent updates all landed"

# --- SQLite-level integrity ----------------------------------------------
echo
echo "=== SQLite file integrity ==="
db_oid=$($PSQL -c "SELECT oid FROM pg_database WHERE datname = current_database()")
t_oid=$($PSQL -c "SELECT 'conc'::regclass::oid")
sqlite_file="/Users/frectonz/.pgrx/data-18/sqlite_heap/${db_oid}/${t_oid}.sqlite"
if command -v sqlite3 >/dev/null 2>&1 && [ -f "$sqlite_file" ]; then
    res=$(sqlite3 "$sqlite_file" "PRAGMA integrity_check")
    [ "$res" = "ok" ] || fail "SQLite integrity_check: $res"
    ok "PRAGMA integrity_check = ok"
else
    echo "  skip: sqlite3 CLI not on PATH (file: $sqlite_file)"
fi

echo
echo "ALL CONCURRENCY CHECKS PASSED"
