//! Minimal WGL bindings for Windows.
//!
//! This mirrors the small subset of the EGL surface in `egl.zig` that
//! Ghostty uses, so the renderer can pick a window-system integration at
//! comptime without knowing which one it got.
//!
//! A hidden helper window owns the device context the GL context is bound
//! to. Ghostty renders into its own framebuffer objects and presents the
//! result itself (GPU->CPU readback on Windows), so no swap chain is
//! needed here: the helper window is never shown.
//!
//! Only the Win32 entry points we actually use are declared. Zig's Windows
//! std API surface has been churning, and this package is deliberately
//! independent of the `src/os/windows.zig` bridge.

const std = @import("std");

const log = std.log.scoped(.opengl_wgl);

// ---------------------------------------------------------------------------
// Win32 types
// ---------------------------------------------------------------------------

const BOOL = i32;
const DWORD = u32;
const UINT = u32;
const ATOM = u16;
const LRESULT = isize;
const WPARAM = usize;
const LPARAM = isize;

const HANDLE = *opaque {};
const HINSTANCE = *opaque {};
const HMODULE = *opaque {};
const HWND = *opaque {};
const HDC = *opaque {};
const HGLRC = *opaque {};
const HICON = *opaque {};
const HCURSOR = *opaque {};
const HBRUSH = *opaque {};
const HMENU = *opaque {};
const LPVOID = ?*anyopaque;
const LPCWSTR = [*:0]const u16;
const LPCSTR = [*:0]const u8;

const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.c) LRESULT;

const WNDCLASSEXW = extern struct {
    cbSize: UINT = @sizeOf(WNDCLASSEXW),
    style: UINT = 0,
    lpfnWndProc: ?WNDPROC = null,
    cbClsExtra: c_int = 0,
    cbWndExtra: c_int = 0,
    hInstance: ?HINSTANCE = null,
    hIcon: ?HICON = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?HBRUSH = null,
    lpszMenuName: ?LPCWSTR = null,
    lpszClassName: ?LPCWSTR = null,
    hIconSm: ?HICON = null,
};

const PIXELFORMATDESCRIPTOR = extern struct {
    nSize: u16 = @sizeOf(PIXELFORMATDESCRIPTOR),
    nVersion: u16 = 1,
    dwFlags: DWORD = 0,
    iPixelType: u8 = 0,
    cColorBits: u8 = 0,
    cRedBits: u8 = 0,
    cRedShift: u8 = 0,
    cGreenBits: u8 = 0,
    cGreenShift: u8 = 0,
    cBlueBits: u8 = 0,
    cBlueShift: u8 = 0,
    cAlphaBits: u8 = 0,
    cAlphaShift: u8 = 0,
    cAccumBits: u8 = 0,
    cAccumRedBits: u8 = 0,
    cAccumGreenBits: u8 = 0,
    cAccumBlueBits: u8 = 0,
    cAccumAlphaBits: u8 = 0,
    cDepthBits: u8 = 0,
    cStencilBits: u8 = 0,
    cAuxBuffers: u8 = 0,
    iLayerType: u8 = 0,
    bReserved: u8 = 0,
    dwLayerMask: DWORD = 0,
    dwVisibleMask: DWORD = 0,
    dwDamageMask: DWORD = 0,
};

// ---------------------------------------------------------------------------
// Win32 constants
// ---------------------------------------------------------------------------

const PFD_DOUBLEBUFFER: DWORD = 0x0000_0001;
const PFD_DRAW_TO_WINDOW: DWORD = 0x0000_0004;
const PFD_SUPPORT_OPENGL: DWORD = 0x0000_0020;
const PFD_TYPE_RGBA: u8 = 0;

const WS_POPUP: DWORD = 0x8000_0000;

const CW_USEDEFAULT: c_int = @bitCast(@as(u32, 0x8000_0000));

const GL_VENDOR: u32 = 0x1F00;
const GL_EXTENSIONS: u32 = 0x1F03;

