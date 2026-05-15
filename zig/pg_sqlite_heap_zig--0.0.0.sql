/* pg_sqlite_heap_zig--0.0.0.sql */

-- The table access method handler. Returns a pointer to the TableAmRoutine.
CREATE FUNCTION sqlite_heap_zig_handler(internal)
    RETURNS table_am_handler
    LANGUAGE c
    AS 'MODULE_PATHNAME', 'sqlite_heap_zig_handler';

CREATE ACCESS METHOD sqlite_heap_zig TYPE TABLE HANDLER sqlite_heap_zig_handler;

-- ===========================================================================
-- Debug / inspection. Each takes a table OID; call with `'mytable'::regclass`.
-- ===========================================================================

CREATE FUNCTION sqlite_heap_zig_file_path(oid)
    RETURNS text
    LANGUAGE c STRICT
    AS 'MODULE_PATHNAME', 'sqlite_heap_zig_file_path';

CREATE FUNCTION sqlite_heap_zig_file_size(oid)
    RETURNS bigint
    LANGUAGE c STRICT
    AS 'MODULE_PATHNAME', 'sqlite_heap_zig_file_size';

CREATE FUNCTION sqlite_heap_zig_schema_version(oid)
    RETURNS integer
    LANGUAGE c STRICT
    AS 'MODULE_PATHNAME', 'sqlite_heap_zig_schema_version';

CREATE FUNCTION sqlite_heap_zig_physical_rows(oid)
    RETURNS bigint
    LANGUAGE c STRICT
    AS 'MODULE_PATHNAME', 'sqlite_heap_zig_physical_rows';

CREATE FUNCTION sqlite_heap_zig_live_rows(oid)
    RETURNS bigint
    LANGUAGE c STRICT
    AS 'MODULE_PATHNAME', 'sqlite_heap_zig_live_rows';

CREATE FUNCTION sqlite_heap_zig_storage(oid)
    RETURNS TABLE(
        rowid bigint,
        xmin bigint,
        cmin bigint,
        xmax bigint,
        cmax bigint,
        tuple_bytes integer,
        live boolean
    )
    LANGUAGE c STRICT
    AS 'MODULE_PATHNAME', 'sqlite_heap_zig_storage';

CREATE FUNCTION sqlite_heap_zig_files()
    RETURNS TABLE(table_oid oid, size_bytes bigint)
    LANGUAGE c
    AS 'MODULE_PATHNAME', 'sqlite_heap_zig_files';

CREATE FUNCTION sqlite_heap_zig_drop_storage(oid)
    RETURNS void
    LANGUAGE c STRICT
    AS 'MODULE_PATHNAME', 'sqlite_heap_zig_drop_storage';

-- ===========================================================================
-- Reclaim the SQLite file when its table is dropped.
-- ===========================================================================

CREATE OR REPLACE FUNCTION sqlite_heap_zig_drop_handler()
    RETURNS event_trigger
    LANGUAGE plpgsql
AS $$
DECLARE
    obj record;
BEGIN
    FOR obj IN
        SELECT objid FROM pg_event_trigger_dropped_objects()
        WHERE object_type = 'table'
    LOOP
        PERFORM sqlite_heap_zig_drop_storage(obj.objid);
    END LOOP;
END;
$$;

CREATE EVENT TRIGGER sqlite_heap_zig_on_drop
    ON sql_drop
    EXECUTE FUNCTION sqlite_heap_zig_drop_handler();
