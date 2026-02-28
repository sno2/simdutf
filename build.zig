const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fallback = b.option(bool, "fallback", "Forcibly use the fallback implementation (defaults to false)") orelse false;
    const sanitize_thread = b.option(bool, "sanitize_thread", "Enable thread sanitizer");

    const upstream = b.dependency("simdutf", .{});

    var flags: std.ArrayList([]const u8) = .empty;
    defer flags.deinit(b.allocator);
    try flags.append(b.allocator, "-std=c++17");
    if (fallback) {
        try flags.append(b.allocator, "-DSIMDUTF_IMPLEMENTATION_FALLBACK=1");
    }
    var query = target.query;
    if (target.result.cpu.arch.isX86()) {
        query.cpu_features_add.addFeature(@intFromEnum(std.Target.x86.Feature.evex512));
    } else if (target.result.cpu.arch.isArm()) {
        query.cpu_features_add.addFeature(@intFromEnum(std.Target.arm.Feature.neon));
    } else if (target.result.cpu.arch.isRISCV()) {
        query.cpu_features_add.addFeature(@intFromEnum(std.Target.riscv.Feature.c));
        query.cpu_features_add.addFeature(@intFromEnum(std.Target.riscv.Feature.v));
    } else if (target.result.cpu.arch == .powerpc64le) {
        query.cpu_features_add.addFeature(@intFromEnum(std.Target.powerpc.Feature.vsx));
    } else if (target.result.cpu.arch == .loongarch64) {
        if (target.result.abi == .musl) {
            // musl had a patch to add these arch bits, but it seems to have been forgotten
            // https://www.openwall.com/lists/musl/2025/04/03/3
            try flags.appendSlice(b.allocator, &.{
                b.fmt("-DHWCAP_LOONGARCH_LSX={}", .{1 << 4}),
                b.fmt("-DHWCAP_LOONGARCH_LASX={}", .{1 << 5}),
            });
        }
        query.cpu_features_add.addFeature(@intFromEnum(std.Target.loongarch.Feature.lasx));
    }

    const simdutf = b.addLibrary(.{
        .name = "simdutf",
        .root_module = b.createModule(.{
            .target = if (fallback) target else b.resolveTargetQuery(query),
            .optimize = optimize,
            .link_libcpp = true,
            .sanitize_thread = sanitize_thread,
            .omit_frame_pointer = sanitize_thread,
        }),
    });
    simdutf.root_module.addIncludePath(upstream.path("src"));
    simdutf.root_module.addIncludePath(upstream.path("include"));
    simdutf.root_module.addCSourceFile(.{
        .file = upstream.path("src/simdutf.cpp"),
        .flags = flags.items,
    });
    simdutf.installHeadersDirectory(upstream.path("include"), "", .{});
    b.installArtifact(simdutf);

    const tests_reference = b.addLibrary(.{
        .name = "tests_reference",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libcpp = true,
            .sanitize_thread = sanitize_thread,
            .omit_frame_pointer = sanitize_thread,
        }),
    });
    tests_reference.installHeadersDirectory(upstream.path("tests/reference"), "tests/reference", .{});
    tests_reference.root_module.linkLibrary(simdutf);
    tests_reference.root_module.addCSourceFiles(.{
        .root = upstream.path("tests/reference"),
        .files = tests_reference_sources,
        .flags = &.{"-std=c++17"},
    });

    const tests_helpers = b.addLibrary(.{
        .name = "tests_helpers",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libcpp = true,
            .sanitize_thread = sanitize_thread,
            .omit_frame_pointer = sanitize_thread,
        }),
    });
    tests_helpers.root_module.linkLibrary(simdutf);
    tests_helpers.root_module.linkLibrary(tests_reference);
    tests_helpers.root_module.addCSourceFiles(.{
        .root = upstream.path("tests/helpers"),
        .files = tests_helpers_sources,
        .flags = &.{ "-std=c++17", "-DSIMDUTF_TEST_LOOP_TRIALS=10", "-DSIMDUTF_BASE64_TEST_MAXLEN=100" },
    });
    tests_helpers.installHeadersDirectory(upstream.path("tests/helpers"), "tests/helpers", .{});

    const test_step = b.step("test", "Run simdutf tests (no fuzz tests)");
    for (test_sources) |test_source| {
        const test_exe = b.addExecutable(.{
            .name = test_source,
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libcpp = true,
                .sanitize_thread = sanitize_thread,
                .omit_frame_pointer = sanitize_thread,
            }),
        });
        test_exe.root_module.addCSourceFile(.{
            .file = upstream.path("tests").path(b, test_source),
            .flags = &.{ "-std=c++17", "-DSIMDUTF_TEST_LOOP_TRIALS=10", "-DSIMDUTF_BASE64_TEST_MAXLEN=100" },
        });
        test_exe.root_module.linkLibrary(simdutf);
        test_exe.root_module.linkLibrary(tests_helpers);
        test_exe.root_module.linkLibrary(tests_reference);
        const run_test = b.addRunArtifact(test_exe);
        run_test.expectExitCode(0);
        test_step.dependOn(&run_test.step);
    }
}

