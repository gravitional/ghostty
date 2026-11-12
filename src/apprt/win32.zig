//! Win32 application runtime for Ghostty on Windows.
//!
//! This is a deliberately small, native Win32 runtime: one window per
//! terminal surface, a classic message loop, and GDI presentation of the
//! CPU frames the OpenGL renderer exports.
//!
//! Rendering never touches the window's device context. The renderer draws
//! into its own framebuffer objects, reads the result back to CPU memory,
//! and this runtime stretches that buffer into the window. That keeps the
//! platform code tiny at the cost of a per-frame copy; a D3D11 swap chain is
//! the natural optimisation once the basics work.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const apprt = @import("../apprt.zig");
const CoreApp = @import("../App.zig");
const CoreSurface = @import("../Surface.zig");
const input = @import("../input.zig");
const configpkg = @import("../config.zig");
const Config = configpkg.Config;
const renderer = @import("../renderer.zig");
const global = @import("../global.zig");
const internal_os = @import("../os/main.zig");

pub const resourcesDir = internal_os.resourcesDir;

const log = std.log.scoped(.win32);

// ---------------------------------------------------------------------------
// Win32 declarations
// ---------------------------------------------------------------------------

const BOOL = i32;
const DWORD = u32;
const UINT = u32;
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;
const LONG_PTR = isize;
const ATOM = u16;

const HANDLE = *opaque {};
const HINSTANCE = *opaque {};
const HWND = *opaque {};
const HDC = *opaque {};
const HMENU = *opaque {};
const HICON = *opaque {};
const HCURSOR = *opaque {};
const HBRUSH = *opaque {};
const LPVOID = ?*anyopaque;
const LPCWSTR = [*:0]const u16;

const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.c) LRESULT;

const POINT = extern struct { x: i32, y: i32 };
const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const MSG = extern struct {
    hwnd: ?HWND = null,
    message: UINT = 0,
    wParam: WPARAM = 0,
    lParam: LPARAM = 0,
    time: DWORD = 0,
    pt: POINT = .{ .x = 0, .y = 0 },
};

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

const BITMAPINFOHEADER = extern struct {
    biSize: DWORD = @sizeOf(BITMAPINFOHEADER),
    biWidth: i32 = 0,
    biHeight: i32 = 0,
    biPlanes: u16 = 1,
    biBitCount: u16 = 32,
    biCompression: DWORD = 0, // BI_RGB
    biSizeImage: DWORD = 0,
    biXPelsPerMeter: i32 = 0,
    biYPelsPerMeter: i32 = 0,
    biClrUsed: DWORD = 0,
    biClrImportant: DWORD = 0,
};

const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER = .{},
    bmiColors: [1]DWORD = .{0},
};

extern "kernel32" fn GetModuleHandleW(lpModuleName: ?LPCWSTR) callconv(.c) ?HINSTANCE;

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
extern "user32" fn DefWindowProcW(hWnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.c) LRESULT;
extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.c) BOOL;
extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: c_int) callconv(.c) BOOL;
extern "user32" fn UpdateWindow(hWnd: HWND) callconv(.c) BOOL;
extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.c) BOOL;
extern "user32" fn GetDC(hWnd: ?HWND) callconv(.c) ?HDC;
extern "user32" fn ReleaseDC(hWnd: ?HWND, hDC: HDC) callconv(.c) c_int;
extern "user32" fn InvalidateRect(hWnd: HWND, lpRect: ?*const RECT, bErase: BOOL) callconv(.c) BOOL;
extern "user32" fn ValidateRect(hWnd: ?HWND, lpRect: ?*const RECT) callconv(.c) BOOL;
extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT) callconv(.c) BOOL;
extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.c) BOOL;
extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.c) LRESULT;
extern "user32" fn PostMessageW(hWnd: ?HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.c) BOOL;
extern "user32" fn PostQuitMessage(nExitCode: c_int) callconv(.c) void;
extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: c_int, dwNewLong: LONG_PTR) callconv(.c) LONG_PTR;
extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: c_int) callconv(.c) LONG_PTR;
extern "user32" fn SetWindowTextW(hWnd: HWND, lpString: LPCWSTR) callconv(.c) BOOL;
extern "user32" fn SetTimer(hWnd: HWND, nIDEvent: usize, uElapse: UINT, lpTimerFunc: ?*const anyopaque) callconv(.c) usize;
extern "user32" fn KillTimer(hWnd: HWND, uIDEvent: usize) callconv(.c) BOOL;
extern "user32" fn SetFocus(hWnd: ?HWND) callconv(.c) ?HWND;
extern "user32" fn SetForegroundWindow(hWnd: HWND) callconv(.c) BOOL;
extern "user32" fn SetWindowPos(
    hWnd: HWND,
    hWndInsertAfter: ?HWND,
    x: c_int,
    y: c_int,
    cx: c_int,
    cy: c_int,
    uFlags: UINT,
) callconv(.c) BOOL;
extern "user32" fn SetProcessDpiAwarenessContext(value: ?*anyopaque) callconv(.c) BOOL;
extern "user32" fn GetDpiForWindow(hWnd: HWND) callconv(.c) UINT;
extern "user32" fn LoadCursorW(hInstance: ?HINSTANCE, lpCursorName: LPCWSTR) callconv(.c) ?HCURSOR;
extern "user32" fn AdjustWindowRectEx(lpRect: *RECT, dwStyle: DWORD, bMenu: BOOL, dwExStyle: DWORD) callconv(.c) BOOL;
extern "user32" fn IsWindowVisible(hWnd: HWND) callconv(.c) BOOL;