const WGL_CONTEXT_MAJOR_VERSION_ARB: c_int = 0x2091;
const WGL_CONTEXT_MINOR_VERSION_ARB: c_int = 0x2092;
const WGL_CONTEXT_PROFILE_MASK_ARB: c_int = 0x9126;
const WGL_CONTEXT_CORE_PROFILE_BIT_ARB: c_int = 0x0000_0001;

// ---------------------------------------------------------------------------
// Win32 imports
// ---------------------------------------------------------------------------

extern "kernel32" fn GetModuleHandleW(lpModuleName: ?LPCWSTR) callconv(.c) ?HINSTANCE;
extern "kernel32" fn GetModuleHandleA(lpModuleName: ?LPCSTR) callconv(.c) ?HMODULE;
extern "kernel32" fn GetLastError() callconv(.c) u32;
extern "kernel32" fn GetProcAddress(hModule: HMODULE, lpProcName: LPCSTR) callconv(.c) ?*const fn () callconv(.c) void;

extern "user32" fn RegisterClassExW(lpwcx: *const WNDCLASSEXW) callconv(.c) ATOM;
extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD,
    lpClassName: LPCWSTR,
    lpWindowName: LPCWSTR,
    dwStyle: DWORD,
    x: c_int,
    y: c_int,
    nWidth: c_int,
    nHeight: c_int,
    hWndParent: ?HWND,
    hMenu: ?HMENU,
    hInstance: ?HINSTANCE,
    lpParam: LPVOID,
) callconv(.c) ?HWND;
extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.c) BOOL;
extern "user32" fn GetDC(hWnd: ?HWND) callconv(.c) ?HDC;
extern "user32" fn ReleaseDC(hWnd: ?HWND, hDC: HDC) callconv(.c) c_int;
extern "user32" fn DefWindowProcW(hWnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.c) LRESULT;

extern "gdi32" fn ChoosePixelFormat(hdc: HDC, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.c) c_int;
extern "gdi32" fn SetPixelFormat(hdc: HDC, format: c_int, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.c) BOOL;
extern "gdi32" fn SwapBuffers(hdc: HDC) callconv(.c) BOOL;

extern "opengl32" fn wglCreateContext(hdc: HDC) callconv(.c) ?HGLRC;
extern "opengl32" fn wglDeleteContext(hglrc: HGLRC) callconv(.c) BOOL;
extern "opengl32" fn wglMakeCurrent(hdc: ?HDC, hglrc: ?HGLRC) callconv(.c) BOOL;
extern "opengl32" fn wglGetProcAddress(lpszProc: LPCSTR) callconv(.c) ?*const fn () callconv(.c) void;
extern "opengl32" fn glGetString(name: u32) callconv(.c) ?[*:0]const u8;

// ---------------------------------------------------------------------------
// Public API (mirrors egl.zig)
// ---------------------------------------------------------------------------

pub const Error = error{
    NotInitialized,
    BadAccess,
    BadAlloc,
    BadAttribute,
    BadContext,
    BadConfig,
    BadCurrentSurface,
    BadDisplay,
    BadSurface,
    BadMatch,
    BadParameter,
    BadNativePixmap,
    BadNativeWindow,
    ContextLost,
    Unknown,
};

/// The WGL "display" is a hidden window plus its device context. Unlike
/// EGL there is nothing to load up front; the entry points come from the
/// import library.
pub fn load() error{WglInitFailed}!void {}

/// WGL has no equivalent of eglBindAPI; there is only OpenGL.
pub fn bindApi(_: anytype) Error!void {}

/// Wraps `wglGetProcAddress`, falling back to the opengl32 export table
/// for the OpenGL 1.1 entry points, which are not exposed through WGL.
pub fn getProcAddress(name: [*c]const u8) callconv(.c) ?*const fn () callconv(.c) void {
    if (wglGetProcAddress(@ptrCast(name))) |proc| {
        // wglGetProcAddress returns small sentinel values for entry points
        // it does not know rather than null.
        const addr = @intFromPtr(proc);
        if (addr != 1 and addr != 2 and addr != 3 and addr != @as(usize, @bitCast(@as(isize, -1)))) {
            return proc;
        }
    }

    const module = GetModuleHandleA("opengl32.dll") orelse return null;
    return GetProcAddress(module, @ptrCast(name));
}

