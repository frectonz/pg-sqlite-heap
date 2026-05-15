/*
 * C shim for the Zig sqlite_heap implementation.
 *
 * Zig 0.16's `@cImport` cannot digest the PostgreSQL header tree (translate-c
 * hangs on it), so the Zig side does *not* see the PostgreSQL headers at all.
 * Instead, every PostgreSQL type stays opaque to Zig and this shim owns all
 * struct layouts, macro expansions, and the pieces that must be emitted by a
 * C compiler (PG_MODULE_MAGIC, the v1 finfo records, the TableAmRoutine
 * dispatch table, the handler).
 *
 * The table-AM callback *bodies* and the inspection-function bodies live in
 * Zig and are exported with the C calling convention; this shim's
 * TableAmRoutine table simply points at them.
 *
 * shim.c includes the real PostgreSQL headers; this header is kept free of
 * them so it can double as documentation of the Zig <-> C boundary.
 */
#ifndef PG_SQLITE_HEAP_ZIG_SHIM_H
#define PG_SQLITE_HEAP_ZIG_SHIM_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

/*
 * Opaque handles. Zig only ever holds pointers to these; it never reaches
 * into the structs.
 */
typedef void *ShimRelation;
typedef void *ShimSnapshot;
typedef void *ShimSlot;
typedef void *ShimHeapTuple;
typedef void *ShimScan;
typedef void *ShimItemPointer;
typedef void *ShimIndexFetch;
typedef void *ShimIndexInfo;
typedef void *ShimIndexDeleteOp;
typedef void *ShimReadStream;
typedef void *ShimEState;
typedef void *ShimExprContext;
typedef void *ShimTupleDesc;
typedef void *ShimFCInfo;
typedef void *ShimParallelScan;

/* PostgreSQL scalar types, fixed-width and stable across the versions we
 * target (PG 17/18). */
typedef uint32_t ShimOid;
typedef uint32_t ShimXid;
typedef uint32_t ShimCid;
typedef uint32_t ShimSubXid;
typedef uint32_t ShimBlockNumber;
typedef uint16_t ShimOffsetNumber;
typedef uintptr_t ShimDatum;

/* --- errors -------------------------------------------------------------- */
extern void shim_ereport_error(const char *msg) __attribute__((noreturn));
extern void shim_ereport_warning(const char *msg);

/* --- backend globals ----------------------------------------------------- */
extern const char *shim_data_dir(void);
extern ShimOid     shim_my_database_id(void);

/* --- filesystem ---------------------------------------------------------- */
extern int     shim_mkdir_p(const char *path);     /* 0 ok, -1 fail */
extern int64_t shim_file_size(const char *path);   /* bytes, 0 if absent */
extern void    shim_unlink(const char *path);
extern void    shim_list_dir(const char *path,
							 void (*cb) (void *ctx, const char *name),
							 void *ctx);

/* --- transaction / sub-transaction callbacks ----------------------------
 *
 * The shim registers permanent C trampolines once; they filter the event
 * kind and dispatch into these Zig-exported functions. Registering happens
 * via shim_register_xact_callbacks().
 */
extern void shim_register_xact_callbacks(void);
/* exported from Zig: */
extern void zig_on_precommit(void);
extern void zig_on_commit(void);
extern void zig_on_abort(void);
extern void zig_on_sub_start(ShimSubXid my_subid);
extern void zig_on_sub_commit(ShimSubXid my_subid);
extern void zig_on_sub_abort(ShimSubXid my_subid);

/* --- transaction id helpers --------------------------------------------- */
extern ShimXid shim_current_xid(void);
extern ShimCid shim_current_cid(bool used);
extern ShimXid shim_oldest_non_removable_xid(ShimRelation rel);
extern bool    shim_xid_did_commit(ShimXid xid);
extern bool    shim_xid_is_current(ShimXid xid);
extern bool    shim_xid_in_progress(ShimXid xid);
extern bool    shim_xid_precedes(ShimXid a, ShimXid b);
extern bool    shim_xid_follows(ShimXid a, ShimXid b);

