/*
 * C shim implementation -- see shim.h for the rationale.
 *
 * This file includes the real PostgreSQL headers and owns:
 *   - the module magic block and the v1 finfo records,
 *   - the TableAmRoutine dispatch table + the handler,
 *   - every wrapper that touches a PostgreSQL struct layout or macro.
 *
 * The table-AM callback bodies (zig_*) and the inspection-function bodies
 * are exported from Zig.
 */
#include "postgres.h"
#include "fmgr.h"
#include "miscadmin.h"
#include "funcapi.h"
#include "access/tableam.h"
#include "access/relscan.h"
#include "access/heapam.h"
#include "access/htup_details.h"
#include "access/xact.h"
#include "access/skey.h"
#include "access/genam.h"
#include "catalog/index.h"
#include "commands/vacuum.h"
#include "executor/executor.h"
#include "executor/tuptable.h"
#include "nodes/execnodes.h"
#include "nodes/tidbitmap.h"
#include "storage/block.h"
#include "storage/itemptr.h"
#include "storage/off.h"
#include "storage/procarray.h"
#include "storage/read_stream.h"
#include "utils/builtins.h"
#include "utils/rel.h"
#include "utils/snapmgr.h"
#include "utils/snapshot.h"
#include "utils/tuplestore.h"

#include <sys/stat.h>
#include <dirent.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>

#include "shim.h"

PG_MODULE_MAGIC;

/* ========================================================================
 * Table-AM callbacks: bodies live in Zig, exported with the C ABI.
 * ======================================================================== */

extern const TupleTableSlotOps *zig_slot_callbacks(Relation rel);

extern TableScanDesc zig_scan_begin(Relation rel, Snapshot snapshot, int nkeys,
									struct ScanKeyData *key,
									ParallelTableScanDesc pscan, uint32 flags);
extern void zig_scan_end(TableScanDesc scan);
extern void zig_scan_rescan(TableScanDesc scan, struct ScanKeyData *key,
							bool set_params, bool allow_strat,
							bool allow_sync, bool allow_pagemode);
extern bool zig_scan_getnextslot(TableScanDesc scan, ScanDirection direction,
								 TupleTableSlot *slot);
extern void zig_scan_set_tidrange(TableScanDesc scan, ItemPointer mintid,
								  ItemPointer maxtid);
extern bool zig_scan_getnextslot_tidrange(TableScanDesc scan,
										  ScanDirection direction,
										  TupleTableSlot *slot);

extern Size zig_parallelscan_estimate(Relation rel);
extern Size zig_parallelscan_initialize(Relation rel, ParallelTableScanDesc pscan);
extern void zig_parallelscan_reinitialize(Relation rel, ParallelTableScanDesc pscan);

extern IndexFetchTableData *zig_index_fetch_begin(Relation rel);
extern void zig_index_fetch_reset(IndexFetchTableData *data);
extern void zig_index_fetch_end(IndexFetchTableData *data);
extern bool zig_index_fetch_tuple(IndexFetchTableData *scan, ItemPointer tid,
								  Snapshot snapshot, TupleTableSlot *slot,
								  bool *call_again, bool *all_dead);

extern bool zig_tuple_fetch_row_version(Relation rel, ItemPointer tid,
										Snapshot snapshot, TupleTableSlot *slot);
extern bool zig_tuple_tid_valid(TableScanDesc scan, ItemPointer tid);
extern void zig_tuple_get_latest_tid(TableScanDesc scan, ItemPointer tid);
extern bool zig_tuple_satisfies_snapshot(Relation rel, TupleTableSlot *slot,
										 Snapshot snapshot);
extern TransactionId zig_index_delete_tuples(Relation rel, TM_IndexDeleteOp *delstate);

extern void zig_tuple_insert(Relation rel, TupleTableSlot *slot, CommandId cid,
							 int options, struct BulkInsertStateData *bistate);
extern void zig_tuple_insert_speculative(Relation rel, TupleTableSlot *slot,
										 CommandId cid, int options,
										 struct BulkInsertStateData *bistate,
										 uint32 spec_token);