extern "gdi32" fn StretchDIBits(
    hdc: HDC,
    xDest: c_int,
    yDest: c_int,
    wDest: c_int,
    hDest: c_int,
    xSrc: c_int,
    ySrc: c_int,
    wSrc: c_int,
    hSrc: c_int,
    lpBits: *const anyopaque,
    lpbmi: *const BITMAPINFO,
    iUsage: UINT,
    rop: DWORD,
) callconv(.c) c_int;

extern "gdi32" fn PatBlt(hdc: HDC, x: c_int, y: c_int, w: c_int, h: c_int, rop: DWORD) callconv(.c) BOOL;

extern "user32" fn GetKeyState(nVirtKey: c_int) callconv(.c) i16;
extern "user32" fn GetKeyboardState(lpKeyState: *[256]u8) callconv(.c) BOOL;
extern "user32" fn ToUnicodeEx(
    wVirtKey: UINT,
    wScanCode: UINT,
    lpKeyState: *const [256]u8,
    pwszBuff: [*]u16,
    cchBuff: c_int,
    wFlags: UINT,
    dwhkl: ?*anyopaque,
) callconv(.c) c_int;
extern "user32" fn MapVirtualKeyW(uCode: UINT, uMapType: UINT) callconv(.c) UINT;

// Window messages we care about.
const WM_DESTROY: UINT = 0x0002;
const WM_SIZE: UINT = 0x0005;
const WM_SETFOCUS: UINT = 0x0007;
const WM_KILLFOCUS: UINT = 0x0008;
const WM_PAINT: UINT = 0x000F;
const WM_CLOSE: UINT = 0x0010;
const WM_TIMER: UINT = 0x0113;
const WM_DPICHANGED: UINT = 0x02E0;
const WM_KEYDOWN: UINT = 0x0100;
const WM_KEYUP: UINT = 0x0101;
const WM_CHAR: UINT = 0x0102;
const WM_SYSKEYDOWN: UINT = 0x0104;
const WM_SYSKEYUP: UINT = 0x0105;
const WM_SYSCHAR: UINT = 0x0106;
const WM_ERASEBKGND: UINT = 0x0014;
const WM_APP_WAKEUP: UINT = 0x8001;

const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF_0000;
const WS_VISIBLE: DWORD = 0x1000_0000;
const CW_USEDEFAULT: c_int = @bitCast(@as(u32, 0x8000_0000));
const SWP_NOZORDER: UINT = 0x0004;

/// DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, a pseudo-handle with the
/// value -4.
const dpi_aware_v2: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -4))));

/// DPI that Windows considers 100% scaling.
const base_dpi: f32 = 96;
const SW_SHOW: c_int = 5;
const GWLP_USERDATA: c_int = -21;
const IDC_ARROW: LPCWSTR = @ptrFromInt(32512);
const SRCCOPY: DWORD = 0x00CC_0020;

const VK_SHIFT: c_int = 0x10;
const VK_CONTROL: c_int = 0x11;
const VK_MENU: c_int = 0x12;
const VK_CAPITAL: c_int = 0x14;
const VK_NUMLOCK: c_int = 0x90;
const VK_F4: UINT = 0x73;
const BLACKNESS: DWORD = 0x0000_0042;

