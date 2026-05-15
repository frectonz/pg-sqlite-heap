; sqlite_heap_ll — SQLite-backed table access method, hand-written LLVM IR.
;
; Scope: enough to make CREATE TABLE / INSERT / SELECT / UPDATE / DELETE work
; on `USING sqlite_heap_ll`. No MVCC, no transactions, no indexes-of-our-own,
; no toast, no vacuum, no parallel/bitmap/sample/tidrange scans. Postgres's
; own b-tree indexes work on top because they only need index_fetch_tuple.
;
; A row of tuple bytes lives as one BLOB in a per-relation SQLite file at
;   $PGDATA/sqlite_heap_ll/<dboid>/<reloid>.sqlite
; schema:
;   CREATE TABLE storage (rowid INTEGER PRIMARY KEY, tuple BLOB NOT NULL)
;
; Per-backend state (thread-local globals): the one open sqlite3*, the rel
; oid it belongs to, and prepared statements for the four hot SQL strings.
; If a different relation walks in we close the previous conn.

target triple = "arm64-apple-darwin"

; ===========================================================================
; Module-magic / finfo / handler — same dance as the toy add_one extension.
; ===========================================================================

%struct.Pg_magic_struct = type {
  i32, i32, i32, i32, i32, i32, [32 x i8], ptr, ptr
}

@Pg_magic_data = internal constant %struct.Pg_magic_struct {
  i32 72,                                                              ; len
  i32 1800, i32 100, i32 32, i32 64, i32 1,                            ; ABI
  [32 x i8] c"PostgreSQL\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00",
  ptr null, ptr null
}

define dso_local ptr @Pg_magic_func() {
  ret ptr @Pg_magic_data
}

%struct.Pg_finfo_record = type { i32 }
@pg_finfo_v1 = internal constant %struct.Pg_finfo_record { i32 1 }

define dso_local ptr @pg_finfo_sqlite_heap_ll_handler() {
  ret ptr @pg_finfo_v1
}

; The SQL-callable handler. Returns a pointer to the shim-built TableAmRoutine
; as a Datum.
declare ptr @shim_get_routine()

define dso_local i64 @sqlite_heap_ll_handler(ptr %fcinfo) {
  %routine = call ptr @shim_get_routine()
  %datum = ptrtoint ptr %routine to i64
  ret i64 %datum
}

; ===========================================================================
; External declarations
; ===========================================================================

; --- SQLite ---
declare i32 @sqlite3_open(ptr, ptr)
declare i32 @sqlite3_close(ptr)
declare i32 @sqlite3_exec(ptr, ptr, ptr, ptr, ptr)
declare i32 @sqlite3_prepare_v2(ptr, ptr, i32, ptr, ptr)
declare i32 @sqlite3_finalize(ptr)
declare i32 @sqlite3_reset(ptr)
declare i32 @sqlite3_clear_bindings(ptr)
declare i32 @sqlite3_step(ptr)
declare i32 @sqlite3_bind_int64(ptr, i32, i64)
declare i32 @sqlite3_bind_blob(ptr, i32, ptr, i32, ptr)
declare i64 @sqlite3_column_int64(ptr, i32)
declare ptr @sqlite3_column_blob(ptr, i32)
declare i32 @sqlite3_column_bytes(ptr, i32)
declare i64 @sqlite3_last_insert_rowid(ptr)
declare ptr @sqlite3_errmsg(ptr)
declare void @sqlite3_free(ptr)

; SQLITE_TRANSIENT == (sqlite3_destructor_type)-1. As a function pointer this
; is the value (void(*)(void*))-1; pass it as such.
@sqlite_transient = internal constant ptr inttoptr (i64 -1 to ptr)