extern void zig_tuple_complete_speculative(Relation rel, TupleTableSlot *slot,
										   uint32 spec_token, bool succeeded);
extern void zig_multi_insert(Relation rel, TupleTableSlot **slots, int nslots,
							 CommandId cid, int options,
							 struct BulkInsertStateData *bistate);
extern TM_Result zig_tuple_delete(Relation rel, ItemPointer tid, CommandId cid,
								  Snapshot snapshot, Snapshot crosscheck,
								  bool wait, TM_FailureData *tmfd,
								  bool changing_part);
extern TM_Result zig_tuple_update(Relation rel, ItemPointer otid,
								  TupleTableSlot *slot, CommandId cid,
								  Snapshot snapshot, Snapshot crosscheck,
								  bool wait, TM_FailureData *tmfd,
								  LockTupleMode *lockmode,
								  TU_UpdateIndexes *update_indexes);
extern TM_Result zig_tuple_lock(Relation rel, ItemPointer tid, Snapshot snapshot,
								TupleTableSlot *slot, CommandId cid,
								LockTupleMode mode, LockWaitPolicy wait_policy,
								uint8 flags, TM_FailureData *tmfd);
extern void zig_finish_bulk_insert(Relation rel, int options);

extern void zig_relation_set_new_filelocator(Relation rel,
											 const RelFileLocator *newrlocator,
											 char persistence,
											 TransactionId *freeze_xid,
											 MultiXactId *minmulti);
extern void zig_relation_nontransactional_truncate(Relation rel);
extern void zig_relation_copy_data(Relation rel, const RelFileLocator *newrlocator);
extern void zig_relation_copy_for_cluster(Relation old_table, Relation new_table,
										  Relation old_index, bool use_sort,
										  TransactionId oldest_xmin,
										  TransactionId *xid_cutoff,
										  MultiXactId *multi_cutoff,
										  double *num_tuples,
										  double *tups_vacuumed,
										  double *tups_recently_dead);
extern void zig_relation_vacuum(Relation rel, struct VacuumParams *params,
								BufferAccessStrategy bstrategy);
extern bool zig_scan_analyze_next_block(TableScanDesc scan, ReadStream *stream);
extern bool zig_scan_analyze_next_tuple(TableScanDesc scan,
										TransactionId oldest_xmin,
										double *liverows, double *deadrows,
										TupleTableSlot *slot);
extern double zig_index_build_range_scan(Relation table_rel, Relation index_rel,
										 struct IndexInfo *index_info,
										 bool allow_sync, bool anyvisible,
										 bool progress,
										 BlockNumber start_blockno,
										 BlockNumber numblocks,
										 IndexBuildCallback callback,
										 void *callback_state,
										 TableScanDesc scan);
extern void zig_index_validate_scan(Relation table_rel, Relation index_rel,
									struct IndexInfo *index_info,
									Snapshot snapshot,
									struct ValidateIndexState *state);

extern uint64 zig_relation_size(Relation rel, ForkNumber fork);
extern bool zig_relation_needs_toast_table(Relation rel);
extern Oid zig_relation_toast_am(Relation rel);
extern void zig_relation_fetch_toast_slice(Relation toastrel, Oid valueid,
										   int32 attrsize, int32 sliceoffset,
										   int32 slicelength,
										   struct varlena *result);
extern void zig_relation_estimate_size(Relation rel, int32 *attr_widths,
									   BlockNumber *pages, double *tuples,
									   double *allvisfrac);

extern bool zig_scan_bitmap_next_tuple(TableScanDesc scan, TupleTableSlot *slot,
									   bool *recheck, uint64 *lossy_pages,
									   uint64 *exact_pages);
extern bool zig_scan_sample_next_block(TableScanDesc scan,
									   struct SampleScanState *scanstate);
extern bool zig_scan_sample_next_tuple(TableScanDesc scan,
									   struct SampleScanState *scanstate,
									   TupleTableSlot *slot);

