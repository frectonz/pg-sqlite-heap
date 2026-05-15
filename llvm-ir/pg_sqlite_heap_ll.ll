; A Postgres extension written entirely in hand-rolled LLVM IR.
;
; Exposes one SQL function — `add_one(int4) -> int4` — plus the boilerplate
; the Postgres loader checks before it'll touch a `.dylib`:
;   * `Pg_magic_func`  -> pointer to a Pg_magic_struct describing the ABI
;   * `pg_finfo_<fn>`  -> pointer to a Pg_finfo_record with api_version = 1
;   * `<fn>`           -> the v1-calling-convention function itself
;
; Layouts pulled from $PGRXP/include/postgresql/server/fmgr.h (PG 18.3):
;
;   Pg_magic_struct = { int len; Pg_abi_values abi_fields; const char *name;
;                       const char *version; }     // sizeof = 72
;   Pg_abi_values   = { int version; int funcmaxargs; int indexmaxkeys;
;                       int namedatalen; int float8byval; char abi_extra[32]; }
;   FunctionCallInfoBaseData = { FmgrInfo *flinfo;     // @ 0
;                                fmNodePtr context;    // @ 8
;                                fmNodePtr resultinfo; // @ 16
;                                Oid fncollation;      // @ 24
;                                bool isnull;          // @ 28
;                                short nargs;          // @ 30
;                                NullableDatum args[]; // @ 32 (Datum, bool, pad)
;                              }

target triple = "arm64-apple-darwin"

; ---------------------------------------------------------------------------
; Pg_magic_struct — a flat record so we don't have to spell the nested
; Pg_abi_values type explicitly. Field-for-field equivalent on every ABI we
; care about.
; ---------------------------------------------------------------------------

%struct.Pg_magic_struct = type {
  i32,          ; len                = sizeof(Pg_magic_struct) = 72
  i32,          ; abi.version        = PG_VERSION_NUM / 100 = 1800
  i32,          ; abi.funcmaxargs    = 100
  i32,          ; abi.indexmaxkeys   = 32
  i32,          ; abi.namedatalen    = 64
  i32,          ; abi.float8byval    = 1 (true on aarch64 darwin)
  [32 x i8],    ; abi.abi_extra      = "PostgreSQL\0..."
  ptr,          ; name               = NULL
  ptr           ; version            = NULL
}

@Pg_magic_data = internal constant %struct.Pg_magic_struct {
  i32 72,
  i32 1800,
  i32 100,
  i32 32,
  i32 64,
  i32 1,
  [32 x i8] c"PostgreSQL\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00",
  ptr null,
  ptr null
}

; The loader looks up "Pg_magic_func" via dlsym and calls it. On macOS the
; assembler prefixes a `_` automatically; just keep the C-level name here.
define dso_local ptr @Pg_magic_func() {
  ret ptr @Pg_magic_data
}

; ---------------------------------------------------------------------------
; Pg_finfo_record { int api_version; } — version 1 for the modern calling
; convention.
; ---------------------------------------------------------------------------

%struct.Pg_finfo_record = type { i32 }

@pg_finfo_v1 = internal constant %struct.Pg_finfo_record { i32 1 }

define dso_local ptr @pg_finfo_add_one() {
  ret ptr @pg_finfo_v1
}

; ---------------------------------------------------------------------------
; The function itself.
;
; v1 ABI:   Datum add_one(FunctionCallInfo fcinfo)
;
; `Datum` is `uintptr_t` (i64 on 64-bit). For int4 args, the low 32 bits hold
; the value. fcinfo->args[0].value lives at byte offset 32 of fcinfo.
;
; We don't touch fcinfo->isnull — Postgres sets it to false before calling,
; and we never return NULL.
; ---------------------------------------------------------------------------

define dso_local i64 @add_one(ptr %fcinfo) {
entry:
  ; arg0.value is at offset 32 (skip flinfo/context/resultinfo/fncollation/
  ; isnull/nargs/padding — see header layout above).
  %args_value_ptr = getelementptr i8, ptr %fcinfo, i64 32
  %arg_datum      = load i64, ptr %args_value_ptr, align 8

  ; Datum -> int32: take low 32 bits.
  %arg_i32 = trunc i64 %arg_datum to i32
  %sum_i32 = add i32 %arg_i32, 1

  ; int32 -> Datum: zero-extend (Postgres uses zext for unsigned/Int32 too).
  %result = zext i32 %sum_i32 to i64
  ret i64 %result
}