/* --- relation ------------------------------------------------------------ */
extern ShimOid       shim_rel_oid(ShimRelation rel);
extern ShimTupleDesc shim_rel_tupdesc(ShimRelation rel);

/* --- slots --------------------------------------------------------------- */
extern void          shim_slot_clear(ShimSlot slot);
extern void          shim_slot_store_tuple(ShimSlot slot, ShimHeapTuple tup);
extern ShimHeapTuple shim_slot_copy_heaptuple(ShimSlot slot);
extern void          shim_slot_set_tid(ShimSlot slot, ShimOid table_oid,
									   ShimBlockNumber blk, ShimOffsetNumber off);
extern void          shim_slot_get_tid(ShimSlot slot, ShimBlockNumber *blk,
									   ShimOffsetNumber *off);

/* --- item pointers (raw, unchecked block/offset access) ------------------ */
extern ShimBlockNumber  shim_itemptr_block(ShimItemPointer p);
extern ShimOffsetNumber shim_itemptr_offset(ShimItemPointer p);

/* --- heap tuples ---------------------------------------------------------
 *
 * Build a HeapTuple as `[HeapTupleData][tuple bytes]` in one palloc and
 * overlay the MVCC header (xmin/xmax/cmin) onto the HeapTupleHeader.
 */
extern ShimHeapTuple shim_build_heap_tuple(ShimOid table_oid,
										   ShimBlockNumber blk,
										   ShimOffsetNumber off,
										   const void *bytes, uint32_t len,
										   ShimXid xmin, ShimXid xmax,
										   ShimCid cid);
extern const void *shim_heaptuple_bytes(ShimHeapTuple tup, uint32_t *len);
extern void        shim_heap_freetuple(ShimHeapTuple tup);

/* --- snapshots ----------------------------------------------------------- */
extern int     shim_snapshot_type(ShimSnapshot snap);
extern ShimXid shim_snap_xmin(ShimSnapshot snap);
extern ShimXid shim_snap_xmax(ShimSnapshot snap);
extern ShimCid shim_snap_curcid(ShimSnapshot snap);
extern uint32_t shim_snap_xcnt(ShimSnapshot snap);
extern ShimXid shim_snap_xip(ShimSnapshot snap, uint32_t i);
extern void    shim_snap_reset_dirty_out(ShimSnapshot snap);
extern void    shim_snap_set_xmin(ShimSnapshot snap, ShimXid xid);
extern void    shim_snap_set_xmax(ShimSnapshot snap, ShimXid xid);

/* SnapshotType enum values (utils/snapshot.h). */
enum
{
	SHIM_SNAPSHOT_MVCC = 0,
	SHIM_SNAPSHOT_SELF = 1,
	SHIM_SNAPSHOT_ANY = 2,
	SHIM_SNAPSHOT_TOAST = 3,
	SHIM_SNAPSHOT_DIRTY = 4,
	SHIM_SNAPSHOT_HISTORIC_MVCC = 5,
	SHIM_SNAPSHOT_NON_VACUUMABLE = 6
};

/* --- scan descriptor -----------------------------------------------------
 *
 * The AM-specific scan state is `[TableScanDescData][void *cursor]`. The
 * cursor is Zig-owned (it holds the loaded rows and iteration position);
 * everything else is reached through these accessors.
 */
extern ShimScan      shim_scan_alloc(ShimRelation rel, ShimSnapshot snapshot,
									 int nkeys, void *key,
									 ShimParallelScan pscan, uint32_t flags,
									 void *cursor);
extern void         *shim_scan_cursor(ShimScan scan);
extern void          shim_scan_free(ShimScan scan);
extern ShimRelation  shim_scan_rel(ShimScan scan);
extern ShimSnapshot  shim_scan_snapshot(ShimScan scan);
extern void          shim_scan_set_tidrange(ShimScan scan,
											ShimItemPointer mintid,
											ShimItemPointer maxtid);
extern void          shim_scan_get_tidrange(ShimScan scan,
											ShimBlockNumber *min_blk,
											ShimOffsetNumber *min_off,
											ShimBlockNumber *max_blk,
											ShimOffsetNumber *max_off);