static const TableAmRoutine sqlite_heap_zig_methods = {
	.type = T_TableAmRoutine,

	.slot_callbacks = zig_slot_callbacks,

	.scan_begin = zig_scan_begin,
	.scan_end = zig_scan_end,
	.scan_rescan = zig_scan_rescan,
	.scan_getnextslot = zig_scan_getnextslot,
	.scan_set_tidrange = zig_scan_set_tidrange,
	.scan_getnextslot_tidrange = zig_scan_getnextslot_tidrange,

	.parallelscan_estimate = zig_parallelscan_estimate,
	.parallelscan_initialize = zig_parallelscan_initialize,
	.parallelscan_reinitialize = zig_parallelscan_reinitialize,

	.index_fetch_begin = zig_index_fetch_begin,
	.index_fetch_reset = zig_index_fetch_reset,
	.index_fetch_end = zig_index_fetch_end,
	.index_fetch_tuple = zig_index_fetch_tuple,

	.tuple_fetch_row_version = zig_tuple_fetch_row_version,
	.tuple_tid_valid = zig_tuple_tid_valid,
	.tuple_get_latest_tid = zig_tuple_get_latest_tid,
	.tuple_satisfies_snapshot = zig_tuple_satisfies_snapshot,
	.index_delete_tuples = zig_index_delete_tuples,

	.tuple_insert = zig_tuple_insert,
	.tuple_insert_speculative = zig_tuple_insert_speculative,
	.tuple_complete_speculative = zig_tuple_complete_speculative,
	.multi_insert = zig_multi_insert,
	.tuple_delete = zig_tuple_delete,
	.tuple_update = zig_tuple_update,
	.tuple_lock = zig_tuple_lock,
	.finish_bulk_insert = zig_finish_bulk_insert,

	.relation_set_new_filelocator = zig_relation_set_new_filelocator,
	.relation_nontransactional_truncate = zig_relation_nontransactional_truncate,
	.relation_copy_data = zig_relation_copy_data,
	.relation_copy_for_cluster = zig_relation_copy_for_cluster,
	.relation_vacuum = zig_relation_vacuum,
	.scan_analyze_next_block = zig_scan_analyze_next_block,
	.scan_analyze_next_tuple = zig_scan_analyze_next_tuple,
	.index_build_range_scan = zig_index_build_range_scan,
	.index_validate_scan = zig_index_validate_scan,

	.relation_size = zig_relation_size,
	.relation_needs_toast_table = zig_relation_needs_toast_table,
	.relation_toast_am = zig_relation_toast_am,
	.relation_fetch_toast_slice = zig_relation_fetch_toast_slice,
	.relation_estimate_size = zig_relation_estimate_size,

	.scan_bitmap_next_tuple = zig_scan_bitmap_next_tuple,
	.scan_sample_next_block = zig_scan_sample_next_block,
	.scan_sample_next_tuple = zig_scan_sample_next_tuple,
};

/* The handler + its finfo record. */
PG_FUNCTION_INFO_V1(sqlite_heap_zig_handler);

Datum
sqlite_heap_zig_handler(PG_FUNCTION_ARGS)
{
	PG_RETURN_POINTER(&sqlite_heap_zig_methods);
}

/* Inspection-function finfo records; bodies are exported from Zig. */
PG_FUNCTION_INFO_V1(sqlite_heap_zig_file_path);
PG_FUNCTION_INFO_V1(sqlite_heap_zig_file_size);
PG_FUNCTION_INFO_V1(sqlite_heap_zig_schema_version);
PG_FUNCTION_INFO_V1(sqlite_heap_zig_physical_rows);
PG_FUNCTION_INFO_V1(sqlite_heap_zig_live_rows);
PG_FUNCTION_INFO_V1(sqlite_heap_zig_storage);
PG_FUNCTION_INFO_V1(sqlite_heap_zig_files);
PG_FUNCTION_INFO_V1(sqlite_heap_zig_drop_storage);

/* ========================================================================
 * errors
 * ======================================================================== */

void
shim_ereport_error(const char *msg)
{
	ereport(ERROR, (errmsg("%s", msg)));
	pg_unreachable();
}