/// Default window size in pixels. The core recomputes its grid from this,
/// so any sane value works; users can resize immediately.
const default_width: i32 = 1024;
const default_height: i32 = 768;

/// Tick interval for core mailbox processing (milliseconds).
const tick_interval_ms: UINT = 16;

/// There is exactly one app runtime per process, so a single module-level
/// pointer keeps the window procedure free of plumbing. This mirrors what
/// most small Win32 apps do.
var app_instance: ?*App = null;

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------

pub const App = struct {
    core_app: *CoreApp,
    config: Config,
    keymap: ?input.Keymap = null,

    /// The first window created. Used for process-wide messages.
    main_hwnd: ?HWND = null,

    pub const Options = struct {};

    /// There is no cross-process IPC channel on Windows yet, so CLI
    /// commands that would talk to a running Ghostty report "not
    /// delivered" instead of pretending to succeed.
    pub fn performIpc(
        _: Allocator,
        _: apprt.ipc.Target,
        comptime action: apprt.ipc.Action.Key,
        _: apprt.ipc.Action.Value(action),
    ) !bool {
        return false;
    }

    pub fn init(
        self: *App,
        core_app: *CoreApp,
        opts: Options,
    ) !void {
        _ = opts;

        // Like the GTK runtime, we own the app-level configuration and load
        // it ourselves; the core only ever sees it through us.
        var config = try Config.load(core_app.alloc);
        errdefer config.deinit();

        self.* = .{
            .core_app = core_app,
            .config = config,
        };

        app_instance = self;
    }

    pub fn terminate(self: *App) void {
        if (self.keymap) |*v| v.deinit();
        self.config.deinit();
        app_instance = null;
    }

    pub fn run(self: *App) !void {
        // Opt into per-monitor DPI scaling before any window exists so
        // that coordinates and fonts are in real device pixels. Without
        // this Windows bitmap-stretches the whole window.
        _ = SetProcessDpiAwarenessContext(dpi_aware_v2);

        // Create the initial window before entering the loop.
        const alloc = self.core_app.alloc;
        const surface = try alloc.create(Surface);
        errdefer alloc.destroy(surface);
        try surface.init(self, .{});
        self.main_hwnd = surface.hwnd;
        // The first ShowWindow call in a process uses STARTUPINFO's show
        // state (often SW_HIDE for console-launched processes), so show
        // again to make sure the window is really visible.
        _ = ShowWindow(surface.hwnd, SW_SHOW);
        _ = ShowWindow(surface.hwnd, SW_SHOW);
        _ = UpdateWindow(surface.hwnd);

        // Claim focus: the process that launched us (a console, Explorer)
        // is usually the foreground window, and Windows allows that
        // process to hand focus to the window it just started.
        _ = SetForegroundWindow(surface.hwnd);
        _ = SetFocus(surface.hwnd);

        _ = SetTimer(surface.hwnd, 1, tick_interval_ms, null);

        var msg: MSG = .{};
        while (true) {
            const res = GetMessageW(&msg, null, 0, 0);
            if (res == 0) break;
            if (res == -1) {
                log.err("GetMessageW failed", .{});
                break;
            }

            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }

        // The core tears its own surface down when the shell exits (it
        // stops the render and IO threads before we get here), so we only
        // release the memory this runtime allocated.
        if (surface.pixels.len > 0) alloc.free(surface.pixels);
        if (surface.title) |title| alloc.free(title);
        alloc.destroy(surface);
    }

    /// Wake up the event loop so the core can process its mailbox.
    pub fn wakeup(self: *const App) void {
        if (self.main_hwnd) |hwnd| {
            _ = PostMessageW(hwnd, WM_APP_WAKEUP, 0, 0);
        }
    }

    pub fn keyboardLayout(self: *App) input.KeyboardLayout {
        _ = self;
        return .us;
    }

    pub fn performAction(
        self: *App,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) !bool {
        _ = self;

        switch (action) {
            .quit => {
                _ = PostQuitMessage(0);
                return true;
            },

            .set_title => {
                if (target == .surface) {
                    target.surface.rt_surface.setTitle(value.title);
                }
                return true;
            },

            .render => {
                // The render thread exported a new frame; ask the window to
                // repaint and pull it in the paint handler.
                if (target == .surface) {
                    _ = InvalidateRect(target.surface.rt_surface.hwnd, null, 0);
                }
                return true;
            },

            else => return false,
        }
    }
};