const tests_reference_sources = &.{
    "encode_utf8.cpp",
    "encode_utf16.cpp",
    "encode_utf32.cpp",
    "encode_latin1.cpp",
    "validate_utf8_to_latin1.cpp",
    "validate_utf16_to_latin1.cpp",
    "validate_utf32_to_latin1.cpp",
    "validate_utf8.cpp",
    "validate_utf16.cpp",
    "validate_utf32.cpp",
};

const tests_helpers_sources = &.{
    "test.cpp",
    "random_int.cpp",
    "transcode_test_base.cpp",
    "random_utf8.cpp",
    "random_utf16.cpp",
    "random_utf32.cpp",
};

const test_sources: []const []const u8 = &.{
    "atomic_base64_tests.cpp",
    "base64_tests.cpp",
    "bele_tests.cpp",
    "convert_latin1_to_utf16be_tests.cpp",
    "convert_latin1_to_utf16le_tests.cpp",
    "convert_latin1_to_utf32_tests.cpp",
    "convert_latin1_to_utf8_tests.cpp",
    "convert_utf16be_to_latin1_tests.cpp",
    "convert_utf16be_to_latin1_tests_with_errors.cpp",
    "convert_utf16be_to_utf32_tests.cpp",
    "convert_utf16be_to_utf32_with_errors_tests.cpp",
    "convert_utf16be_to_utf8_tests.cpp",
    "convert_utf16be_to_utf8_with_errors_tests.cpp",
    "convert_utf16le_to_latin1_tests.cpp",
    "convert_utf16le_to_latin1_tests_with_errors.cpp",
    "convert_utf16le_to_utf32_tests.cpp",
    "convert_utf16le_to_utf32_with_errors_tests.cpp",
    "convert_utf16le_to_utf8_tests.cpp",
    "convert_utf16le_to_utf8_with_errors_tests.cpp",
    "convert_utf32_to_latin1_tests.cpp",
    "convert_utf32_to_latin1_with_errors_tests.cpp",
    "convert_utf32_to_utf16be_tests.cpp",
    "convert_utf32_to_utf16be_with_errors_tests.cpp",
    "convert_utf32_to_utf16le_tests.cpp",
    "convert_utf32_to_utf16le_with_errors_tests.cpp",
    "convert_utf32_to_utf8_tests.cpp",
    "convert_utf32_to_utf8_with_errors_tests.cpp",
    "convert_utf8_to_latin1_tests.cpp",
    "convert_utf8_to_latin1_with_errors_tests.cpp",
    "convert_utf8_to_utf16be_tests.cpp",
    "convert_utf8_to_utf16be_with_errors_tests.cpp",
    "convert_utf8_to_utf16le_tests.cpp",
    "convert_utf8_to_utf16le_with_errors_tests.cpp",
    "convert_utf8_to_utf32_tests.cpp",
    "convert_utf8_to_utf32_with_errors_tests.cpp",
    "convert_valid_utf16be_to_latin1_tests.cpp",
    "convert_valid_utf16be_to_utf32_tests.cpp",
    "convert_valid_utf16be_to_utf8_tests.cpp",
    "convert_valid_utf16le_to_latin1_tests.cpp",
    "convert_valid_utf16le_to_utf32_tests.cpp",
    "convert_valid_utf16le_to_utf8_tests.cpp",
    "convert_valid_utf32_to_latin1_tests.cpp",
    "convert_valid_utf32_to_utf16be_tests.cpp",
    "convert_valid_utf32_to_utf16le_tests.cpp",
    "convert_valid_utf32_to_utf8_tests.cpp",
    "convert_valid_utf8_to_latin1_tests.cpp",
    "convert_valid_utf8_to_utf16be_tests.cpp",
    "convert_valid_utf8_to_utf16le_tests.cpp",
    "convert_valid_utf8_to_utf32_tests.cpp",
    "count_utf16be.cpp",
    "count_utf16le.cpp",
    "count_utf8.cpp",
    "detect_encodings_tests.cpp",
    "internal_tests.cpp",
    "null_safety_tests.cpp",
    "readme_tests.cpp",
    "select_implementation.cpp",
    "span_tests.cpp",
    "special_tests.cpp",
    "to_well_formed_utf16_tests.cpp",
    "utf8_length_from_utf16_tests.cpp",
    "validate_ascii_basic_tests.cpp",
    "validate_ascii_with_errors_tests.cpp",
    "validate_utf16be_basic_tests.cpp",
    "validate_utf16be_with_errors_tests.cpp",
    "validate_utf16le_basic_tests.cpp",
    "validate_utf16le_with_errors_tests.cpp",
    "validate_utf32_basic_tests.cpp",
    "validate_utf32_with_errors_tests.cpp",
    "validate_utf8_basic_tests.cpp",
    "validate_utf8_brute_force_tests.cpp",
    "validate_utf8_puzzler_tests.cpp",
    "validate_utf8_with_errors_tests.cpp",
};