; --- shim helpers ---
declare ptr @shim_slot_copy_heap_tuple(ptr)
declare void @shim_slot_clear(ptr)
declare void @shim_slot_store_heap_tuple(ptr, ptr, i8)
declare i32  @shim_rel_oid(ptr)
declare ptr  @shim_rel_tupdesc(ptr)
declare i32  @shim_my_database_id()
declare ptr  @shim_data_dir()
declare ptr  @shim_build_heap_tuple(i32, i64, ptr, i32)
declare void @shim_set_inserted_tid(ptr, i32, i64)
declare i64  @shim_tid_to_rowid(ptr)
declare i32  @shim_heap_tuple_t_len(ptr)
declare ptr  @shim_heap_tuple_t_data(ptr)
declare void @shim_heap_freetuple(ptr)
declare i32  @shim_make_path(ptr, i64, i32, i32)
declare i32  @shim_unlink_path(i32, i32)
declare i64  @shim_file_size(i32, i32)

; --- Postgres ---
declare ptr @palloc(i64)
declare ptr @palloc0(i64)
declare void @pfree(ptr)
declare void @ereport_finish(ptr)  ; we go through ereport via a printf-style helper below

; A tiny "panic" path that just abort()s. Good enough for a stunt extension;
; real code would ereport(ERROR, ...).
declare void @abort()

; TTSOpsHeapTuple is a const global in postgres — pick it up by symbol.
@TTSOpsHeapTuple = external global i8

; ===========================================================================
; Per-backend state
; ===========================================================================

; current open connection and which relation it's for.
@cur_db          = thread_local global ptr null     ; sqlite3 *
@cur_rel_oid     = thread_local global i32 0
@cur_db_oid      = thread_local global i32 0

; cached prepared statements (lazily built on first use against cur_db)
@stmt_insert     = thread_local global ptr null
@stmt_select_all = thread_local global ptr null
@stmt_select_one = thread_local global ptr null
@stmt_delete     = thread_local global ptr null
@stmt_update     = thread_local global ptr null

; static SQL strings (NUL-terminated)
@SQL_CREATE = private unnamed_addr constant [76 x i8] c"CREATE TABLE IF NOT EXISTS storage (rowid INTEGER PRIMARY KEY, tuple BLOB)\00\00"
@SQL_INSERT = private unnamed_addr constant [40 x i8] c"INSERT INTO storage (tuple) VALUES (?1)\00"
@SQL_SEL_AL = private unnamed_addr constant [48 x i8] c"SELECT rowid, tuple FROM storage ORDER BY rowid\00"
@SQL_SEL_ON = private unnamed_addr constant [43 x i8] c"SELECT tuple FROM storage WHERE rowid = ?1\00"
@SQL_DELETE = private unnamed_addr constant [37 x i8] c"DELETE FROM storage WHERE rowid = ?1\00"
@SQL_UPDATE = private unnamed_addr constant [47 x i8] c"UPDATE storage SET tuple = ?1 WHERE rowid = ?2\00"
@SQL_PRAGMA = private unnamed_addr constant [21 x i8] c"PRAGMA synchronous=1\00"
@SQL_TRUNC  = private unnamed_addr constant [21 x i8] c"DELETE FROM storage;\00"

; ===========================================================================
; Helper: finalize-and-null a thread-local prepared statement.
; ===========================================================================
define internal void @stmt_drop(ptr %slot) {
  %s = load ptr, ptr %slot
  %is_null = icmp eq ptr %s, null
  br i1 %is_null, label %done, label %fin
fin:
  %rc = call i32 @sqlite3_finalize(ptr %s)
  store ptr null, ptr %slot
  br label %done
done:
  ret void
}

; Drop everything (prepared stmts + connection). Used when we need to switch
; relations or unlink a file.
define internal void @drop_conn() {
  call void @stmt_drop(ptr @stmt_insert)
  call void @stmt_drop(ptr @stmt_select_all)
  call void @stmt_drop(ptr @stmt_select_one)
  call void @stmt_drop(ptr @stmt_delete)
  call void @stmt_drop(ptr @stmt_update)
  %db = load ptr, ptr @cur_db
  %is_null = icmp eq ptr %db, null
  br i1 %is_null, label %done, label %close
close:
  %rc = call i32 @sqlite3_close(ptr %db)
  store ptr null, ptr @cur_db
  store i32 0, ptr @cur_rel_oid
  br label %done
done:
  ret void
}