// ---------------------------------------------------------------------------
// Surface
// ---------------------------------------------------------------------------

pub const Surface = struct {
    app: *App,
    core_surface: CoreSurface,
    hwnd: HWND,
    size: apprt.SurfaceSize,
    content_scale: apprt.ContentScale,
    cursor_pos: apprt.CursorPos,
    title: ?[:0]const u8 = null,

    /// Scratch buffer for the BGRA, top-down copy we hand to GDI.
    pixels: []u8 = &.{},

    /// Frames presented so far, for rate-limited diagnostics.
    frame_count: u32 = 0,

    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWin32");

    pub const Options = struct {
        working_directory: ?[]const u8 = null,
        font_size: f32 = 0,
    };

    pub fn init(self: *Surface, app: *App, opts: Options) !void {
        _ = opts;

        self.* = .{
            .app = app,
            .core_surface = undefined,
            .hwnd = undefined,
            .size = .{ .width = default_width, .height = default_height },
            .content_scale = .{ .x = 1, .y = 1 },
            .cursor_pos = .{ .x = -1, .y = -1 },
        };

        // Register the window class. Re-registering is harmless.
        const hinstance = GetModuleHandleW(null);
        var wc: WNDCLASSEXW = .{
            .lpfnWndProc = windowProc,
            .hInstance = hinstance,
            .hCursor = LoadCursorW(null, IDC_ARROW),
            .lpszClassName = class_name,
        };
        _ = RegisterClassExW(&wc);

        var rect: RECT = .{
            .left = 0,
            .top = 0,
            .right = @intCast(self.size.width),
            .bottom = @intCast(self.size.height),
        };
        _ = AdjustWindowRectEx(&rect, WS_OVERLAPPEDWINDOW, 0, 0);

        const hwnd = CreateWindowExW(
            0,
            class_name,
            std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
            WS_OVERLAPPEDWINDOW | WS_VISIBLE,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            rect.right - rect.left,
            rect.bottom - rect.top,
            null,
            null,
            hinstance,
            self,
        ) orelse return error.WindowCreateFailed;
        errdefer _ = DestroyWindow(hwnd);
        self.hwnd = hwnd;

        _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, @bitCast(@intFromPtr(self)));

        const dpi = GetDpiForWindow(hwnd);
        if (dpi > 0) {
            const scale = @as(f32, @floatFromInt(dpi)) / base_dpi;
            self.content_scale = .{ .x = scale, .y = scale };
        }

        // Register with the core before initializing so that callbacks can
        // find us.
        try app.core_app.addSurface(self);
        errdefer app.core_app.deleteSurface(self);

        var config = try apprt.surface.newConfig(app.core_app, &app.config, .window);
        defer config.deinit();

        try self.core_surface.init(
            app.core_app.alloc,
            &config,
            app.core_app,
            app,
            self,
        );
        errdefer self.core_surface.deinit();
    }

    pub fn deinit(self: *Surface) void {
        if (self.title) |v| self.app.core_app.alloc.free(v);
        self.app.core_app.deleteSurface(self);
        self.core_surface.deinit();
        if (self.pixels.len > 0) self.app.core_app.alloc.free(self.pixels);
    }

    pub fn core(self: *Surface) *CoreSurface {
        return &self.core_surface;
    }

    pub fn rtApp(self: *const Surface) *App {
        return self.app;
    }

    pub fn close(self: *const Surface, process_alive: bool) void {
        _ = process_alive;
        _ = DestroyWindow(self.hwnd);
    }

    pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
        return self.content_scale;
    }

    pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
        return self.size;
    }

    pub fn getTitle(self: *Surface) ?[:0]const u8 {
        return self.title;
    }

    pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
        return self.cursor_pos;
    }

    pub fn supportsClipboard(self: *const Surface, clipboard_type: apprt.Clipboard) bool {
        _ = self;
        return clipboard_type == .standard;
    }

    /// Clipboard reads are not implemented yet; callers treat the error as
    /// "nothing to paste" rather than hanging on a request that will never
    /// complete.
    pub fn clipboardRequest(
        self: *Surface,
        clipboard_type: apprt.Clipboard,
        state: apprt.ClipboardRequest,
    ) !apprt.ClipboardReadResult {
        _ = self;
        _ = clipboard_type;
        _ = state;
        return error.Unsupported;
    }

    pub fn setClipboard(
        self: *Surface,
        clipboard_type: apprt.Clipboard,
        contents: []const apprt.ClipboardContent,
        confirm: bool,
    ) !void {
        _ = self;
        _ = clipboard_type;
        _ = contents;
        _ = confirm;
        return error.Unsupported;
    }

    pub fn refresh(self: *Surface) void {
        self.core_surface.refreshCallback() catch |err| {
            log.err("error in refresh callback err={}", .{err});
        };
    }

    pub fn draw(self: *Surface) void {
        self.core_surface.draw() catch |err| {
            log.err("error in draw err={}", .{err});
        };
    }

    pub fn defaultTermioEnv(self: *const Surface) !std.process.Environ.Map {
        _ = self;
        return try global.environMap();
    }

    pub fn renderDeviceOptions(self: *const Surface) !renderer.Device.Options {
        _ = self;
        return .{};
    }

    pub fn updateContentScale(self: *Surface, x: f64, y: f64) void {
        self.content_scale = .{
            .x = @floatCast(@max(1, x)),
            .y = @floatCast(@max(1, y)),
        };
        self.core_surface.contentScaleCallback(self.content_scale) catch |err| {
            log.err("error in content scale callback err={}", .{err});
        };
    }

    pub fn updateSize(self: *Surface, width: u32, height: u32) void {
        if (self.size.width == width and self.size.height == height) return;
        if (width == 0 or height == 0) return;

        self.size = .{ .width = width, .height = height };
        self.core_surface.sizeCallback(self.size) catch |err| {
            log.err("error in size callback err={}", .{err});
        };
    }

    pub fn setTitle(self: *Surface, title: [:0]const u8) void {
        const alloc = self.app.core_app.alloc;
        if (self.title) |v| alloc.free(v);

        const owned = alloc.dupeSentinel(u8, title, 0) catch return;
        self.title = owned;

        const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, owned) catch return;
        defer alloc.free(wide);
        _ = SetWindowTextW(self.hwnd, wide.ptr);
    }

    /// Translate a Win32 virtual key into a core key event.
    ///
    /// Text is generated here rather than from WM_CHAR so that the core
    /// sees one event carrying both the physical key and the produced
    /// text, which is what its key encoder expects for things like
    /// Ctrl+C (physical `c` plus text is what makes 0x03).
    fn handleKey(self: *Surface, vk: u32, extended: bool, action: input.Action) bool {
        const mods = currentMods();

        var text_buf: [8]u8 = undefined;
        const text: []const u8 = switch (action) {
            .press, .repeat => textForVk(vk, mods, &text_buf),
            .release => "",
        };

        const event: input.KeyEvent = .{
            .action = action,
            .key = keyFromVk(vk, extended),
            .mods = mods,
            // Shift is consumed when it changed the produced character.
            .consumed_mods = .{ .shift = mods.shift and text.len > 0 },
            .utf8 = text,
        };

        const effect = self.core_surface.keyCallback(event) catch |err| {
            log.err("key callback failed err={}", .{err});
            return false;
        };
        return effect == .consumed;
    }

    /// Pull the latest exported frame and blit it into the window.
    fn presentFrame(self: *Surface) void {
        const frame = self.core_surface.renderer.takeFrame() orelse {
            log.debug("paint with no frame available", .{});
            return;
        };
        defer frame.deinit();

        switch (frame) {
            .memory => |m| {
                self.blit(m);
            },
            // There is no DMABUF path on Windows.
            .dmabuf => {},
        }
    }

    fn blit(self: *Surface, m: renderer.OpenGL.ExportedFrame.Memory) void {
        const alloc = self.app.core_app.alloc;
        const len = @as(usize, m.width) * @as(usize, m.height) * 4;

        if (self.pixels.len != len) {
            if (self.pixels.len > 0) alloc.free(self.pixels);
            self.pixels = alloc.alloc(u8, len) catch {
                self.pixels = &.{};
                return;
            };
        }

        // `readPixels` returns bottom-up RGBA; GDI wants top-down BGRA.
        const src_stride = @as(usize, m.width) * 4;
        const dst_stride = src_stride;
        var y: usize = 0;
        while (y < m.height) : (y += 1) {
            const src_row = m.pixels[(m.height - 1 - y) * src_stride ..][0..src_stride];
            const dst_row = self.pixels[y * dst_stride ..][0..dst_stride];
            var x: usize = 0;
            while (x < src_stride) : (x += 4) {
                dst_row[x + 0] = src_row[x + 2];
                dst_row[x + 1] = src_row[x + 1];
                dst_row[x + 2] = src_row[x + 0];
                dst_row[x + 3] = src_row[x + 3];
            }
        }

        self.presentPixels(m.width, m.height);
    }

    fn presentPixels(self: *Surface, width: u32, height: u32) void {
        const hdc = GetDC(self.hwnd) orelse return;
        defer _ = ReleaseDC(self.hwnd, hdc);

        var bmi: BITMAPINFO = .{};
        bmi.bmiHeader.biWidth = @intCast(width);
        bmi.bmiHeader.biHeight = -@as(i32, @intCast(height));
        bmi.bmiHeader.biSizeImage = width * height * 4;

        const res = StretchDIBits(
            hdc,
            0,
            0,
            @intCast(width),
            @intCast(height),
            0,
            0,
            @intCast(width),
            @intCast(height),
            self.pixels.ptr,
            &bmi,
            0, // DIB_RGB_COLORS
            SRCCOPY,
        );
        if (res <= 0) log.err("StretchDIBits failed res={d}", .{res});
    }

    fn clearBackground(self: *Surface) void {
        const hdc = GetDC(self.hwnd) orelse return;
        defer _ = ReleaseDC(self.hwnd, hdc);

        var rect: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        if (GetClientRect(self.hwnd, &rect) == 0) return;
        _ = PatBlt(hdc, 0, 0, rect.right, rect.bottom, BLACKNESS);
    }
};

