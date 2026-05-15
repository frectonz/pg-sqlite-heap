const std = @import("std");

// Build the Zig re-implementation of the sqlite_heap table access method.
//
//   zig build               -- compile pg_sqlite_heap_zig into zig-out/lib
//   zig build pg-install    -- copy the module + .control + .sql into the
//                              PostgreSQL tree reported by pg_config
//
// `pg_config` is discovered, in order, from `-Dpg_config=...`, the `PG_CONFIG`
// environment variable, or this repo's pgrx config (`~/.pgrx/config.toml`),
// finally falling back to whatever `pg_config` is on PATH. All of that --
// plus reading DLSUFFIX out of the PGXS makefile -- happens in one shell
// helper so `build.zig` itself stays free of host-specific file I/O.

const discover =
    \\set -e
    \\PGC="$1"
    \\[ -z "$PGC" ] && PGC="${PG_CONFIG:-}"
    \\if [ -z "$PGC" ] && [ -f "$HOME/.pgrx/config.toml" ]; then
    \\  PGC=$(grep -oE '"[^"]*pg_config"' "$HOME/.pgrx/config.toml" | tail -1 | tr -d '"')
    \\fi
    \\[ -z "$PGC" ] && PGC=pg_config
    \\INC=$("$PGC" --includedir-server)
    \\PKG=$("$PGC" --pkglibdir)
    \\SHARE=$("$PGC" --sharedir)
    \\DLS=$(grep -E '^DLSUFFIX' "$PKG/pgxs/src/Makefile.global" 2>/dev/null | head -1 | sed 's/.*= *//')
    \\[ -z "$DLS" ] && DLS=.so
    \\printf '%s\n%s\n%s\n%s\n' "$INC" "$PKG" "$SHARE" "$DLS"
;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const pg_config_opt = b.option([]const u8, "pg_config", "Path to the pg_config to build against") orelse "";

    const out = b.run(&.{ "sh", "-c", discover, "build.zig", pg_config_opt });
    var lines = std.mem.tokenizeScalar(u8, out, '\n');
    const include_server = lines.next() orelse @panic("pg_config discovery failed");
    const pkglibdir = lines.next() orelse @panic("pg_config discovery failed");
    const sharedir = lines.next() orelse @panic("pg_config discovery failed");
    const dlsuffix = lines.next() orelse ".so";

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(.{ .cwd_relative = include_server });
    mod.addIncludePath(b.path("src"));
    mod.addCSourceFile(.{
        .file = b.path("src/shim.c"),
        .flags = &.{ "-std=gnu11", "-Wno-unused-parameter", "-Wno-sign-conversion" },
    });
    mod.linkSystemLibrary("sqlite3", .{});

    const lib = b.addLibrary(.{
        .name = "pg_sqlite_heap_zig",
        .root_module = mod,
        .linkage = .dynamic,
    });
    // PostgreSQL symbols are resolved at load time from the running backend,
    // not at link time -- the module is intentionally left with undefined
    // symbols.
    lib.linker_allow_shlib_undefined = true;
    b.installArtifact(lib);

    // `zig build pg-install` -- drop the artifacts where PostgreSQL expects
    // them. The module file is renamed to `<name><DLSUFFIX>` (no `lib` prefix)
    // because that is what `module_pathname` in the .control file resolves to.
    const pg_install = b.step("pg-install", "Install the extension into the PostgreSQL tree");

    const cp_lib = b.addSystemCommand(&.{"cp"});
    cp_lib.addFileArg(lib.getEmittedBin());
    cp_lib.addArg(b.fmt("{s}/pg_sqlite_heap_zig{s}", .{ pkglibdir, dlsuffix }));
    pg_install.dependOn(&cp_lib.step);

    const cp_control = b.addSystemCommand(&.{"cp"});
    cp_control.addFileArg(b.path("pg_sqlite_heap_zig.control"));
    cp_control.addArg(b.fmt("{s}/extension/pg_sqlite_heap_zig.control", .{sharedir}));
    pg_install.dependOn(&cp_control.step);

    const cp_sql = b.addSystemCommand(&.{"cp"});
    cp_sql.addFileArg(b.path("pg_sqlite_heap_zig--0.0.0.sql"));
    cp_sql.addArg(b.fmt("{s}/extension/pg_sqlite_heap_zig--0.0.0.sql", .{sharedir}));
    pg_install.dependOn(&cp_sql.step);
}
