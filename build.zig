const std = @import("std");

/// Build the bundled SQLite static library from the amalgamation source.
/// This eliminates the need for users to have SQLite installed on their system.
fn buildSqliteLib(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) struct { lib: *std.Build.Step.Compile, dep: *std.Build.Dependency } {
    const sqlite_dep = b.dependency("sqlite", .{});

    const lib = b.addLibrary(.{
        .name = "sqlite3",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    lib.addCSourceFile(.{
        .file = sqlite_dep.path("sqlite3.c"),
        .flags = &.{
            "-std=c99",
            "-DSQLITE_ENABLE_FTS5",
            "-DSQLITE_ENABLE_RTREE",
            "-DSQLITE_ENABLE_JSON1",
            "-DSQLITE_ENABLE_COLUMN_METADATA",
            "-DSQLITE_DQS=0",
            "-DSQLITE_DEFAULT_MEMSTATUS=0",
            "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
            "-DSQLITE_LIKE_DOESNT_MATCH_BLOBS",
            "-DSQLITE_MAX_EXPR_DEPTH=0",
            "-DSQLITE_OMIT_DEPRECATED",
            "-DSQLITE_OMIT_PROGRESS_CALLBACK",
            "-DSQLITE_OMIT_SHARED_CACHE",
            "-DSQLITE_USE_ALLOCA",
            "-DSQLITE_THREADSAFE=1",
        },
    });

    lib.addIncludePath(sqlite_dep.path("."));

    return .{ .lib = lib, .dep = sqlite_dep };
}

/// Helper to link SQLite to a module
fn linkSqlite(mod: *std.Build.Module, sqlite_lib: *std.Build.Step.Compile, sqlite_dep: *std.Build.Dependency) void {
    mod.linkLibrary(sqlite_lib);
    mod.addIncludePath(sqlite_dep.path("."));
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build the bundled SQLite library
    const sqlite = buildSqliteLib(b, target, optimize);

    const mod = b.addModule("engine12", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .link_libc = true,
    });

    const ziggurat = b.dependency("ziggurat", .{
        .target = target,
        .optimize = optimize,
    });
    const vigil = b.dependency("vigil", .{
        .target = target,
        .optimize = optimize,
    });

    const ziggurat_mod = b.createModule(.{
        .root_source_file = ziggurat.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    mod.addImport("vigil", vigil.module("vigil"));
    mod.addImport("ziggurat", ziggurat_mod);

    // Link bundled SQLite instead of system library
    linkSqlite(mod, sqlite.lib, sqlite.dep);

    const exe = b.addExecutable(.{
        .name = "engine12",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "engine12", .module = mod },
                .{ .name = "vigil", .module = vigil.module("vigil") },
                .{ .name = "ziggurat", .module = ziggurat_mod },
            },
        }),
    });
    linkSqlite(exe.root_module, sqlite.lib, sqlite.dep);
    b.installArtifact(exe);

    const run_step = b.step("run", "Show available build commands");
    const run_info_cmd = b.addSystemCommand(&.{ "sh", "-c" });
    run_info_cmd.addArgs(&.{
        "printf '\\nengine12 Build Commands\\n=========================================================\\n  zig build             Build engine12 library and executables\\n  zig build test         Run all tests\\n  zig build todo-run     Run the TODO application\\n  zig build todo-test    Run TODO application tests\\n=========================================================\\n\\n'",
    });
    run_step.dependOn(&run_info_cmd.step);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    linkSqlite(mod_tests.root_module, sqlite.lib, sqlite.dep);
    mod_tests.root_module.link_libc = true;
    const run_mod_tests = b.addRunArtifact(mod_tests);
    run_mod_tests.has_side_effects = true;

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    linkSqlite(exe_tests.root_module, sqlite.lib, sqlite.dep);
    exe_tests.root_module.link_libc = true;
    const run_exe_tests = b.addRunArtifact(exe_tests);
    run_exe_tests.has_side_effects = true;

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const todo_exe = b.addExecutable(.{
        .name = "todo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("todo/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "engine12", .module = mod },
                .{ .name = "vigil", .module = vigil.module("vigil") },
                .{ .name = "ziggurat", .module = ziggurat_mod },
            },
        }),
    });
    linkSqlite(todo_exe.root_module, sqlite.lib, sqlite.dep);
    b.installArtifact(todo_exe);

    const todo_run_step = b.step("todo-run", "Run the TODO application");
    const todo_run_cmd = b.addRunArtifact(todo_exe);
    todo_run_step.dependOn(&todo_run_cmd.step);
    todo_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        todo_run_cmd.addArgs(args);
    }

    const todo_test_exe = b.addTest(.{
        .root_module = todo_exe.root_module,
    });
    linkSqlite(todo_test_exe.root_module, sqlite.lib, sqlite.dep);
    todo_test_exe.root_module.link_libc = true;
    const todo_test_step = b.step("todo-test", "Run TODO application tests");
    const run_todo_tests = b.addRunArtifact(todo_test_exe);
    todo_test_step.dependOn(&run_todo_tests.step);

    const build_zon_content = @embedFile("build.zig.zon");
    const version_prefix = ".version = \"";
    const version_start = std.mem.indexOf(u8, build_zon_content, version_prefix) orelse {
        @panic("FATAL: Could not find '.version = \"' in build.zig.zon. Please ensure build.zig.zon contains a version field.");
    };
    const version_value_start = version_start + version_prefix.len;
    if (version_value_start >= build_zon_content.len) {
        @panic("FATAL: Invalid version format in build.zig.zon. Version value appears to be empty.");
    }
    const version_end = std.mem.indexOfScalar(u8, build_zon_content[version_value_start..], '"') orelse {
        @panic("FATAL: Could not find closing quote for version in build.zig.zon. Please check the version field format.");
    };
    if (version_end == 0) {
        @panic("FATAL: Version string is empty in build.zig.zon.");
    }
    const version = build_zon_content[version_value_start..][0..version_end];

    const cli_options = b.addOptions();
    cli_options.addOption([]const u8, "version", version);

    const cli_exe = b.addExecutable(.{
        .name = "e12",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    cli_exe.root_module.addOptions("build_options", cli_options);
    b.installArtifact(cli_exe);

    const cli_install_step = b.step("cli-install", "Install e12 CLI tool");
    const cli_install_artifact = b.addInstallArtifact(cli_exe, .{});
    cli_install_step.dependOn(&cli_install_artifact.step);

    const cli_reminder_cmd = b.addSystemCommand(&.{ "sh", "-c" });
    cli_reminder_cmd.addArgs(&.{
        "printf '\\n\\033[1;32m e12 CLI installed successfully!\\033[0m\\n\\nTo use the e12 command, add it to your PATH:\\n  For zsh: source ~/.zshrc\\n  For bash: source ~/.bashrc\\n\\nOr restart your terminal.\\n\\nYou can also run it directly: ./zig-out/bin/e12\\n\\n'",
    });
    cli_install_step.dependOn(&cli_reminder_cmd.step);
}