// ---------------------------------------------------------------------------
// Window procedure
// ---------------------------------------------------------------------------

fn windowProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.c) LRESULT {
    const self = surfaceFromWindow(hwnd) orelse return DefWindowProcW(hwnd, msg, wParam, lParam);

    switch (msg) {
        WM_SIZE => {
            const width: u32 = @as(u16, @truncate(@as(usize, @bitCast(lParam))));
            const height: u32 = @intCast((@as(usize, @bitCast(lParam)) >> 16) & 0xFFFF);
            self.updateSize(width, height);
            return 0;
        },

        WM_KEYDOWN, WM_SYSKEYDOWN => {
            const vk: u32 = @intCast(wParam & 0xFFFF);

            // Let the system handle Alt+F4 and friends.
            if (msg == WM_SYSKEYDOWN and vk == VK_F4) {
                return DefWindowProcW(hwnd, msg, wParam, lParam);
            }

            const repeat = (lParam & (@as(LPARAM, 1) << 30)) != 0;
            const extended = (lParam & (@as(LPARAM, 1) << 24)) != 0;
            _ = self.handleKey(vk, extended, if (repeat) .repeat else .press);
            return 0;
        },

        WM_KEYUP, WM_SYSKEYUP => {
            const vk: u32 = @intCast(wParam & 0xFFFF);
            if (msg == WM_SYSKEYUP and vk == VK_F4) {
                return DefWindowProcW(hwnd, msg, wParam, lParam);
            }

            const extended = (lParam & (@as(LPARAM, 1) << 24)) != 0;
            _ = self.handleKey(vk, extended, .release);
            return 0;
        },

        // Text already travelled with the key event above; swallowing
        // WM_CHAR keeps it from being inserted twice.
        WM_CHAR, WM_SYSCHAR => return 0,

        WM_DPICHANGED => {
            const new_dpi: u32 = @intCast(wParam & 0xFFFF);
            const scale: f64 = @as(f64, @floatFromInt(new_dpi)) / base_dpi;
            self.updateContentScale(scale, scale);

            // Windows suggests the new outer rect for this DPI; honour it.
            const suggested: *const RECT = @ptrFromInt(@as(usize, @bitCast(lParam)));
            _ = SetWindowPos(
                hwnd,
                null,
                suggested.left,
                suggested.top,
                suggested.right - suggested.left,
                suggested.bottom - suggested.top,
                SWP_NOZORDER,
            );
            return 0;
        },

        WM_SETFOCUS => {
            self.core_surface.focusCallback(true) catch {};
            return 0;
        },

        WM_KILLFOCUS => {
            self.core_surface.focusCallback(false) catch {};
            return 0;
        },

        WM_PAINT => {
            self.presentFrame();
            _ = ValidateRect(hwnd, null);
            return 0;
        },

        WM_ERASEBKGND => {
            self.clearBackground();
            return 1;
        },

        WM_TIMER => {
            if (app_instance) |app| {
                app.core_app.tick(app) catch |err| {
                    log.err("core tick failed err={}", .{err});
                };
            }
            return 0;
        },

        WM_APP_WAKEUP => {
            if (app_instance) |app| {
                app.core_app.tick(app) catch |err| {
                    log.err("core tick failed err={}", .{err});
                };
            }
            return 0;
        },

        WM_CLOSE => {
            self.core_surface.close();
            return 0;
        },

        WM_DESTROY => {
            if (app_instance) |app| {
                if (app.main_hwnd == hwnd) {
                    _ = KillTimer(hwnd, 1);
                    app.main_hwnd = null;
                    PostQuitMessage(0);
                }
            }
            return 0;
        },

        else => {},
    }

    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

fn surfaceFromWindow(hwnd: HWND) ?*Surface {
    const value = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (value == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(value)));
}

