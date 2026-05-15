/*
 * shim.c — minimum C boilerplate the IR side can't easily express on its own.
 *
 * Most of Postgres's executor API is callable via plain `declare` in IR. Two
 * categories aren't: (a) static-inline functions in PG headers (no real
 * symbol to dlsym), and (b) building a 45-field TableAmRoutine constant —
 * doable in IR but ugly. We trampoline those through here.
 *
 * Everything actually interesting (scan/insert/seqscan stepping, the SQLite
 * calls) lives in main.ll.
 */

#include "postgres.h"
#include "access/htup_details.h"
#include "access/tableam.h"
#include "catalog/index.h"
#include "executor/executor.h"
#include "executor/tuptable.h"
#include "miscadmin.h"
#include "storage/itemptr.h"
#include "utils/rel.h"
#include "utils/snapmgr.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

/* ---------- static-inline wrappers --------------------------------------- */

PGDLLEXPORT HeapTuple shim_slot_copy_heap_tuple(TupleTableSlot *slot);
PGDLLEXPORT void      shim_slot_clear(TupleTableSlot *slot);
PGDLLEXPORT void      shim_slot_store_heap_tuple(HeapTuple tup, TupleTableSlot *slot, bool shouldFree);

HeapTuple shim_slot_copy_heap_tuple(TupleTableSlot *slot)
    { return ExecCopySlotHeapTuple(slot); }
void shim_slot_clear(TupleTableSlot *slot)
    { ExecClearTuple(slot); }
void shim_slot_store_heap_tuple(HeapTuple tup, TupleTableSlot *slot, bool shouldFree)
    { ExecStoreHeapTuple(tup, slot, shouldFree); }

/* ---------- relation/slot field accessors -------------------------------- */

PGDLLEXPORT Oid       shim_rel_oid(Relation rel);
PGDLLEXPORT TupleDesc shim_rel_tupdesc(Relation rel);
PGDLLEXPORT Oid       shim_my_database_id(void);
PGDLLEXPORT const char *shim_data_dir(void);

Oid shim_rel_oid(Relation rel)            { return rel->rd_id; }
TupleDesc shim_rel_tupdesc(Relation rel)  { return rel->rd_att; }
Oid shim_my_database_id(void)             { return MyDatabaseId; }
const char *shim_data_dir(void)           { return DataDir; }

/* ---------- HeapTuple construction --------------------------------------- */
/*
 * We store an opaque tuple blob in SQLite. To hand it back to Postgres we
 * rebuild a HeapTuple whose `t_data` points at our bytes — same trick the
 * Rust impl uses (`build_heap_tuple_from_parts`).
 */
PGDLLEXPORT HeapTuple shim_build_heap_tuple(Oid table_oid, int64 rowid,
                                            const void *bytes, uint32 len);

#define LL_TIDS_PER_BLOCK 256

static void rowid_to_tid(int64 rowid, ItemPointerData *tid)
{
    /* rowid is 1-based; pack into (block, offset) so any single value fits
     * inside MaxHeapTuplesPerPage. */
    BlockNumber blk = (BlockNumber)((rowid - 1) / LL_TIDS_PER_BLOCK);
    OffsetNumber off = (OffsetNumber)(((rowid - 1) % LL_TIDS_PER_BLOCK) + 1);
    ItemPointerSet(tid, blk, off);
}

HeapTuple shim_build_heap_tuple(Oid table_oid, int64 rowid,
                                const void *bytes, uint32 len)
{
    /* one palloc, header + data, matching heap_form_tuple's layout so
     * heap_freetuple cleans up correctly. */
    char *raw = (char *)palloc(HEAPTUPLESIZE + len);
    HeapTuple tup = (HeapTuple)raw;
    char *data = raw + HEAPTUPLESIZE;
    memcpy(data, bytes, len);
    tup->t_len = len;
    rowid_to_tid(rowid, &tup->t_self);
    tup->t_tableOid = table_oid;
    tup->t_data = (HeapTupleHeader)data;
    return tup;
}

PGDLLEXPORT void shim_set_inserted_tid(TupleTableSlot *slot, Oid table_oid, int64 rowid);
void shim_set_inserted_tid(TupleTableSlot *slot, Oid table_oid, int64 rowid)
{
    slot->tts_tableOid = table_oid;
    rowid_to_tid(rowid, &slot->tts_tid);
}