; ===========================================================================
; Helper: ensure the open connection corresponds to `rel_oid`. Opens the file
; (creating it + the schema if absent), stashes the handle in @cur_db.
;
; Returns the sqlite3* handle.
; ===========================================================================
define internal ptr @ensure_conn(i32 %rel_oid) {
entry:
  %cur = load i32, ptr @cur_rel_oid
  %same = icmp eq i32 %cur, %rel_oid
  br i1 %same, label %check_db, label %switch

check_db:
  %db_cur = load ptr, ptr @cur_db
  %db_null = icmp eq ptr %db_cur, null
  br i1 %db_null, label %switch, label %ret_existing

ret_existing:
  ret ptr %db_cur

switch:
  call void @drop_conn()
  ; build path
  %pathbuf = alloca [1024 x i8], align 1
  %db_oid = call i32 @shim_my_database_id()
  store i32 %db_oid, ptr @cur_db_oid
  %mk_rc = call i32 @shim_make_path(ptr %pathbuf, i64 1024, i32 %db_oid, i32 %rel_oid)
  %mk_ok = icmp eq i32 %mk_rc, 0
  br i1 %mk_ok, label %do_open, label %panic
panic:
  call void @abort()
  unreachable

do_open:
  %db_slot = alloca ptr, align 8
  store ptr null, ptr %db_slot
  %open_rc = call i32 @sqlite3_open(ptr %pathbuf, ptr %db_slot)
  %open_ok = icmp eq i32 %open_rc, 0
  br i1 %open_ok, label %schema, label %panic

schema:
  %db = load ptr, ptr %db_slot
  store ptr %db, ptr @cur_db
  store i32 %rel_oid, ptr @cur_rel_oid
  ; PRAGMA synchronous=NORMAL — fine for a stunt; we're not crash-durable anyway.
  %rc1 = call i32 @sqlite3_exec(ptr %db, ptr @SQL_PRAGMA, ptr null, ptr null, ptr null)
  %rc2 = call i32 @sqlite3_exec(ptr %db, ptr @SQL_CREATE, ptr null, ptr null, ptr null)
  ret ptr %db
}

; ===========================================================================
; Helper: prepare-and-cache. Given a slot holding the cached stmt and the SQL
; text, returns a ready-to-bind statement (reset + bindings cleared).
; ===========================================================================
define internal ptr @prep_cached(ptr %db, ptr %slot, ptr %sql) {
entry:
  %existing = load ptr, ptr %slot
  %is_null = icmp eq ptr %existing, null
  br i1 %is_null, label %prepare, label %reuse

reuse:
  %rrc = call i32 @sqlite3_reset(ptr %existing)
  %crc = call i32 @sqlite3_clear_bindings(ptr %existing)
  ret ptr %existing

prepare:
  %out = alloca ptr, align 8
  store ptr null, ptr %out
  %rc = call i32 @sqlite3_prepare_v2(ptr %db, ptr %sql, i32 -1, ptr %out, ptr null)
  %ok = icmp eq i32 %rc, 0
  br i1 %ok, label %store, label %panic
panic:
  call void @abort()
  unreachable
store:
  %stmt = load ptr, ptr %out
  store ptr %stmt, ptr %slot
  ret ptr %stmt
}

; ===========================================================================
; tuple_insert
; ===========================================================================
define dso_local void @ll_tuple_insert(ptr %rel, ptr %slot, i32 %cid,
                                       i32 %options, ptr %bistate) {
  %rel_oid = call i32 @shim_rel_oid(ptr %rel)
  %db      = call ptr @ensure_conn(i32 %rel_oid)
  %stmt    = call ptr @prep_cached(ptr %db, ptr @stmt_insert, ptr @SQL_INSERT)

  %tup     = call ptr @shim_slot_copy_heap_tuple(ptr %slot)
  %t_data  = call ptr @shim_heap_tuple_t_data(ptr %tup)
  %t_len   = call i32 @shim_heap_tuple_t_len(ptr %tup)
  %trans   = load ptr, ptr @sqlite_transient
  %brc     = call i32 @sqlite3_bind_blob(ptr %stmt, i32 1, ptr %t_data, i32 %t_len, ptr %trans)
  %src     = call i32 @sqlite3_step(ptr %stmt)
  %done    = icmp eq i32 %src, 101  ; SQLITE_DONE
  br i1 %done, label %ok, label %panic
panic:
  call void @abort()
  unreachable
ok:
  %rowid = call i64 @sqlite3_last_insert_rowid(ptr %db)
  call void @shim_set_inserted_tid(ptr %slot, i32 %rel_oid, i64 %rowid)
  call void @shim_heap_freetuple(ptr %tup)
  ret void
}

