//! The OpenGL device context.
//!
//! This holds the window-system integration used to create GL contexts,
//! each corresponding to a surface, its renderer object and its render
//! thread.
//!
//! On Unix the display is EGL's surfaceless platform. Windows has no EGL,
//! so `wsi` resolves to a small WGL implementation backed by a hidden
//! helper window. Either way the renderer itself is identical: it renders
//! into its own framebuffer objects and never draws to a window.
//!
//! TODO: If there's a way to prefer certain devices like in
//! Vulkan or Metal we should do it here.
const Device = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");
const wsi = gl.wsi;

const log = std.log.scoped(.opengl);

/// Options used when creating the OpenGL device.
pub const Options = struct {
    /// Render with the provided display.
    /// Caller is responsible for managing the lifetime of the display.
    /// The default display will be used when null.
    display: ?*wsi.Display = null,

    /// Window to bind the GL context to when the app runtime wants frames
    /// presented with `SwapBuffers` instead of read back. Opaque here.
    window_handle: ?*anyopaque = null,
};

/// The window-system display.
///
/// The lifecycle of this display is always managed externally, both in the
/// cases where we were given a display as a config option, or we use the
/// systemwide default display that is cleaned up by the OS.
display: *wsi.Display,

/// The config used to create surface renderer contexts. Chosen
/// once here so that all contexts share compatible capabilities.
config: *wsi.Config,

pub fn init(alloc: Allocator, options: Options) !*Device {
    const self = try alloc.create(Device);
    errdefer alloc.destroy(self);

    try wsi.load();

    const display = options.display orelse
        if (options.window_handle) |handle|
            try wsi.Display.initForWindow(handle)
        else
            try wsi.Display.initDefault();

    log.info("GL vendor={s}", .{display.queryString(.vendor) orelse "(unknown)"});
    log.info("GL extensions={s}", .{display.queryString(.extensions) orelse "(unknown)"});

    const config = try wsi.Config.chooseDefault(display);

    self.* = .{
        .display = display,
        .config = config,
    };
    return self;
}

pub fn deinit(self: *Device, alloc: std.mem.Allocator) void {
    // Do not destroy the display as it is externally managed.
    alloc.destroy(self);
}