PGDLLEXPORT int64 shim_tid_to_rowid(const ItemPointerData *tid);
int64 shim_tid_to_rowid(const ItemPointerData *tid)
{
    BlockNumber blk = ItemPointerGetBlockNumberNoCheck(tid);
    OffsetNumber off = ItemPointerGetOffsetNumberNoCheck(tid);
    return (int64)blk * LL_TIDS_PER_BLOCK + off;
}

/* ---------- HeapTupleData reader helpers --------------------------------- */
/*
 * Used to dig into a palloc'd HeapTuple returned by ExecCopySlotHeapTuple,
 * since spelling out HeapTupleData / HeapTupleHeaderData in IR is painful.
 */
PGDLLEXPORT uint32 shim_heap_tuple_t_len(HeapTuple tup);
PGDLLEXPORT void  *shim_heap_tuple_t_data(HeapTuple tup);
PGDLLEXPORT void   shim_heap_freetuple(HeapTuple tup);

uint32 shim_heap_tuple_t_len(HeapTuple tup) { return tup->t_len; }
void  *shim_heap_tuple_t_data(HeapTuple tup) { return tup->t_data; }
void   shim_heap_freetuple(HeapTuple tup)    { heap_freetuple(tup); }

/* ---------- filesystem helpers ------------------------------------------- */
/*
 * Build "$PGDATA/sqlite_heap_ll/<dboid>/<reloid>.sqlite" into a caller-
 * supplied buffer, mkdir'ing parents. Returns 0 on success.
 */
PGDLLEXPORT int shim_make_path(char *buf, size_t buflen,
                               Oid db_oid, Oid rel_oid);

static int mkdir_p(const char *path)
{
    char tmp[1024];
    size_t len = strlen(path);
    if (len >= sizeof(tmp)) return -1;
    memcpy(tmp, path, len + 1);
    for (size_t i = 1; i < len; i++) {
        if (tmp[i] == '/') {
            tmp[i] = 0;
            if (mkdir(tmp, 0700) != 0 && errno != EEXIST) return -1;
            tmp[i] = '/';
        }
    }
    if (mkdir(tmp, 0700) != 0 && errno != EEXIST) return -1;
    return 0;
}

int shim_make_path(char *buf, size_t buflen, Oid db_oid, Oid rel_oid)
{
    char dir[1024];
    int n = snprintf(dir, sizeof(dir),
                     "%s/sqlite_heap_ll/%u", DataDir, db_oid);
    if (n < 0 || (size_t)n >= sizeof(dir)) return -1;
    if (mkdir_p(dir) != 0) return -1;
    n = snprintf(buf, buflen, "%s/%u.sqlite", dir, rel_oid);
    if (n < 0 || (size_t)n >= buflen) return -1;
    return 0;
}

PGDLLEXPORT int shim_unlink_path(Oid db_oid, Oid rel_oid);
int shim_unlink_path(Oid db_oid, Oid rel_oid)
{
    char path[1024];
    if (shim_make_path(path, sizeof(path), db_oid, rel_oid) != 0) return -1;
    (void)unlink(path);
    /* WAL/SHM siblings */
    char buf[1280];
    snprintf(buf, sizeof(buf), "%s-wal", path); unlink(buf);
    snprintf(buf, sizeof(buf), "%s-shm", path); unlink(buf);
    return 0;
}

PGDLLEXPORT int64 shim_file_size(Oid db_oid, Oid rel_oid);
int64 shim_file_size(Oid db_oid, Oid rel_oid)
{
    char path[1024];
    if (shim_make_path(path, sizeof(path), db_oid, rel_oid) != 0) return 0;
    struct stat st;
    if (stat(path, &st) != 0) return 0;
    return (int64)st.st_size;
}

/* ---------- TableAmRoutine table ----------------------------------------- */
/*
 * Builds the 45-slot TableAmRoutine the SQL handler returns. Each slot is an
 * IR-side function pointer, passed in from main.ll's `ll_install_routine`.
 *
 * Doing this here keeps the IR free of the 45-field constant initializer.
 */

/* Forward decls for the IR-defined callbacks. */
extern const TupleTableSlotOps *ll_slot_callbacks(Relation);
extern TableScanDesc ll_scan_begin(Relation, Snapshot, int, struct ScanKeyData *,
                                   ParallelTableScanDesc, uint32);
extern void          ll_scan_end(TableScanDesc);
extern void          ll_scan_rescan(TableScanDesc, struct ScanKeyData *,
                                    bool, bool, bool, bool);
extern bool          ll_scan_getnextslot(TableScanDesc, ScanDirection, TupleTableSlot *);
extern void          ll_tuple_insert(Relation, TupleTableSlot *, CommandId, int,
                                     struct BulkInsertStateData *);
