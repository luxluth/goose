const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("goose", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "goose",
        .root_module = mod,
    });
    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "goose-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "goose", .module = mod },
            },
        }),
    });

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("test-app", "Run the test app");
    run_step.dependOn(&run_cmd.step);

    const playground_exe = b.addExecutable(.{
        .name = "goose-playground",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/playground.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "goose", .module = mod },
            },
        }),
    });

    const run_plgd_cmd = b.addRunArtifact(playground_exe);
    run_plgd_cmd.step.dependOn(b.getInstallStep());
    run_plgd_cmd.addPassthruArgs();

    const run_plgd_step = b.step("playground", "Run the playground test file");
    run_plgd_step.dependOn(&run_plgd_cmd.step);

    const server_exe = b.addExecutable(.{
        .name = "goose-server-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/server_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "goose", .module = mod },
            },
        }),
    });

    const run_server = b.addRunArtifact(server_exe);
    run_server.addPassthruArgs();
    const server_step = b.step("test-server", "Run the server test app");
    server_step.dependOn(&run_server.step);

    const client_exe = b.addExecutable(.{
        .name = "goose-client-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/client_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "goose", .module = mod },
            },
        }),
    });

    const run_client = b.addRunArtifact(client_exe);
    run_client.addPassthruArgs();
    const client_step = b.step("test-client", "Run the client test app");
    client_step.dependOn(&run_client.step);

    const concurrency_exe = b.addExecutable(.{
        .name = "goose-concurrency-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/concurrency_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "goose", .module = mod },
            },
        }),
    });

    const run_concurrency = b.addRunArtifact(concurrency_exe);
    run_concurrency.addPassthruArgs();
    const concurrency_step = b.step("test-concurrency", "Run concurrency and lifecycle tests");
    concurrency_step.dependOn(&run_concurrency.step);

    const fd_exe = b.addExecutable(.{
        .name = "goose-unix-fd-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/unix_fd_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "goose", .module = mod },
            },
        }),
    });

    const run_fd = b.addRunArtifact(fd_exe);
    run_fd.addPassthruArgs();
    const fd_step = b.step("test-fd", "Run UNIX file descriptor passing tests");
    fd_step.dependOn(&run_fd.step);

    const intro_exe = b.addExecutable(.{
        .name = "goose-introspection",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/introspector.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "goose", .module = mod },
            },
        }),
    });
    b.installArtifact(intro_exe);
    const run_intro = b.addRunArtifact(intro_exe);
    run_intro.addPassthruArgs();
    const intro_step = b.step("introspection", "Run the introspection demo");
    intro_step.dependOn(&run_intro.step);

    const gen_exe = b.addExecutable(.{
        .name = "goose-generate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/generate_proxy.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "goose", .module = mod },
            },
        }),
    });
    b.installArtifact(gen_exe);

    const run_gen = b.addRunArtifact(gen_exe);
    run_gen.addPassthruArgs();
    const gen_step = b.step("generate", "Generate Zig proxy from D-Bus introspection");
    gen_step.dependOn(&run_gen.step);

    const mod_tests = b.addTest(.{
        .root_module = mod,
        .name = "goose",
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);

    const docs_step = b.step("docs", "Generate HTML documentation");
    const docs_install = b.addInstallDirectory(.{
        .source_dir = mod_tests.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    docs_step.dependOn(&docs_install.step);
}