/// Returns true if `name` appears in the space-separated extension string.
pub fn hasExtension(exts: []const u8, name: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, exts, ' ');
    while (it.next()) |ext| {
        if (std.mem.eql(u8, ext, name)) return true;
    }
    return false;
}

pub const Display = struct {
    hwnd: HWND,
    hdc: HDC,
    class_name: [:0]const u16,

    /// The single pixel format chosen by `Config.choose`. WGL configs are
    /// not separate objects, so the config is stored on the display.
    config: Config = .{ .pixel_format = 0 },

    /// Lazily queried, owned by the display.
    extensions: ?[:0]const u8 = null,

    const class_name_w = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWglHelper");

    pub fn initDefault() Error!*Display {
        const self = std.heap.page_allocator.create(Display) catch return error.BadAlloc;
        errdefer std.heap.page_allocator.destroy(self);

        const hinstance = GetModuleHandleW(null) orelse return error.BadDisplay;

        var wc: WNDCLASSEXW = .{
            .lpfnWndProc = DefWindowProcW,
            .hInstance = hinstance,
            .lpszClassName = class_name_w,
        };
        // The class may already be registered if the process created more
        // than one display; that is not an error.
        _ = RegisterClassExW(&wc);

        const hwnd = CreateWindowExX(
            0,
            class_name_w,
            class_name_w,
            WS_POPUP,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            1,
            1,
            null,
            null,
            hinstance,
            null,
        ) orelse {
            log.err("CreateWindowExW failed error={d}", .{GetLastError()});
            return error.BadNativeWindow;
        };
        errdefer _ = DestroyWindow(hwnd);

        const hdc = GetDC(hwnd) orelse return error.BadNativeWindow;
        errdefer _ = ReleaseDC(hwnd, hdc);

        self.* = .{
            .hwnd = hwnd,
            .hdc = hdc,
            .class_name = class_name_w,
        };
        return self;
    }

    pub fn terminate(self: *Display) void {
        _ = ReleaseDC(self.hwnd, self.hdc);
        _ = DestroyWindow(self.hwnd);
        std.heap.page_allocator.destroy(self);
    }

    const StringQuery = enum { vendor, extensions };

    pub fn queryString(self: *Display, name: StringQuery) ?[:0]const u8 {
        return switch (name) {
            .vendor => if (glGetString(GL_VENDOR)) |v| std.mem.span(v) else null,
            .extensions => self.extensions orelse exts: {
                const v = wglExtensions(self.hdc) orelse break :exts null;
                self.extensions = v;
                break :exts v;
            },
        };
    }

    /// Make the GL context current on the calling thread. `draw` and `read`
    /// are ignored: WGL binds a context to a thread, not to a drawable.
    pub fn makeCurrent(self: *Display, draw: ?*Surface, read: ?*Surface, context: ?*Context) Error!void {
        _ = draw;
        _ = read;

        const hglrc: ?HGLRC = if (context) |ctx| ctx.hglrc else null;
        if (wglMakeCurrent(self.hdc, hglrc) == 0) {
            log.err("wglMakeCurrent failed error={d}", .{GetLastError()});
            return error.BadContext;
        }
    }

    pub fn releaseCurrent(self: *Display) void {
        _ = self;
        _ = wglMakeCurrent(null, null);
    }
};