extern bool          ll_tuple_fetch_row_version(Relation, ItemPointer, Snapshot,
                                                TupleTableSlot *);
extern TM_Result     ll_tuple_delete(Relation, ItemPointer, CommandId, Snapshot,
                                     Snapshot, bool, struct TM_FailureData *, bool);
extern TM_Result     ll_tuple_update(Relation, ItemPointer, TupleTableSlot *,
                                     CommandId, Snapshot, Snapshot, bool,
                                     struct TM_FailureData *, LockTupleMode *, TU_UpdateIndexes *);
extern void          ll_relation_set_new_filelocator(Relation, const RelFileLocator *,
                                                     char, TransactionId *, MultiXactId *);
extern void          ll_relation_nontransactional_truncate(Relation);
extern uint64        ll_relation_size(Relation, ForkNumber);
extern bool          ll_relation_needs_toast_table(Relation);
extern void          ll_relation_estimate_size(Relation, int32 *, BlockNumber *,
                                               double *, double *);
extern void          ll_index_fetch_reset(struct IndexFetchTableData *);
extern void          ll_index_fetch_end(struct IndexFetchTableData *);
extern struct IndexFetchTableData *ll_index_fetch_begin(Relation);
extern bool          ll_index_fetch_tuple(struct IndexFetchTableData *, ItemPointer,
                                          Snapshot, TupleTableSlot *, bool *, bool *);
extern double        ll_index_build_range_scan(Relation, Relation, struct IndexInfo *,
                                               bool, bool, bool, BlockNumber, BlockNumber,
                                               IndexBuildCallback, void *,
                                               TableScanDesc);
extern bool          ll_tuple_satisfies_snapshot(Relation, TupleTableSlot *, Snapshot);
extern Size          ll_parallelscan_estimate(Relation);
extern Size          ll_parallelscan_initialize(Relation, ParallelTableScanDesc);
extern void          ll_parallelscan_reinitialize(Relation, ParallelTableScanDesc);
extern bool          ll_tuple_tid_valid(TableScanDesc, ItemPointer);
extern void          ll_tuple_get_latest_tid(TableScanDesc, ItemPointer);
extern TransactionId ll_index_delete_tuples(Relation, TM_IndexDeleteOp *);
extern void          ll_tuple_insert_speculative(Relation, TupleTableSlot *, CommandId,
                                                 int, struct BulkInsertStateData *, uint32);
extern void          ll_tuple_complete_speculative(Relation, TupleTableSlot *, uint32, bool);
extern void          ll_multi_insert(Relation, TupleTableSlot **, int, CommandId, int,
                                     struct BulkInsertStateData *);
extern TM_Result     ll_tuple_lock(Relation, ItemPointer, Snapshot, TupleTableSlot *,
                                   CommandId, LockTupleMode, LockWaitPolicy, uint8,
                                   struct TM_FailureData *);
extern void          ll_finish_bulk_insert(Relation, int);
extern void          ll_relation_copy_data(Relation, const RelFileLocator *);
extern void          ll_relation_copy_for_cluster(Relation, Relation, Relation, bool,
                                                  TransactionId, TransactionId *,
                                                  MultiXactId *, double *, double *,
                                                  double *);
extern void          ll_relation_vacuum(Relation, struct VacuumParams *,
                                        BufferAccessStrategy);
extern bool          ll_scan_analyze_next_block(TableScanDesc, ReadStream *);
extern bool          ll_scan_analyze_next_tuple(TableScanDesc, TransactionId,
                                                double *, double *, TupleTableSlot *);
extern void          ll_index_validate_scan(Relation, Relation, struct IndexInfo *,
                                            Snapshot, struct ValidateIndexState *);
extern bool          ll_scan_sample_next_block(TableScanDesc, struct SampleScanState *);
extern bool          ll_scan_sample_next_tuple(TableScanDesc, struct SampleScanState *,
                                               TupleTableSlot *);
extern bool          ll_scan_bitmap_next_tuple(TableScanDesc, TupleTableSlot *,
                                               bool *, uint64 *, uint64 *);

