// Instrumenting wrapper around a package's own build.zig (the skill's route 3b for a
// zig-built addon).  Tested on zig 0.16.0 with an image-decoding binding's
// zig build; see
// references/zig-build.md for the recipe and the traps.
//
// It does NOT edit the package: it instantiates the package as a path dependency with
// the same target/optimize its publish workflow uses, finds the Compile step that
// builds the .node (-Dname=, required), walks the whole Module graph and appends
// compiler flags to every C/C++ source set -- the zig analog of overriding CC.target in
// a gyp makefile.  Coverage goes in through zig cc (which is clang), the AFL runtime
// lives only in the harness, and covstub.c keeps the .node loadable by plain node.
// Products, under --prefix:
//   lib/<name>.node        the addon exactly as the package builds it + flags + covstub.c
//   lib/lib<name>glue.a    the addon's own C++ TUs (same files, same flags) as a static lib
//   lib/lib<dep>.a         every vendored library the .node links (instrumented)
//   bin/harness, bin/harness-fork   (only with -Dharness=<harness.cc> -Dstubs=<stubs.cc>)
//
// Layout: a directory holding this file as build.zig, covstub.c (copy it from
// resources/), and a build.zig.zon declaring the package:
//   .{ .name = .zbuild, .version = "0.0.0", .fingerprint = <zig tells you the value>,
//      .dependencies = .{ .pkg = .{ .path = "../<pkg>" } }, .paths = .{""} }
// Then:
//   zig build -Dtarget=<the publish target> -Doptimize=ReleaseFast --prefix /abs/out/plain
//   zig build harness ... -Dharness=/abs/harness.cc -Dstubs=/abs/out/plain/stubs.cc \
//             -Dshim=/abs/resources/afl_shim.h -Dafl_rt=$(resources/find_afl_rt.sh) --prefix /abs/out/plain
//   (asan: add -Dasan=true -Dasan_rt=$(dirname $(resources/find_asan_rt.sh)))
const std = @import("std");
const Compile = std.Build.Step.Compile;
const Module = std.Build.Module;

fn appendFlags(b: *std.Build, old: []const []const u8, extra: []const []const u8) []const []const u8 {
    const n = b.allocator.alloc([]const u8, old.len + extra.len) catch @panic("OOM");
    @memcpy(n[0..old.len], old);
    @memcpy(n[old.len..], extra);
    return n;
}

fn patchModule(b: *std.Build, m: *Module, extra: []const []const u8, seen: *std.AutoHashMapUnmanaged(*Module, void), libs: *std.ArrayListUnmanaged(*Compile), seen_c: *std.AutoHashMapUnmanaged(*Compile, void)) void {
    if (seen.contains(m)) return;
    seen.put(b.allocator, m, {}) catch @panic("OOM");
    for (m.link_objects.items) |lo| switch (lo) {
        .c_source_files => |csf| csf.flags = appendFlags(b, csf.flags, extra),
        .c_source_file => |cs| cs.flags = appendFlags(b, cs.flags, extra),
        .other_step => |c| patchCompile(b, c, extra, seen, libs, seen_c),
        else => {},
    };
    for (m.import_table.values()) |im| patchModule(b, im, extra, seen, libs, seen_c);
}

fn patchCompile(b: *std.Build, c: *Compile, extra: []const []const u8, seen: *std.AutoHashMapUnmanaged(*Module, void), libs: *std.ArrayListUnmanaged(*Compile), seen_c: *std.AutoHashMapUnmanaged(*Compile, void)) void {
    if (seen_c.contains(c)) return;
    seen_c.put(b.allocator, c, {}) catch @panic("OOM");
    libs.append(b.allocator, c) catch @panic("OOM");
    patchModule(b, c.root_module, extra, seen, libs, seen_c);
}