pub const Config = struct {
    pixel_format: c_int,

    pub fn chooseDefault(display: *Display) Error!*Config {
        var pfd: PIXELFORMATDESCRIPTOR = .{
            .dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER,
            .iPixelType = PFD_TYPE_RGBA,
            .cColorBits = 32,
            .cAlphaBits = 8,
            .cDepthBits = 0,
            .cStencilBits = 0,
        };

        const format = ChoosePixelFormat(display.hdc, &pfd);
        if (format == 0) {
            log.err("ChoosePixelFormat failed error={d}", .{GetLastError()});
            return error.BadConfig;
        }

        if (SetPixelFormat(display.hdc, format, &pfd) == 0) {
            log.err("SetPixelFormat failed error={d}", .{GetLastError()});
            return error.BadConfig;
        }

        display.config = .{ .pixel_format = format };
        return &display.config;
    }
};

pub const Surface = opaque {};

pub const Context = struct {
    hglrc: HGLRC,

    /// Creates an OpenGL 4.3 core profile context.
    ///
    /// A core profile can only be requested through the ARB extension
    /// entry point, which itself requires a current context, so we first
    /// create a legacy context, ask for the extension, and swap.
    pub fn createDefault(display: *Display, config: *Config) Error!*Context {
        _ = config;

        const legacy = wglCreateContext(display.hdc) orelse {
            log.err("wglCreateContext failed error={d}", .{GetLastError()});
            return error.BadContext;
        };
        defer _ = wglDeleteContext(legacy);

        if (wglMakeCurrent(display.hdc, legacy) == 0) {
            log.err("wglMakeCurrent(legacy) failed error={d}", .{GetLastError()});
            return error.BadContext;
        }
        defer _ = wglMakeCurrent(null, null);

        const create_attribs = wglGetProcAddress("wglCreateContextAttribsARB") orelse {
            log.err("wglCreateContextAttribsARB unavailable; a driver " ++
                "supporting OpenGL 3.2 or newer is required", .{});
            return error.BadContext;
        };
        const create: *const fn (HDC, ?HGLRC, [*]const c_int) callconv(.c) ?HGLRC =
            @ptrCast(create_attribs);

        const attribs = [_]c_int{
            WGL_CONTEXT_MAJOR_VERSION_ARB, 4,
            WGL_CONTEXT_MINOR_VERSION_ARB, 3,
            WGL_CONTEXT_PROFILE_MASK_ARB,  WGL_CONTEXT_CORE_PROFILE_BIT_ARB,
            0,
        };
        const hglrc = create(display.hdc, null, &attribs) orelse {
            log.err("wglCreateContextAttribsARB failed error={d}", .{GetLastError()});
            return error.BadContext;
        };
        errdefer _ = wglDeleteContext(hglrc);

        const self = std.heap.page_allocator.create(Context) catch return error.BadAlloc;
        errdefer std.heap.page_allocator.destroy(self);

        self.* = .{ .hglrc = hglrc };
        return self;
    }

    pub fn destroy(self: *Context, display: *Display) Error!void {
        _ = display;
        if (wglDeleteContext(self.hglrc) == 0) return error.BadContext;
        std.heap.page_allocator.destroy(self);
    }
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn CreateWindowExX(
    ex_style: DWORD,
    class_name: [:0]const u16,
    window_name: [:0]const u16,
    style: DWORD,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    parent: ?HWND,
    menu: ?HMENU,
    instance: ?HINSTANCE,
    param: LPVOID,
) ?HWND {
    return CreateWindowExW(
        ex_style,
        class_name.ptr,
        window_name.ptr,
        style,
        x,
        y,
        width,
        height,
        parent,
        menu,
        instance,
        param,
    );
}

/// WGL extension string, via `WGL_ARB_extensions_string`.
fn wglExtensions(hdc: HDC) ?[:0]const u8 {
    const proc = wglGetProcAddress("wglGetExtensionsStringARB") orelse return null;
    const get: *const fn (HDC) callconv(.c) ?[*:0]const u8 = @ptrCast(proc);
    const str = get(hdc) orelse return null;
    return std.mem.span(str);
}

test {
    _ = PIXELFORMATDESCRIPTOR;
    _ = GL_EXTENSIONS;
}
