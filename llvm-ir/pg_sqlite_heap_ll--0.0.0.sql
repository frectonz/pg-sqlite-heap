-- Wire the LLVM-IR-defined `add_one` symbol up as a SQL function.
CREATE FUNCTION add_one(integer)
    RETURNS integer
    LANGUAGE c
    IMMUTABLE STRICT
    AS 'MODULE_PATHNAME', 'add_one';