void
shim_ereport_warning(const char *msg)
{
	ereport(WARNING, (errmsg("%s", msg)));
}

/* ========================================================================
 * backend globals
 * ======================================================================== */

const char *
shim_data_dir(void)
{
	return DataDir;
}

ShimOid
shim_my_database_id(void)
{
	return (ShimOid) MyDatabaseId;
}

/* ========================================================================
 * filesystem
 * ======================================================================== */

int
shim_mkdir_p(const char *path)
{
	char		buf[MAXPGPATH];
	size_t		len = strlen(path);

	if (len == 0 || len >= sizeof(buf))
		return -1;
	memcpy(buf, path, len + 1);

	for (char *p = buf + 1; *p; p++)
	{
		if (*p != '/')
			continue;
		*p = '\0';
		if (mkdir(buf, 0700) != 0 && errno != EEXIST)
			return -1;
		*p = '/';
	}
	if (mkdir(buf, 0700) != 0 && errno != EEXIST)
		return -1;
	return 0;
}

int64_t
shim_file_size(const char *path)
{
	struct stat st;

	if (stat(path, &st) != 0)
		return 0;
	return (int64_t) st.st_size;
}

void
shim_unlink(const char *path)
{
	(void) unlink(path);
}

void
shim_list_dir(const char *path, void (*cb) (void *ctx, const char *name), void *ctx)
{
	DIR		   *dir = opendir(path);
	struct dirent *entry;

	if (dir == NULL)
		return;
	while ((entry = readdir(dir)) != NULL)
		cb(ctx, entry->d_name);
	closedir(dir);
}

/* ========================================================================
 * transaction callbacks
 * ======================================================================== */

static void
xact_trampoline(XactEvent event, void *arg)
{
	if (event == XACT_EVENT_PRE_COMMIT)
		zig_on_precommit();
	else if (event == XACT_EVENT_COMMIT)
		zig_on_commit();
	else if (event == XACT_EVENT_ABORT)
		zig_on_abort();
}

static void
subxact_trampoline(SubXactEvent event, SubTransactionId my_subid,
				   SubTransactionId parent_subid, void *arg)
{
	if (event == SUBXACT_EVENT_START_SUB)
		zig_on_sub_start((ShimSubXid) my_subid);
	else if (event == SUBXACT_EVENT_COMMIT_SUB)
		zig_on_sub_commit((ShimSubXid) my_subid);
	else if (event == SUBXACT_EVENT_ABORT_SUB)
		zig_on_sub_abort((ShimSubXid) my_subid);
}

void
shim_register_xact_callbacks(void)
{
	RegisterXactCallback(xact_trampoline, NULL);
	RegisterSubXactCallback(subxact_trampoline, NULL);
}

/* ========================================================================
 * transaction id helpers
 * ======================================================================== */

ShimXid
shim_current_xid(void)
{
	return (ShimXid) GetCurrentTransactionId();
}

ShimCid
shim_current_cid(bool used)
{
	return (ShimCid) GetCurrentCommandId(used);
}

ShimXid
shim_oldest_non_removable_xid(ShimRelation rel)
{
	return (ShimXid) GetOldestNonRemovableTransactionId((Relation) rel);
}

bool
shim_xid_did_commit(ShimXid xid)
{
	if (xid == InvalidTransactionId)
		return false;
	return TransactionIdDidCommit((TransactionId) xid);
}

bool
shim_xid_is_current(ShimXid xid)
{
	return TransactionIdIsCurrentTransactionId((TransactionId) xid);
}

bool
shim_xid_in_progress(ShimXid xid)
{
	return TransactionIdIsInProgress((TransactionId) xid);
}

bool
shim_xid_precedes(ShimXid a, ShimXid b)
{
	return TransactionIdPrecedes((TransactionId) a, (TransactionId) b);
}

bool
shim_xid_follows(ShimXid a, ShimXid b)
{
	return TransactionIdFollows((TransactionId) a, (TransactionId) b);
}

/* ========================================================================
 * relation
 * ======================================================================== */

ShimOid
shim_rel_oid(ShimRelation rel)
{
	return (ShimOid) (((Relation) rel)->rd_id);
}

