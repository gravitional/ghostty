const std = @import("std");
const translate_c = @import("translate_c");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("opengl", .{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Windows has no EGL. Translating `glad_egl.h` there would declare EGL
    // globals that nothing defines, which fails the Windows linker, so only
    // the GL header is translated for that target.
    switch (target.result.os.tag) {
        .windows => try translate_c.addImportToModule(b, "opengl_c", module, .{
            .source = .{ .includes = .{ .files = &.{
                .{ .path = "glad/gl.h" },
            } } },
            .target = target,
            .optimize = optimize,
            .include_paths = &.{b.path("../../vendor/glad/include")},
        }),

        else => try translate_c.addImportToModule(b, "opengl_c", module, .{
            .source = .{ .includes = .{ .files = &.{
                .{ .path = "glad/gl.h" },
                .{ .path = "glad/glad_egl.h" },
            } } },
            .target = target,
            .optimize = optimize,
            .include_paths = &.{b.path("../../vendor/glad/include")},
        }),
    }
}