/// The modifier state for the current input message.
fn currentMods() input.Mods {
    var mods: input.Mods = .{};
    mods.shift = (GetKeyState(VK_SHIFT) & @as(i16, @bitCast(@as(u16, 0x8000)))) != 0;
    mods.ctrl = (GetKeyState(VK_CONTROL) & @as(i16, @bitCast(@as(u16, 0x8000)))) != 0;
    mods.alt = (GetKeyState(VK_MENU) & @as(i16, @bitCast(@as(u16, 0x8000)))) != 0;
    mods.super = (GetKeyState(0x5B) & @as(i16, @bitCast(@as(u16, 0x8000)))) != 0 or
        (GetKeyState(0x5C) & @as(i16, @bitCast(@as(u16, 0x8000)))) != 0;
    mods.caps_lock = (GetKeyState(VK_CAPITAL) & 1) != 0;
    mods.num_lock = (GetKeyState(VK_NUMLOCK) & 1) != 0;
    return mods;
}

/// Map a Win32 virtual key to the physical key the core understands. The
/// keycode table carries the Windows VK column for exactly this purpose.
fn keyFromVk(vk: u32, extended: bool) input.Key {
    // The keycode table's Windows column holds scan codes (with the 0xE0
    // prefix for extended keys), not virtual key codes.
    const base = MapVirtualKeyW(vk, 0);
    const scan: u32 = if (extended and base != 0) 0xE000 | base else base;

    for (input.keycodes.entries) |entry| {
        if (entry.native == scan) return entry.key;
    }

    // Some keys are not flagged extended by Windows but the table only
    // carries one form; accept the base code as a fallback.
    for (input.keycodes.entries) |entry| {
        if (entry.native == base) return entry.key;
    }

    return .unidentified;
}