ShimTupleDesc
shim_rel_tupdesc(ShimRelation rel)
{
	return (ShimTupleDesc) RelationGetDescr((Relation) rel);
}

/* ========================================================================
 * slots
 * ======================================================================== */

void
shim_slot_clear(ShimSlot slot)
{
	ExecClearTuple((TupleTableSlot *) slot);
}

void
shim_slot_store_tuple(ShimSlot slot, ShimHeapTuple tup)
{
	ExecStoreHeapTuple((HeapTuple) tup, (TupleTableSlot *) slot, true);
}

ShimHeapTuple
shim_slot_copy_heaptuple(ShimSlot slot)
{
	return (ShimHeapTuple) ExecCopySlotHeapTuple((TupleTableSlot *) slot);
}

void
shim_slot_set_tid(ShimSlot slot, ShimOid table_oid, ShimBlockNumber blk,
				  ShimOffsetNumber off)
{
	TupleTableSlot *s = (TupleTableSlot *) slot;

	s->tts_tableOid = (Oid) table_oid;
	ItemPointerSet(&s->tts_tid, (BlockNumber) blk, (OffsetNumber) off);
}

void
shim_slot_get_tid(ShimSlot slot, ShimBlockNumber *blk, ShimOffsetNumber *off)
{
	TupleTableSlot *s = (TupleTableSlot *) slot;

	*blk = (ShimBlockNumber) ItemPointerGetBlockNumberNoCheck(&s->tts_tid);
	*off = (ShimOffsetNumber) ItemPointerGetOffsetNumberNoCheck(&s->tts_tid);
}

/* ========================================================================
 * item pointers
 * ======================================================================== */

ShimBlockNumber
shim_itemptr_block(ShimItemPointer p)
{
	return (ShimBlockNumber) ItemPointerGetBlockNumberNoCheck((ItemPointer) p);
}

ShimOffsetNumber
shim_itemptr_offset(ShimItemPointer p)
{
	return (ShimOffsetNumber) ItemPointerGetOffsetNumberNoCheck((ItemPointer) p);
}

/* ========================================================================
 * heap tuples
 * ======================================================================== */

ShimHeapTuple
shim_build_heap_tuple(ShimOid table_oid, ShimBlockNumber blk, ShimOffsetNumber off,
					  const void *bytes, uint32_t len,
					  ShimXid xmin, ShimXid xmax, ShimCid cid)
{
	HeapTuple	tup = (HeapTuple) palloc(HEAPTUPLESIZE + len);

	tup->t_len = len;
	ItemPointerSet(&tup->t_self, (BlockNumber) blk, (OffsetNumber) off);
	tup->t_tableOid = (Oid) table_oid;
	tup->t_data = (HeapTupleHeader) ((char *) tup + HEAPTUPLESIZE);
	memcpy(tup->t_data, bytes, len);

	/*
	 * Overlay the MVCC header. Writing the union fields directly mirrors what
	 * the stored blob already encodes and sidesteps the combo-cid assertions,
	 * exactly like the Rust port.
	 */
	tup->t_data->t_choice.t_heap.t_xmin = (TransactionId) xmin;
	tup->t_data->t_choice.t_heap.t_xmax = (TransactionId) xmax;
	tup->t_data->t_choice.t_heap.t_field3.t_cid = (CommandId) cid;

	return (ShimHeapTuple) tup;
}

const void *
shim_heaptuple_bytes(ShimHeapTuple tup, uint32_t *len)
{
	HeapTuple	t = (HeapTuple) tup;

	*len = t->t_len;
	return t->t_data;
}

void
shim_heap_freetuple(ShimHeapTuple tup)
{
	heap_freetuple((HeapTuple) tup);
}

/* ========================================================================
 * snapshots
 * ======================================================================== */

int
shim_snapshot_type(ShimSnapshot snap)
{
	return (int) ((Snapshot) snap)->snapshot_type;
}

ShimXid
shim_snap_xmin(ShimSnapshot snap)
{
	return (ShimXid) ((Snapshot) snap)->xmin;
}

