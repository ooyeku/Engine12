const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("engine12", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const ziggurat = b.dependency("ziggurat", .{
        .target = target,
        .optimize = optimize,
    });

    const vigil = b.dependency("vigil", .{
        .target = target,
        .optimize = optimize,
    });

    const websocket_dep = b.dependency("websocket", .{
        .target = target,
        .optimize = optimize,
    });

    // Create ziggurat module from its root source
    const ziggurat_mod = b.createModule(.{
        .root_source_file = ziggurat.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add vigil, ziggurat, and websocket to the engine12 module's imports
    mod.addImport("vigil", vigil.module("vigil"));
    mod.addImport("ziggurat", ziggurat_mod);
    mod.addImport("websocket", websocket_dep.module("websocket"));

    // Link system SQLite library for direct sqlite3 calls in ORM
    mod.linkSystemLibrary("sqlite3", .{});

    const exe = b.addExecutable(.{
        .name = "engine12",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "engine12", .module = mod },
                .{ .name = "vigil", .module = vigil.module("vigil") },
                .{ .name = "ziggurat", .module = ziggurat_mod },
            },
        }),
    });

    // Link system SQLite library directly
    exe.linkSystemLibrary("sqlite3");
    exe.linkLibC();

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

    // Link system SQLite library to mod tests
    mod_tests.linkSystemLibrary("sqlite3");
    mod_tests.linkLibC();

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);
    run_mod_tests.has_side_effects = true;

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // Link system SQLite library to exe tests
    exe_tests.linkSystemLibrary("sqlite3");
    exe_tests.linkLibC();

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);
    run_exe_tests.has_side_effects = true;

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // TODO Application executable
    const todo_exe = b.addExecutable(.{
        .name = "todo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("todo/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "engine12", .module = mod },
                .{ .name = "vigil", .module = vigil.module("vigil") },
                .{ .name = "ziggurat", .module = ziggurat_mod },
            },
        }),
    });

    // Link system SQLite library to todo executable
    todo_exe.linkSystemLibrary("sqlite3");
    todo_exe.linkLibC();

    // Install todo executable
    b.installArtifact(todo_exe);

    // TODO run step
    const todo_run_step = b.step("todo-run", "Run the TODO application");
    const todo_run_cmd = b.addRunArtifact(todo_exe);
    todo_run_step.dependOn(&todo_run_cmd.step);
    todo_run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        todo_run_cmd.addArgs(args);
    }

    // TODO test step
    const todo_test_exe = b.addTest(.{
        .root_module = todo_exe.root_module,
    });

    // Link system SQLite library to todo test executable
    todo_test_exe.linkSystemLibrary("sqlite3");
    todo_test_exe.linkLibC();

    const todo_test_step = b.step("todo-test", "Run TODO application tests");
    const run_todo_tests = b.addRunArtifact(todo_test_exe);
    todo_test_step.dependOn(&run_todo_tests.step);

    // Read version from build.zig.zon with robust error handling
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

    // Create options module for CLI with version
    const cli_options = b.addOptions();
    cli_options.addOption([]const u8, "version", version);

    // CLI executable
    const cli_exe = b.addExecutable(.{
        .name = "e12",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    cli_exe.root_module.addOptions("build_options", cli_options);

    // Install CLI executable
    b.installArtifact(cli_exe);

    // CLI install step
    const cli_install_step = b.step("cli-install", "Install e12 CLI tool");
    const cli_install_artifact = b.addInstallArtifact(cli_exe, .{});
    cli_install_step.dependOn(&cli_install_artifact.step);

    // Add reminder message after installation
    const cli_reminder_cmd = b.addSystemCommand(&.{ "sh", "-c" });
    cli_reminder_cmd.addArgs(&.{
        "printf '\\n\\033[1;32m e12 CLI installed successfully!\\033[0m\\n\\nTo use the e12 command, add it to your PATH:\\n  For zsh: source ~/.zshrc\\n  For bash: source ~/.bashrc\\n\\nOr restart your terminal.\\n\\nYou can also run it directly: ./zig-out/bin/e12\\n\\n'",
    });
    cli_install_step.dependOn(&cli_reminder_cmd.step);
}