; ===========================================================================
; tuple_delete
;   TM_Result tuple_delete(Relation, ItemPointer, CommandId, Snapshot,
;                          Snapshot crosscheck, bool wait,
;                          TM_FailureData *, bool changingPart)
;   TM_Ok = 0
; ===========================================================================
define dso_local i32 @ll_tuple_delete(ptr %rel, ptr %tid, i32 %cid,
                                      ptr %snap, ptr %crosscheck, i8 %wait,
                                      ptr %tmfd, i8 %changingPart) {
  %rel_oid = call i32 @shim_rel_oid(ptr %rel)
  %db      = call ptr @ensure_conn(i32 %rel_oid)
  %stmt    = call ptr @prep_cached(ptr %db, ptr @stmt_delete, ptr @SQL_DELETE)
  %rowid   = call i64 @shim_tid_to_rowid(ptr %tid)
  %brc     = call i32 @sqlite3_bind_int64(ptr %stmt, i32 1, i64 %rowid)
  %src     = call i32 @sqlite3_step(ptr %stmt)
  %done    = icmp eq i32 %src, 101
  br i1 %done, label %ok, label %panic
panic:
  call void @abort()
  unreachable
ok:
  ret i32 0
}

; ===========================================================================
; tuple_update — MVCC-less in-place update keyed by rowid.
;   TM_Result tuple_update(Relation, ItemPointer otid, TupleTableSlot *slot,
;                          CommandId, Snapshot, Snapshot crosscheck, bool wait,
;                          TM_FailureData *, LockTupleMode *, TU_UpdateIndexes *)
; ===========================================================================
define dso_local i32 @ll_tuple_update(ptr %rel, ptr %otid, ptr %slot,
                                      i32 %cid, ptr %snap, ptr %crosscheck,
                                      i8 %wait, ptr %tmfd, ptr %lockmode,
                                      ptr %update_indexes) {
  %rel_oid = call i32 @shim_rel_oid(ptr %rel)
  %db      = call ptr @ensure_conn(i32 %rel_oid)
  %stmt    = call ptr @prep_cached(ptr %db, ptr @stmt_update, ptr @SQL_UPDATE)

  %tup     = call ptr @shim_slot_copy_heap_tuple(ptr %slot)
  %t_data  = call ptr @shim_heap_tuple_t_data(ptr %tup)
  %t_len   = call i32 @shim_heap_tuple_t_len(ptr %tup)
  %rowid   = call i64 @shim_tid_to_rowid(ptr %otid)
  %trans   = load ptr, ptr @sqlite_transient
  %brc1    = call i32 @sqlite3_bind_blob(ptr %stmt, i32 1, ptr %t_data, i32 %t_len, ptr %trans)
  %brc2    = call i32 @sqlite3_bind_int64(ptr %stmt, i32 2, i64 %rowid)
  %src     = call i32 @sqlite3_step(ptr %stmt)
  %done    = icmp eq i32 %src, 101
  br i1 %done, label %ok, label %panic
panic:
  call void @abort()
  unreachable
ok:
  ; rowid stays the same — stamp the slot with the (unchanged) tid.
  call void @shim_set_inserted_tid(ptr %slot, i32 %rel_oid, i64 %rowid)
  call void @shim_heap_freetuple(ptr %tup)
  ; *update_indexes = TU_All  (= 0 means TU_All in PG 18 — yes; for "no
  ;  shortcut" we set to 0)
  store i32 0, ptr %update_indexes
  ret i32 0
}

; ===========================================================================
; tuple_fetch_row_version — fetch by tid for FETCH / EvalPlanQual paths.
; ===========================================================================
define dso_local i8 @ll_tuple_fetch_row_version(ptr %rel, ptr %tid,
                                                ptr %snapshot, ptr %slot) {
entry:
  %rel_oid = call i32 @shim_rel_oid(ptr %rel)
  %db      = call ptr @ensure_conn(i32 %rel_oid)
  %stmt    = call ptr @prep_cached(ptr %db, ptr @stmt_select_one, ptr @SQL_SEL_ON)
  %rowid   = call i64 @shim_tid_to_rowid(ptr %tid)
  %brc     = call i32 @sqlite3_bind_int64(ptr %stmt, i32 1, i64 %rowid)
  %src     = call i32 @sqlite3_step(ptr %stmt)
  %is_row  = icmp eq i32 %src, 100  ; SQLITE_ROW
  br i1 %is_row, label %fill, label %miss
miss:
  call void @shim_slot_clear(ptr %slot)
  ret i8 0
fill:
  %blob = call ptr @sqlite3_column_blob(ptr %stmt, i32 0)
  %len  = call i32 @sqlite3_column_bytes(ptr %stmt, i32 0)
  %tup  = call ptr @shim_build_heap_tuple(i32 %rel_oid, i64 %rowid, ptr %blob, i32 %len)
  call void @shim_slot_store_heap_tuple(ptr %tup, ptr %slot, i8 1)
  ret i8 1
}

; ===========================================================================
; Sequential scan
;
; Scan state layout: [ TableScanDescData (64 bytes) | sqlite3_stmt* ]
; ===========================================================================
define dso_local ptr @ll_scan_begin(ptr %rel, ptr %snapshot, i32 %nkeys,
                                    ptr %key, ptr %pscan, i32 %flags) {
  %state = call ptr @palloc0(i64 72)
  ; rs_rd @ 0
  store ptr %rel, ptr %state
  ; rs_snapshot @ 8
  %p_snap = getelementptr i8, ptr %state, i64 8
  store ptr %snapshot, ptr %p_snap
  ; rs_nkeys @ 16
  %p_nkeys = getelementptr i8, ptr %state, i64 16
  store i32 %nkeys, ptr %p_nkeys
  ; rs_key @ 24
  %p_key = getelementptr i8, ptr %state, i64 24
  store ptr %key, ptr %p_key
  ; rs_flags @ 48
  %p_flags = getelementptr i8, ptr %state, i64 48
  store i32 %flags, ptr %p_flags
  ; rs_parallel @ 56
  %p_pscan = getelementptr i8, ptr %state, i64 56
  store ptr %pscan, ptr %p_pscan

  ; prep the SELECT and stash in our private slot @ 64.
  %rel_oid = call i32 @shim_rel_oid(ptr %rel)
  %db      = call ptr @ensure_conn(i32 %rel_oid)
  %stmt    = call ptr @prep_cached(ptr %db, ptr @stmt_select_all, ptr @SQL_SEL_AL)
  %p_stmt  = getelementptr i8, ptr %state, i64 64
  store ptr %stmt, ptr %p_stmt
  ret ptr %state
}

define dso_local void @ll_scan_end(ptr %state) {
  ; Stmt is cached in the thread-local slot — reset it so the next scan starts
  ; from the top, but don't finalize (cache hit on next call).
  %p_stmt = getelementptr i8, ptr %state, i64 64
  %stmt   = load ptr, ptr %p_stmt
  %is_null = icmp eq ptr %stmt, null
  br i1 %is_null, label %free, label %reset
reset:
  %rc = call i32 @sqlite3_reset(ptr %stmt)
  br label %free
free:
  call void @pfree(ptr %state)
  ret void
}

define dso_local void @ll_scan_rescan(ptr %state, ptr %key, i8 %set_params,
                                       i8 %allow_strat, i8 %allow_sync,
                                       i8 %allow_pagemode) {
  %p_stmt = getelementptr i8, ptr %state, i64 64
  %stmt   = load ptr, ptr %p_stmt
  %is_null = icmp eq ptr %stmt, null
  br i1 %is_null, label %done, label %reset
reset:
  %rc = call i32 @sqlite3_reset(ptr %stmt)
  br label %done
done:
  ret void
}

define dso_local i8 @ll_scan_getnextslot(ptr %state, i32 %direction, ptr %slot) {
  %rel   = load ptr, ptr %state
  %p_stmt = getelementptr i8, ptr %state, i64 64
  %stmt   = load ptr, ptr %p_stmt
  call void @shim_slot_clear(ptr %slot)
  %src = call i32 @sqlite3_step(ptr %stmt)
  %is_row = icmp eq i32 %src, 100
  br i1 %is_row, label %fill, label %eof
eof:
  ret i8 0
fill:
  %rel_oid = call i32 @shim_rel_oid(ptr %rel)
  %rowid   = call i64 @sqlite3_column_int64(ptr %stmt, i32 0)
  %blob    = call ptr @sqlite3_column_blob(ptr %stmt, i32 1)
  %len     = call i32 @sqlite3_column_bytes(ptr %stmt, i32 1)
  %tup     = call ptr @shim_build_heap_tuple(i32 %rel_oid, i64 %rowid, ptr %blob, i32 %len)
  call void @shim_slot_store_heap_tuple(ptr %tup, ptr %slot, i8 1)
  ret i8 1
}

; ===========================================================================
; Index fetch — used by Postgres b-tree index lookups.
;
; IndexFetchTableData layout: { Relation rel; }  (sizeof = 8)
; ===========================================================================
define dso_local ptr @ll_index_fetch_begin(ptr %rel) {
  %p = call ptr @palloc(i64 8)
  store ptr %rel, ptr %p
  ret ptr %p
}

define dso_local void @ll_index_fetch_reset(ptr %data) {
  ret void
}

define dso_local void @ll_index_fetch_end(ptr %data) {
  call void @pfree(ptr %data)
  ret void
}

define dso_local i8 @ll_index_fetch_tuple(ptr %data, ptr %tid, ptr %snapshot,
                                          ptr %slot, ptr %call_again,
                                          ptr %all_dead) {
  ; one-shot: never ask the caller to call again.
  store i8 0, ptr %call_again
  %rel = load ptr, ptr %data
  %ok  = call i8 @ll_tuple_fetch_row_version(ptr %rel, ptr %tid, ptr %snapshot, ptr %slot)
  ret i8 %ok
}

; ===========================================================================
; tuple_satisfies_snapshot — always visible. We're MVCC-free.
; ===========================================================================
define dso_local i8 @ll_tuple_satisfies_snapshot(ptr %rel, ptr %slot, ptr %snapshot) {
  ret i8 1
}

; ===========================================================================
; relation_set_new_filelocator — first call during CREATE TABLE (also TRUNCATE
; with a new file). Postgres has just allocated a fresh RelFileLocator; we
; mirror that by (re-)creating the SQLite file.
;   void relation_set_new_filelocator(Relation, const RelFileLocator *,
;                                     char persistence,
;                                     TransactionId *freezeXid,
;                                     MultiXactId *minMulti)
; ===========================================================================
define dso_local void @ll_relation_set_new_filelocator(ptr %rel, ptr %newlocator,
                                                       i8 %persistence,
                                                       ptr %freezeXid,
                                                       ptr %minMulti) {
  ; freezeXid / minMulti are out-params — set to 0.
  %is_fx_null = icmp eq ptr %freezeXid, null
  br i1 %is_fx_null, label %skip_fx, label %set_fx
set_fx:
  store i32 0, ptr %freezeXid
  br label %skip_fx
skip_fx:
  %is_mm_null = icmp eq ptr %minMulti, null
  br i1 %is_mm_null, label %open, label %set_mm
set_mm:
  store i32 0, ptr %minMulti
  br label %open
open:
  %rel_oid = call i32 @shim_rel_oid(ptr %rel)
  ; Drop the current conn (cache may be stale; the storage file is being
  ; rewritten under us) and unlink the old file.
  call void @drop_conn()
  %db_oid = call i32 @shim_my_database_id()
  %unlink_rc = call i32 @shim_unlink_path(i32 %db_oid, i32 %rel_oid)
  ; Reopen — ensure_conn will create the file and the schema.
  %db = call ptr @ensure_conn(i32 %rel_oid)
  ret void
}

; ===========================================================================
; relation_nontransactional_truncate — DELETE FROM storage.
; ===========================================================================
define dso_local void @ll_relation_nontransactional_truncate(ptr %rel) {
  %rel_oid = call i32 @shim_rel_oid(ptr %rel)
  %db      = call ptr @ensure_conn(i32 %rel_oid)
  %rc      = call i32 @sqlite3_exec(ptr %db, ptr @SQL_TRUNC, ptr null, ptr null, ptr null)
  ret void
}

; ===========================================================================
; Misc planner / catalog hooks
; ===========================================================================
define dso_local i64 @ll_relation_size(ptr %rel, i32 %forknum) {
  %rel_oid = call i32 @shim_rel_oid(ptr %rel)
  %db_oid  = call i32 @shim_my_database_id()
  %sz      = call i64 @shim_file_size(i32 %db_oid, i32 %rel_oid)
  ret i64 %sz
}

define dso_local i8 @ll_relation_needs_toast_table(ptr %rel) {
  ret i8 0
}

; relation_estimate_size(rel, attr_widths, pages, tuples, allvisfrac)
; — fake plausible numbers.
define dso_local void @ll_relation_estimate_size(ptr %rel, ptr %attr_widths,
                                                 ptr %pages, ptr %tuples,
                                                 ptr %allvisfrac) {
  %rel_oid = call i32 @shim_rel_oid(ptr %rel)
  %db_oid  = call i32 @shim_my_database_id()
  %bytes   = call i64 @shim_file_size(i32 %db_oid, i32 %rel_oid)
  ; pages = max(1, bytes / 8192)
  %p_raw   = sdiv i64 %bytes, 8192
  %p_int   = trunc i64 %p_raw to i32
  %p_zero  = icmp eq i32 %p_int, 0
  %p_clamp = select i1 %p_zero, i32 1, i32 %p_int
  store i32 %p_clamp, ptr %pages
  store double 1.0, ptr %allvisfrac
  ; tuples ≈ bytes / 64 (cheap guess for a generic small row)
  %t_raw   = sdiv i64 %bytes, 64
  %t_dbl   = sitofp i64 %t_raw to double
  store double %t_dbl, ptr %tuples
  ret void
}

; ===========================================================================
; index_build_range_scan — CREATE INDEX support.
;   double (*index_build_range_scan)(Relation heap_rel, Relation index_rel,
;                                    IndexInfo *info, bool allow_sync,
;                                    bool anyvisible, bool progress,
;                                    BlockNumber start_blockno,
;                                    BlockNumber numblocks,
;                                    IndexBuildCallback callback, void *cb_state,
;                                    TableScanDesc scan)
;
; Postgres calls this once and we walk the heap with our seqscan path,
; invoking the callback for each visible tuple.
;
; This is the most painful single callback to write in IR because the index
; tuple machinery (FormIndexDatum, slot init) is verbose. For this stunt we
; stub it — Postgres prints an error if CREATE INDEX is attempted but the
; rest of the AM works fine.
; ===========================================================================
define dso_local double @ll_index_build_range_scan(ptr %heap, ptr %index,
                                                   ptr %info, i8 %allow_sync,
                                                   i8 %anyvisible, i8 %progress,
                                                   i32 %start_blockno,
                                                   i32 %numblocks,
                                                   ptr %callback, ptr %state,
                                                   ptr %scan) {
  ret double 0.0
}

; ===========================================================================
; slot_callbacks — every tuple lives as a HeapTuple, so use Postgres's stock
; HeapTuple slot ops.
; ===========================================================================
define dso_local ptr @ll_slot_callbacks(ptr %rel) {
  ret ptr @TTSOpsHeapTuple
}

; ===========================================================================
; Stubs — Postgres's cassert build wants every TableAmRoutine slot non-NULL.
; None of these get called by INSERT / SELECT / UPDATE / DELETE on our AM, so
; they trap if invoked.
; ===========================================================================
define dso_local i64 @ll_parallelscan_estimate(ptr %rel) { ret i64 0 }
define dso_local i64 @ll_parallelscan_initialize(ptr %rel, ptr %p) { ret i64 0 }
define dso_local void @ll_parallelscan_reinitialize(ptr %rel, ptr %p) { ret void }

define dso_local i8 @ll_tuple_tid_valid(ptr %scan, ptr %tid) { ret i8 1 }
define dso_local void @ll_tuple_get_latest_tid(ptr %scan, ptr %tid) { ret void }
define dso_local i32 @ll_index_delete_tuples(ptr %rel, ptr %delstate) { ret i32 0 }

define dso_local void @ll_tuple_insert_speculative(ptr %rel, ptr %slot, i32 %cid,
                                                   i32 %options, ptr %bistate,
                                                   i32 %token) {
  call void @ll_tuple_insert(ptr %rel, ptr %slot, i32 %cid, i32 %options, ptr %bistate)
  ret void
}
define dso_local void @ll_tuple_complete_speculative(ptr %rel, ptr %slot,
                                                     i32 %token, i8 %succeeded) {
  ret void
}

; multi_insert: just loop through ll_tuple_insert. Postgres's COPY uses this.
define dso_local void @ll_multi_insert(ptr %rel, ptr %slots, i32 %nslots,
                                       i32 %cid, i32 %options, ptr %bistate) {
entry:
  %i.slot = alloca i32
  store i32 0, ptr %i.slot
  br label %loop
loop:
  %i = load i32, ptr %i.slot
  %done = icmp sge i32 %i, %nslots
  br i1 %done, label %end, label %body
body:
  %idx = sext i32 %i to i64
  %slot_ptr_ptr = getelementptr ptr, ptr %slots, i64 %idx
  %slot_ptr = load ptr, ptr %slot_ptr_ptr
  call void @ll_tuple_insert(ptr %rel, ptr %slot_ptr, i32 %cid, i32 %options, ptr %bistate)
  %i2 = add i32 %i, 1
  store i32 %i2, ptr %i.slot
  br label %loop
end:
  ret void
}

define dso_local i32 @ll_tuple_lock(ptr %rel, ptr %tid, ptr %snap, ptr %slot,
                                    i32 %cid, i32 %mode, i32 %wait_policy,
                                    i8 %flags, ptr %tmfd) {
  ret i32 0  ; TM_Ok
}

define dso_local void @ll_finish_bulk_insert(ptr %rel, i32 %options) { ret void }
define dso_local void @ll_relation_copy_data(ptr %rel, ptr %newlocator) { ret void }
define dso_local void @ll_relation_copy_for_cluster(ptr %old, ptr %new, ptr %old_index,
                                                    i8 %use_sort, i32 %oxmin, ptr %oxmin_out,
                                                    ptr %fxid_out, ptr %tup_out, ptr %tup_in_out,
                                                    ptr %tlc_out) { ret void }
define dso_local void @ll_relation_vacuum(ptr %rel, ptr %params, ptr %bstrategy) { ret void }
define dso_local i8 @ll_scan_analyze_next_block(ptr %scan, ptr %stream) { ret i8 0 }
define dso_local i8 @ll_scan_analyze_next_tuple(ptr %scan, i32 %oxmin,
                                                 ptr %liverows, ptr %deadrows,
                                                 ptr %slot) { ret i8 0 }
define dso_local void @ll_index_validate_scan(ptr %table, ptr %index, ptr %info,
                                              ptr %snap, ptr %state) { ret void }
define dso_local i8 @ll_scan_sample_next_block(ptr %scan, ptr %scanstate) { ret i8 0 }
define dso_local i8 @ll_scan_sample_next_tuple(ptr %scan, ptr %scanstate, ptr %slot) { ret i8 0 }
define dso_local i8 @ll_scan_bitmap_next_tuple(ptr %scan, ptr %recheck, ptr %slot, ptr %_unused, ptr %_unused2) { ret i8 0 }