ShimXid
shim_snap_xmax(ShimSnapshot snap)
{
	return (ShimXid) ((Snapshot) snap)->xmax;
}

ShimCid
shim_snap_curcid(ShimSnapshot snap)
{
	return (ShimCid) ((Snapshot) snap)->curcid;
}

uint32_t
shim_snap_xcnt(ShimSnapshot snap)
{
	return (uint32_t) ((Snapshot) snap)->xcnt;
}

ShimXid
shim_snap_xip(ShimSnapshot snap, uint32_t i)
{
	return (ShimXid) ((Snapshot) snap)->xip[i];
}

void
shim_snap_reset_dirty_out(ShimSnapshot snap)
{
	Snapshot	s = (Snapshot) snap;

	s->xmin = InvalidTransactionId;
	s->xmax = InvalidTransactionId;
	s->speculativeToken = 0;
}

void
shim_snap_set_xmin(ShimSnapshot snap, ShimXid xid)
{
	((Snapshot) snap)->xmin = (TransactionId) xid;
}

void
shim_snap_set_xmax(ShimSnapshot snap, ShimXid xid)
{
	((Snapshot) snap)->xmax = (TransactionId) xid;
}

/* ========================================================================
 * scan descriptor
 * ======================================================================== */

typedef struct ShimScanState
{
	TableScanDescData rs_base;
	void	   *cursor;			/* Zig-owned iteration state */
} ShimScanState;

ShimScan
shim_scan_alloc(ShimRelation rel, ShimSnapshot snapshot, int nkeys, void *key,
				ShimParallelScan pscan, uint32_t flags, void *cursor)
{
	ShimScanState *s = (ShimScanState *) palloc0(sizeof(ShimScanState));

	s->rs_base.rs_rd = (Relation) rel;
	s->rs_base.rs_snapshot = (Snapshot) snapshot;
	s->rs_base.rs_nkeys = nkeys;
	s->rs_base.rs_key = (struct ScanKeyData *) key;
	s->rs_base.rs_flags = flags;
	s->rs_base.rs_parallel = (ParallelTableScanDesc) pscan;
	s->cursor = cursor;
	return (ShimScan) s;
}

void *
shim_scan_cursor(ShimScan scan)
{
	return ((ShimScanState *) scan)->cursor;
}

void
shim_scan_free(ShimScan scan)
{
	pfree(scan);
}

ShimRelation
shim_scan_rel(ShimScan scan)
{
	return (ShimRelation) ((ShimScanState *) scan)->rs_base.rs_rd;
}

ShimSnapshot
shim_scan_snapshot(ShimScan scan)
{
	return (ShimSnapshot) ((ShimScanState *) scan)->rs_base.rs_snapshot;
}

void
shim_scan_set_tidrange(ShimScan scan, ShimItemPointer mintid, ShimItemPointer maxtid)
{
	ShimScanState *s = (ShimScanState *) scan;

	s->rs_base.st.tidrange.rs_mintid = *(ItemPointer) mintid;
	s->rs_base.st.tidrange.rs_maxtid = *(ItemPointer) maxtid;
}

void
shim_scan_get_tidrange(ShimScan scan, ShimBlockNumber *min_blk,
					   ShimOffsetNumber *min_off, ShimBlockNumber *max_blk,
					   ShimOffsetNumber *max_off)
{
	ShimScanState *s = (ShimScanState *) scan;
	ItemPointer min = &s->rs_base.st.tidrange.rs_mintid;
	ItemPointer max = &s->rs_base.st.tidrange.rs_maxtid;

	*min_blk = (ShimBlockNumber) ItemPointerGetBlockNumberNoCheck(min);
	*min_off = (ShimOffsetNumber) ItemPointerGetOffsetNumberNoCheck(min);
	*max_blk = (ShimBlockNumber) ItemPointerGetBlockNumberNoCheck(max);
	*max_off = (ShimOffsetNumber) ItemPointerGetOffsetNumberNoCheck(max);
}