static const TableAmRoutine ll_routine = {
    .type                            = T_TableAmRoutine,
    .slot_callbacks                  = ll_slot_callbacks,
    .scan_begin                      = ll_scan_begin,
    .scan_end                        = ll_scan_end,
    .scan_rescan                     = ll_scan_rescan,
    .scan_getnextslot                = ll_scan_getnextslot,
    .parallelscan_estimate           = ll_parallelscan_estimate,
    .parallelscan_initialize         = ll_parallelscan_initialize,
    .parallelscan_reinitialize       = ll_parallelscan_reinitialize,
    .index_fetch_begin               = ll_index_fetch_begin,
    .index_fetch_reset               = ll_index_fetch_reset,
    .index_fetch_end                 = ll_index_fetch_end,
    .index_fetch_tuple               = ll_index_fetch_tuple,
    .tuple_fetch_row_version         = ll_tuple_fetch_row_version,
    .tuple_tid_valid                 = ll_tuple_tid_valid,
    .tuple_get_latest_tid            = ll_tuple_get_latest_tid,
    .tuple_satisfies_snapshot        = ll_tuple_satisfies_snapshot,
    .index_delete_tuples             = ll_index_delete_tuples,
    .tuple_insert                    = ll_tuple_insert,
    .tuple_insert_speculative        = ll_tuple_insert_speculative,
    .tuple_complete_speculative      = ll_tuple_complete_speculative,
    .multi_insert                    = ll_multi_insert,
    .tuple_delete                    = ll_tuple_delete,
    .tuple_update                    = ll_tuple_update,
    .tuple_lock                      = ll_tuple_lock,
    .finish_bulk_insert              = ll_finish_bulk_insert,
    .relation_set_new_filelocator    = ll_relation_set_new_filelocator,
    .relation_nontransactional_truncate = ll_relation_nontransactional_truncate,
    .relation_copy_data              = ll_relation_copy_data,
    .relation_copy_for_cluster       = ll_relation_copy_for_cluster,
    .relation_vacuum                 = ll_relation_vacuum,
    .scan_analyze_next_block         = ll_scan_analyze_next_block,
    .scan_analyze_next_tuple         = ll_scan_analyze_next_tuple,
    .index_build_range_scan          = ll_index_build_range_scan,
    .index_validate_scan             = ll_index_validate_scan,
    .relation_size                   = ll_relation_size,
    .relation_needs_toast_table      = ll_relation_needs_toast_table,
    .relation_estimate_size          = ll_relation_estimate_size,
    .scan_bitmap_next_tuple          = ll_scan_bitmap_next_tuple,
    .scan_sample_next_block          = ll_scan_sample_next_block,
    .scan_sample_next_tuple          = ll_scan_sample_next_tuple,
};

PGDLLEXPORT const TableAmRoutine *shim_get_routine(void);
const TableAmRoutine *shim_get_routine(void) { return &ll_routine; }

/* ---------- index_build_range_scan --------------------------------------- */
/*
 * Walk the heap via the IR-defined scan_* callbacks, hand each tuple to the
 * index AM's callback. Mirrors heap_handler.c's heapam_index_build_range_scan
 * for the simple (non-concurrent, no-blockwise) case our smoke test hits.
 */
PGDLLEXPORT double shim_index_build_range_scan(
    Relation heap, Relation index, IndexInfo *info,
    bool allow_sync, bool anyvisible, bool progress,
    BlockNumber start_blockno, BlockNumber numblocks,
    IndexBuildCallback cb, void *state, TableScanDesc scan);

double shim_index_build_range_scan(
    Relation heap, Relation index, IndexInfo *info,
    bool allow_sync, bool anyvisible, bool progress,
    BlockNumber start_blockno, BlockNumber numblocks,
    IndexBuildCallback cb, void *state, TableScanDesc scan)
{
    bool need_unregister = false;
    Snapshot snapshot;

    if (scan == NULL) {
        snapshot = RegisterSnapshot(GetTransactionSnapshot());
        need_unregister = true;
        scan = table_beginscan_strat(heap, snapshot, 0, NULL, true, allow_sync);
    } else {
        snapshot = scan->rs_snapshot;
    }

    EState *estate = CreateExecutorState();
    ExprContext *econtext = GetPerTupleExprContext(estate);
    TupleTableSlot *slot = table_slot_create(heap, NULL);
    econtext->ecxt_scantuple = slot;

    Datum values[INDEX_MAX_KEYS];
    bool  isnull[INDEX_MAX_KEYS];
    double n = 0;

    while (table_scan_getnextslot(scan, ForwardScanDirection, slot)) {
        ResetPerTupleExprContext(estate);
        FormIndexDatum(info, slot, estate, values, isnull);
        cb(index, &slot->tts_tid, values, isnull, true, state);
        n++;
    }

    table_endscan(scan);
    if (need_unregister) UnregisterSnapshot(snapshot);
    ExecDropSingleTupleTableSlot(slot);
    FreeExecutorState(estate);
    return n;
}
