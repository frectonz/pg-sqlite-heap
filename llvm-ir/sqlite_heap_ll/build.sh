#!/usr/bin/env bash
# Build pg_sqlite_heap_ll: compile main.ll + shim.c, link the SQLite the rest
# of the project uses, install into the pgrx-managed Postgres tree.

set -euo pipefail
cd "$(dirname "$0")"

PG_CONFIG=${PG_CONFIG:-/Users/frectonz/.pgrx/18.3/pgrx-install/bin/pg_config}
PG_INCLUDE=$("$PG_CONFIG" --includedir-server)
LIBDIR=$("$PG_CONFIG" --pkglibdir)
SHAREDIR=$("$PG_CONFIG" --sharedir)

# Same system SQLite the Zig and refactored Rust impls link.
SQLITE_DIR=/nix/store/pd3zpzir56yy600l1iy500y7lw03pcjw-sqlite-3.51.2
SQLITE_INC="$SQLITE_DIR/include"
SQLITE_LIB="$SQLITE_DIR/lib"

clang -O2 -fPIC -c shim.c    -I"$PG_INCLUDE" -I"$SQLITE_INC" -o shim.o
clang -O2 -fPIC -c main.ll                                  -o main.o
clang -shared -undefined dynamic_lookup \
      -Wl,-install_name,@rpath/pg_sqlite_heap_ll.dylib \
      -L"$SQLITE_LIB" -lsqlite3 \
      shim.o main.o -o pg_sqlite_heap_ll.dylib

install -m 0755 pg_sqlite_heap_ll.dylib       "$LIBDIR/pg_sqlite_heap_ll.dylib"
install -m 0644 pg_sqlite_heap_ll.control     "$SHAREDIR/extension/pg_sqlite_heap_ll.control"
install -m 0644 pg_sqlite_heap_ll--0.0.0.sql  "$SHAREDIR/extension/pg_sqlite_heap_ll--0.0.0.sql"
echo "installed $LIBDIR/pg_sqlite_heap_ll.dylib"