bool
shim_tbm_next(ShimScan scan, ShimTbmPage *out)
{
	ShimScanState *s = (ShimScanState *) scan;
	TBMIterateResult tbmres;

	if (!tbm_iterate(&s->rs_base.st.rs_tbmiterator, &tbmres))
		return false;

	out->blockno = (ShimBlockNumber) tbmres.blockno;
	out->recheck = tbmres.recheck;
	out->lossy = tbmres.lossy;
	if (tbmres.lossy)
		out->noffsets = 0;
	else
		out->noffsets = tbm_extract_page_tuple(&tbmres, out->offsets,
											   SHIM_MAX_OFFSETS);
	return true;
}

/* ========================================================================
 * analyze / sample
 * ======================================================================== */

bool
shim_read_stream_next(ShimReadStream stream)
{
	BufferAccessStrategy strategy = NULL;
	BlockNumber blk = read_stream_next_block((ReadStream *) stream, &strategy);

	return blk != InvalidBlockNumber;
}

/* ========================================================================
 * parallel scan
 * ======================================================================== */

size_t
shim_parallelscan_estimate(ShimRelation rel)
{
	return table_block_parallelscan_estimate((Relation) rel);
}

size_t
shim_parallelscan_initialize(ShimRelation rel, ShimParallelScan pscan)
{
	return table_block_parallelscan_initialize((Relation) rel,
											   (ParallelTableScanDesc) pscan);
}

void
shim_parallelscan_reinitialize(ShimRelation rel, ShimParallelScan pscan)
{
	table_block_parallelscan_reinitialize((Relation) rel,
										  (ParallelTableScanDesc) pscan);
}

/* ========================================================================
 * index fetch
 * ======================================================================== */

ShimIndexFetch
shim_index_fetch_alloc(ShimRelation rel)
{
	IndexFetchTableData *data =
		(IndexFetchTableData *) palloc0(sizeof(IndexFetchTableData));

	data->rel = (Relation) rel;
	return (ShimIndexFetch) data;
}

ShimRelation
shim_index_fetch_rel(ShimIndexFetch data)
{
	return (ShimRelation) ((IndexFetchTableData *) data)->rel;
}

void
shim_index_fetch_free(ShimIndexFetch data)
{
	pfree(data);
}

/* ========================================================================
 * index delete (bottom-up deletion)
 * ======================================================================== */

int
shim_idel_count(ShimIndexDeleteOp op)
{
	return ((TM_IndexDeleteOp *) op)->ndeltids;
}

void
shim_idel_set_count(ShimIndexDeleteOp op, int n)
{
	((TM_IndexDeleteOp *) op)->ndeltids = n;
}

void
shim_idel_tid(ShimIndexDeleteOp op, int i, ShimBlockNumber *blk,
			  ShimOffsetNumber *off)
{
	ItemPointer tid = &((TM_IndexDeleteOp *) op)->deltids[i].tid;

	*blk = (ShimBlockNumber) ItemPointerGetBlockNumberNoCheck(tid);
	*off = (ShimOffsetNumber) ItemPointerGetOffsetNumberNoCheck(tid);
}

int
shim_idel_id(ShimIndexDeleteOp op, int i)
{
	return ((TM_IndexDeleteOp *) op)->deltids[i].id;
}

void
shim_idel_set_deletable(ShimIndexDeleteOp op, int status_idx)
{
	((TM_IndexDeleteOp *) op)->status[status_idx].knowndeletable = true;
}

/* ========================================================================
 * index build
 * ======================================================================== */

int
shim_index_info_natts(ShimIndexInfo info)
{
	return ((IndexInfo *) info)->ii_NumIndexAttrs;
}

void
shim_index_build_setup(ShimRelation table_rel, ShimEState *estate_out,
					   ShimSlot *slot_out)
{
	Relation	table = (Relation) table_rel;
	EState	   *estate = CreateExecutorState();
	ExprContext *econtext = MakePerTupleExprContext(estate);
	TupleTableSlot *slot = MakeSingleTupleTableSlot(RelationGetDescr(table),
													&TTSOpsHeapTuple);

	econtext->ecxt_scantuple = slot;
	*estate_out = (ShimEState) estate;
	*slot_out = (ShimSlot) slot;
}