/// The UTF-8 text produced by pressing `vk` with the given modifiers.
///
/// Control and Alt combos produce no text: the core derives their encoding
/// from the physical key so that Ctrl+C becomes 0x03 rather than "c".
fn textForVk(vk: u32, mods: input.Mods, buf: *[8]u8) []const u8 {
    if (mods.ctrl or mods.alt or mods.super) return "";

    var state: [256]u8 = undefined;
    if (GetKeyboardState(&state) == 0) return "";

    // ToUnicodeEx only accepts 0 or 1 for the toggle keys.
    state[@intCast(VK_CAPITAL)] &= 1;
    state[@intCast(VK_NUMLOCK)] &= 1;

    var wide: [8]u16 = undefined;
    const n = ToUnicodeEx(
        vk,
        MapVirtualKeyW(vk, 0),
        &state,
        &wide,
        wide.len,
        0,
        null,
    );
    if (n <= 0) return "";

    const len: usize = @min(@as(usize, @intCast(n)), wide.len);
    const cp_len = std.unicode.utf16LeToUtf8(buf, wide[0..len]) catch return "";
    if (cp_len == 0) return "";

    // Control characters are encoded from the key, not as text.
    if (buf[0] < 0x20) return "";

    return buf[0..cp_len];
}

test {
    _ = App;
    _ = Surface;
}