fn findCompile(step: *std.Build.Step, name: []const u8) ?*Compile {
    if (step.cast(Compile)) |c| if (std.mem.eql(u8, c.name, name)) return c;
    for (step.dependencies.items) |d| if (findCompile(d, name)) |c| return c;
    return null;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const cov = b.option(bool, "cov", "add -fsanitize-coverage=trace-pc-guard") orelse true;
    const asan = b.option(bool, "asan", "add -fsanitize=address") orelse false;
    const harness_src = b.option([]const u8, "harness", "absolute path of harness.cc");
    const stubs_src = b.option([]const u8, "stubs", "absolute path of stubs.cc");
    const afl_rt = b.option([]const u8, "afl_rt", "afl-compiler-rt.o") orelse "/usr/lib/afl/afl-compiler-rt.o";
    const shim = b.option([]const u8, "shim", "afl shim header") orelse "";
    const asan_rt = b.option([]const u8, "asan_rt", "libclang_rt.asan static archive dir");
    const name = b.option([]const u8, "name", "name of the Compile step that builds the .node") orelse @panic("pass -Dname=<the Compile step that builds the .node>");
    const pkg = b.option([]const u8, "pkg", "dependency name in build.zig.zon") orelse "pkg";
    const arch = @tagName(target.result.cpu.arch);

    var extra: std.ArrayListUnmanaged([]const u8) = .empty;
    if (cov) extra.append(b.allocator, "-fsanitize-coverage=trace-pc-guard") catch unreachable;
    if (asan) {
        extra.append(b.allocator, "-fsanitize=address") catch unreachable;
        extra.append(b.allocator, "-fno-omit-frame-pointer") catch unreachable;
    }

    const dep = b.dependency(pkg, .{ .target = target, .optimize = optimize });
    const addon = findCompile(dep.builder.getInstallStep(), name) orelse @panic("Compile step for the .node not found; pass -Dname=");

    // Lift the addon's own C++ source set BEFORE patching (so we copy it once).
    var glue_sets: std.ArrayListUnmanaged(*Module.CSourceFiles) = .empty;
    for (addon.root_module.link_objects.items) |lo| switch (lo) {
        .c_source_files => |csf| glue_sets.append(b.allocator, csf) catch unreachable,
        else => {},
    };

    var seen: std.AutoHashMapUnmanaged(*Module, void) = .empty;
    var seen_c: std.AutoHashMapUnmanaged(*Compile, void) = .empty;
    var libs: std.ArrayListUnmanaged(*Compile) = .empty;
    patchCompile(b, addon, extra.items, &seen, &libs, &seen_c);

    // covstub.c: weak no-op coverage callbacks so node can dlopen the instrumented .node
    // (the real AFL runtime lives only in the harness).  Not itself instrumented.
    addon.root_module.addCSourceFile(.{ .file = b.path("covstub.c"), .flags = &.{} });
    if (asan) addon.linker_allow_shlib_undefined = true; // ASAN runtime comes from LD_PRELOAD under node

    b.getInstallStep().dependOn(&b.addInstallFile(addon.getEmittedBin(), b.fmt("lib/{s}.node", .{name})).step);

    // The addon's own TUs as a static library: same root, same file list, same flags
    // (already patched above), same include paths (via the same linkLibrary calls).
    const glue = b.addLibrary(.{
        .name = b.fmt("{s}glue", .{name}),
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .pic = true, .link_libc = true, .link_libcpp = true }),
    });
    for (glue_sets.items) |csf| glue.root_module.addCSourceFiles(.{ .root = csf.root, .files = csf.files, .flags = csf.flags });
    for (addon.root_module.link_objects.items) |lo| switch (lo) {
        .other_step => |c| if (c.kind == .lib) glue.root_module.linkLibrary(c) else glue.root_module.addObject(c),
        else => {},
    };
    const glue_step = b.step("glue", "build the glue static lib and the libraries");
    glue_step.dependOn(&b.addInstallArtifact(glue, .{}).step);
    for (libs.items[1..]) |c| {
        if (c.kind == .lib) {
            const ia = b.addInstallArtifact(c, .{ .dest_sub_path = b.fmt("lib{s}.a", .{c.name}), .h_dir = .disabled });
            glue_step.dependOn(&ia.step);
            b.getInstallStep().dependOn(&ia.step);
        }
    }
    b.getInstallStep().dependOn(glue_step);

    if (harness_src) |hs| {
        const hstep = b.step("harness", "link harness and harness-fork");
        for ([_][]const u8{ "harness", "harness-fork" }) |exe_name| {
            const exe = b.addExecutable(.{
                .name = exe_name,
                .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .link_libcpp = true }),
            });
            var hflags: std.ArrayListUnmanaged([]const u8) = .empty;
            hflags.appendSlice(b.allocator, glue_sets.items[0].flags) catch unreachable;
            if (shim.len > 0) hflags.appendSlice(b.allocator, &.{ "-include", shim }) catch unreachable;
            if (std.mem.eql(u8, exe_name, "harness-fork")) hflags.append(b.allocator, "-DNO_PERSISTENT") catch unreachable;
            hflags.append(b.allocator, b.fmt("-I{s}", .{dep.builder.pathFromRoot("src")})) catch unreachable;
            exe.root_module.addCSourceFile(.{ .file = .{ .cwd_relative = hs }, .flags = hflags.items });
            if (stubs_src) |ss| exe.root_module.addCSourceFile(.{ .file = .{ .cwd_relative = ss }, .flags = extra.items });
            exe.root_module.linkLibrary(glue);
            for (addon.root_module.link_objects.items) |lo| switch (lo) {
                .other_step => |c| if (c.kind == .lib) exe.root_module.linkLibrary(c) else exe.root_module.addObject(c),
                else => {},
            };
            exe.root_module.addObjectFile(.{ .cwd_relative = afl_rt });
            if (asan_rt) |ar| {
                exe.root_module.addObjectFile(.{ .cwd_relative = b.fmt("{s}/libclang_rt.asan_static-{s}.a", .{ ar, arch }) });
                exe.root_module.addObjectFile(.{ .cwd_relative = b.fmt("{s}/libclang_rt.asan-{s}.a", .{ ar, arch }) });
                exe.root_module.addObjectFile(.{ .cwd_relative = b.fmt("{s}/libclang_rt.asan_cxx-{s}.a", .{ ar, arch }) });
            }
            hstep.dependOn(&b.addInstallArtifact(exe, .{}).step);
        }
    }
}
