#!/usr/bin/env bash
# Compile pg_sqlite_heap_ll.ll into a loadable Postgres dylib, then drop the
# control file + SQL script into the pgrx-install share dir so a plain
# `CREATE EXTENSION pg_sqlite_heap_ll` works.

set -euo pipefail
cd "$(dirname "$0")"

PG_CONFIG=${PG_CONFIG:-/Users/frectonz/.pgrx/18.3/pgrx-install/bin/pg_config}
LIBDIR=$("$PG_CONFIG" --pkglibdir)
SHAREDIR=$("$PG_CONFIG" --sharedir)

# `clang -shared` runs LLVM's optimizer and linker over the .ll directly, so
# we get the same codegen path Rust uses for its .rs files — just with the IR
# spelled by hand instead of by rustc.
clang -O2 -shared -undefined dynamic_lookup \
      -Wl,-install_name,@rpath/pg_sqlite_heap_ll.dylib \
      -o pg_sqlite_heap_ll.dylib pg_sqlite_heap_ll.ll

install -m 0755 pg_sqlite_heap_ll.dylib "$LIBDIR/postgresql/pg_sqlite_heap_ll.dylib"
install -m 0644 pg_sqlite_heap_ll.control "$SHAREDIR/extension/pg_sqlite_heap_ll.control"
install -m 0644 pg_sqlite_heap_ll--0.0.0.sql "$SHAREDIR/extension/pg_sqlite_heap_ll--0.0.0.sql"

echo "Installed:"
echo "  $LIBDIR/postgresql/pg_sqlite_heap_ll.dylib"
echo "  $SHAREDIR/extension/pg_sqlite_heap_ll.control"
echo "  $SHAREDIR/extension/pg_sqlite_heap_ll--0.0.0.sql"
