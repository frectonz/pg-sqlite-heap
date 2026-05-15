#!/usr/bin/env bash
# The zig equivalent of `cargo pgrx run`: rebuild + reinstall the extension,
# start the pgrx-managed PostgreSQL if needed, then exec psql against it.
#
# Any arguments are forwarded to the client (e.g. `./run.sh -c 'SELECT 1'`).
#
# Override either side:
#   PG_CONFIG  -- which pg_config / cluster to talk to (default: highest-major
#                 entry in `~/.pgrx/config.toml`, falling back to $PATH).
#   PSQL       -- which client to launch (default: the pgrx-shipped psql).
#                 Anything that takes a `postgresql://` URL works -- e.g.
#                 `PSQL=pgcli ./run.sh`, `PSQL=usql ./run.sh`.

set -euo pipefail

cd "$(dirname "$0")"

# --- locate pg_config ----------------------------------------------------
PGC="${PG_CONFIG:-}"
if [ -z "$PGC" ] && [ -f "$HOME/.pgrx/config.toml" ]; then
    PGC=$(grep -oE '"[^"]*pg_config"' "$HOME/.pgrx/config.toml" | tail -1 | tr -d '"')
fi
[ -z "$PGC" ] && PGC=$(command -v pg_config || true)
if [ -z "$PGC" ] || [ ! -x "$PGC" ]; then
    echo "run.sh: could not locate pg_config (try setting \$PG_CONFIG)" >&2
    exit 1
fi

BINDIR=$("$PGC" --bindir)
# "PostgreSQL 18.3" -> 18. pgrx names its data dir after the major version and
# picks port 28800 + major.
MAJOR=$("$PGC" --version | awk '{print $2}' | cut -d. -f1)
PGDATA="$HOME/.pgrx/data-$MAJOR"
PORT=$((28800 + MAJOR))
LOG="/tmp/pg_sqlite_heap_zig-$MAJOR.log"

# --- build + install -----------------------------------------------------
zig build pg-install -Dpg_config="$PGC"

# --- start the cluster if it is not already running ----------------------
if ! "$BINDIR/pg_ctl" -D "$PGDATA" status >/dev/null 2>&1; then
    if [ ! -d "$PGDATA" ]; then
        echo "run.sh: $PGDATA does not exist; initialise it with \`cargo pgrx init\` first" >&2
        exit 1
    fi
    "$BINDIR/pg_ctl" -D "$PGDATA" -l "$LOG" -o "-p $PORT" start
fi

# --- exec the client -----------------------------------------------------
# Use a `postgresql://` URL so pgcli / usql / etc. work uniformly; psql
# accepts the same form.
URL="postgresql://localhost:$PORT/postgres"
CLIENT="${PSQL:-$BINDIR/psql}"
exec "$CLIENT" "$URL" "$@"