void
shim_index_build_form_datum(ShimIndexInfo info, ShimSlot slot, ShimEState estate,
							ShimDatum *values, bool *isnull)
{
	FormIndexDatum((IndexInfo *) info, (TupleTableSlot *) slot,
				   (EState *) estate, (Datum *) values, isnull);
}

void
shim_index_build_emit(void *callback, ShimRelation index_rel, ShimBlockNumber blk,
					  ShimOffsetNumber off, ShimDatum *values, bool *isnull,
					  void *callback_state)
{
	ItemPointerData tid;

	ItemPointerSet(&tid, (BlockNumber) blk, (OffsetNumber) off);
	((IndexBuildCallback) callback) ((Relation) index_rel, &tid,
									 (Datum *) values, isnull, true,
									 callback_state);
}

void
shim_index_build_teardown(ShimEState estate, ShimSlot slot)
{
	ExecDropSingleTupleTableSlot((TupleTableSlot *) slot);
	FreeExecutorState((EState *) estate);
}

void
shim_set_update_indexes_all(void *update_indexes)
{
	*(TU_UpdateIndexes *) update_indexes = TU_All;
}

/* ========================================================================
 * Datum construction / argument access
 * ======================================================================== */

ShimDatum
shim_int64_datum(int64_t v)
{
	return (ShimDatum) Int64GetDatum(v);
}

ShimDatum
shim_int32_datum(int32_t v)
{
	return (ShimDatum) Int32GetDatum(v);
}

ShimDatum
shim_bool_datum(bool v)
{
	return (ShimDatum) BoolGetDatum(v);
}

ShimDatum
shim_oid_datum(ShimOid v)
{
	return (ShimDatum) ObjectIdGetDatum((Oid) v);
}

ShimDatum
shim_text_datum(const char *s)
{
	return (ShimDatum) CStringGetTextDatum(s);
}

ShimOid
shim_getarg_oid(ShimFCInfo fcinfo, int n)
{
	return (ShimOid) DatumGetObjectId(((FunctionCallInfo) fcinfo)->args[n].value);
}

/* ========================================================================
 * set-returning functions
 * ======================================================================== */

ShimSRF
shim_srf_begin(ShimFCInfo fcinfo_)
{
	FunctionCallInfo fcinfo = (FunctionCallInfo) fcinfo_;
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	MemoryContext per_query_ctx;
	MemoryContext oldcontext;
	TupleDesc	tupdesc;
	Tuplestorestate *tupstore;
	ShimSRF		srf;

	if (rsinfo == NULL || !IsA(rsinfo, ReturnSetInfo))
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("set-valued function called in context that cannot accept a set")));
	if (!(rsinfo->allowedModes & SFRM_Materialize))
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("materialize mode required, but it is not allowed in this context")));

	per_query_ctx = rsinfo->econtext->ecxt_per_query_memory;
	oldcontext = MemoryContextSwitchTo(per_query_ctx);

	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("function returning record called in context that cannot accept type record")));
	tupdesc = BlessTupleDesc(tupdesc);
	tupstore = tuplestore_begin_heap(true, false, work_mem);

	rsinfo->returnMode = SFRM_Materialize;
	rsinfo->setResult = tupstore;
	rsinfo->setDesc = tupdesc;

	MemoryContextSwitchTo(oldcontext);

	srf.tupstore = tupstore;
	srf.tupdesc = tupdesc;
	return srf;
}

void
shim_srf_put(ShimSRF *srf, ShimDatum *values, bool *nulls)
{
	tuplestore_putvalues((Tuplestorestate *) srf->tupstore,
						 (TupleDesc) srf->tupdesc, (Datum *) values, nulls);
}

/* ========================================================================
 * macro-only constants
 * ======================================================================== */

const void *
shim_tts_ops_heaptuple(void)
{
	return &TTSOpsHeapTuple;
}

uint32_t
shim_blcksz(void)
{
	return (uint32_t) BLCKSZ;
}
