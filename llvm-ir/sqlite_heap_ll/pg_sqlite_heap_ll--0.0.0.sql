CREATE FUNCTION sqlite_heap_ll_handler(internal)
    RETURNS table_am_handler
    LANGUAGE c
    AS 'MODULE_PATHNAME', 'sqlite_heap_ll_handler';

CREATE ACCESS METHOD sqlite_heap_ll TYPE TABLE HANDLER sqlite_heap_ll_handler;