/* --- bitmap (TID-bitmap) scan -------------------------------------------
 *
 * One page of the TID bitmap, extracted in a single shim call. For an exact
 * page, `offsets[0..noffsets]` holds the page's tuple offsets; for a lossy
 * page `lossy` is true and the Zig side must enumerate the block itself.
 */
#define SHIM_MAX_OFFSETS 1024
typedef struct ShimTbmPage
{
	ShimBlockNumber  blockno;
	bool             recheck;
	bool             lossy;
	int              noffsets;
	ShimOffsetNumber offsets[SHIM_MAX_OFFSETS];
} ShimTbmPage;

extern bool shim_tbm_next(ShimScan scan, ShimTbmPage *out);

/* --- analyze / sample ---------------------------------------------------- */
extern bool shim_read_stream_next(ShimReadStream stream); /* false at end */

/* --- parallel scan ------------------------------------------------------- */
extern size_t shim_parallelscan_estimate(ShimRelation rel);
extern size_t shim_parallelscan_initialize(ShimRelation rel, ShimParallelScan pscan);
extern void   shim_parallelscan_reinitialize(ShimRelation rel, ShimParallelScan pscan);

/* --- index fetch --------------------------------------------------------- */
extern ShimIndexFetch shim_index_fetch_alloc(ShimRelation rel);
extern ShimRelation   shim_index_fetch_rel(ShimIndexFetch data);
extern void           shim_index_fetch_free(ShimIndexFetch data);

/* --- index delete (bottom-up deletion) ---------------------------------- */
extern int     shim_idel_count(ShimIndexDeleteOp op);
extern void    shim_idel_set_count(ShimIndexDeleteOp op, int n);
extern void    shim_idel_tid(ShimIndexDeleteOp op, int i,
							 ShimBlockNumber *blk, ShimOffsetNumber *off);
extern int     shim_idel_id(ShimIndexDeleteOp op, int i);
extern void    shim_idel_set_deletable(ShimIndexDeleteOp op, int status_idx);

/* --- index build --------------------------------------------------------- */
extern int  shim_index_info_natts(ShimIndexInfo info);
/* Set up an executor state + per-tuple slot for an index build. The opaque
 * handles are returned through the out-params; release with
 * shim_index_build_teardown. */
extern void shim_index_build_setup(ShimRelation table_rel,
								   ShimEState *estate_out,
								   ShimSlot *slot_out);
extern void shim_index_build_form_datum(ShimIndexInfo info, ShimSlot slot,
										ShimEState estate,
										ShimDatum *values, bool *isnull);
/* Construct the TID for `blk`/`off` and invoke the index build callback. */
extern void shim_index_build_emit(void *callback, ShimRelation index_rel,
								  ShimBlockNumber blk, ShimOffsetNumber off,
								  ShimDatum *values, bool *isnull,
								  void *callback_state);
extern void shim_index_build_teardown(ShimEState estate, ShimSlot slot);

/* --- tuple update index signalling -------------------------------------- */
extern void shim_set_update_indexes_all(void *update_indexes);

/* --- Datum construction / argument access ------------------------------- */
extern ShimDatum shim_int64_datum(int64_t v);
extern ShimDatum shim_int32_datum(int32_t v);
extern ShimDatum shim_bool_datum(bool v);
extern ShimDatum shim_oid_datum(ShimOid v);
extern ShimDatum shim_text_datum(const char *s);
extern ShimOid   shim_getarg_oid(ShimFCInfo fcinfo, int n);

/* --- set-returning functions -------------------------------------------- */
typedef struct ShimSRF
{
	void *tupstore;
	void *tupdesc;
} ShimSRF;

extern ShimSRF shim_srf_begin(ShimFCInfo fcinfo);
extern void    shim_srf_put(ShimSRF *srf, ShimDatum *values, bool *nulls);

/* --- slot operations vtable ---------------------------------------------- */
extern const void *shim_tts_ops_heaptuple(void);

/* --- macro-only constants ------------------------------------------------ */
extern uint32_t shim_blcksz(void);

#endif							/* PG_SQLITE_HEAP_ZIG_SHIM_H */
