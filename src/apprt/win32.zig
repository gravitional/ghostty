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
const HIMC = *opaque {};
const HCURSOR = *opaque {};
const HBRUSH = *opaque {};
const LPVOID = ?*anyopaque;
const LPCWSTR = [*:0]const u16;

const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.c) LRESULT;

const POINT = extern struct { x: i32, y: i32 };
const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const PAINTSTRUCT = extern struct {
    hdc: ?HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]u8,
};

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

const GWL_STYLE: c_int = -16;
const WS_CAPTION: DWORD = 0x00C0_0000;
const WS_THICKFRAME: DWORD = 0x0004_0000;
const SWP_FRAMECHANGED: UINT = 0x0020;
const SWP_SHOWWINDOW: UINT = 0x0040;
const MONITOR_DEFAULTTONEAREST: DWORD = 2;

const MONITORINFO = extern struct {
    cbSize: DWORD,
    rcMonitor: RECT,
    rcWork: RECT,
    dwFlags: DWORD,
};

extern "user32" fn GetWindowRect(hWnd: HWND, lpRect: *RECT) callconv(.c) BOOL;
extern "user32" fn MonitorFromWindow(hWnd: HWND, dwFlags: DWORD) callconv(.c) HWND;
extern "user32" fn GetMonitorInfoW(hMonitor: HWND, lpmi: *MONITORINFO) callconv(.c) BOOL;
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
extern "user32" fn GetSystemMetrics(nIndex: c_int) callconv(.c) c_int;
extern "user32" fn SendMessageW(hWnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.c) LRESULT;
extern "user32" fn MoveWindow(hWnd: HWND, x: c_int, y: c_int, w: c_int, h: c_int, repaint: BOOL) callconv(.c) BOOL;
extern "user32" fn ClientToScreen(hWnd: HWND, lpPoint: *POINT) callconv(.c) BOOL;
extern "comctl32" fn InitCommonControlsEx(picce: *const INITCOMMONCONTROLSEX) callconv(.c) BOOL;

const INITCOMMONCONTROLSEX = extern struct {
    dwSize: DWORD,
    dwICC: DWORD,
};

const ICC_TAB_CLASSES: DWORD = 0x0008;
const TCS_FOCUSNEVER: DWORD = 0x0001;
const TCM_INSERTITEMW: UINT = 0x1307;
const TCM_DELETEITEM: UINT = 0x1308;
const TCM_GETCOUNT: UINT = 0x1304;
const TCM_GETITEMW: UINT = 0x1305;
const TCM_SETITEMW: UINT = 0x1306;
const TCM_GETCURSEL: UINT = 0x130B;
const TCM_SETCURSEL: UINT = 0x130C;
const TCM_SETITEMSIZE: UINT = 0x1329;
const TCIF_TEXT: UINT = 0x0001;
const TCN_SELCHANGE: UINT = @bitCast(@as(i32, -551));
const WM_NOTIFY: UINT = 0x004E;

const NMHDR = extern struct {
    hwndFrom: HWND,
    idFrom: usize,
    code: UINT,
};

const TCITEMW = extern struct {
    mask: UINT = 0,
    dwState: DWORD = 0,
    dwStateMask: DWORD = 0,
    pszText: ?LPWSTR = null,
    cchTextMax: c_int = 0,
    iImage: c_int = 0,
    lParam: LPARAM = 0,
};

extern "kernel32" fn CreateNamedPipeW(
    lpName: LPCWSTR,
    dwOpenMode: DWORD,
    dwPipeMode: DWORD,
    nMaxInstances: DWORD,
    nOutBufferSize: DWORD,
    nInBufferSize: DWORD,
    nDefaultTimeOut: DWORD,
    lpSecurityAttributes: ?*anyopaque,
) callconv(.c) HANDLE;
extern "kernel32" fn ConnectNamedPipe(hNamedPipe: HANDLE, lpOverlapped: ?*anyopaque) callconv(.c) BOOL;
extern "kernel32" fn DisconnectNamedPipe(hNamedPipe: HANDLE) callconv(.c) BOOL;
extern "kernel32" fn ReadFile(
    hFile: HANDLE,
    lpBuffer: ?*anyopaque,
    nNumberOfBytesToRead: DWORD,
    lpNumberOfBytesRead: ?*DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.c) BOOL;
extern "kernel32" fn WriteFile(
    hFile: HANDLE,
    lpBuffer: ?*const anyopaque,
    nNumberOfBytesToWrite: DWORD,
    lpNumberOfBytesWritten: ?*DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.c) BOOL;
extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.c) BOOL;
extern "kernel32" fn GetLastError() callconv(.c) u32;
extern "kernel32" fn CreateFileW(
    lpFileName: LPCWSTR,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: ?HANDLE,
) callconv(.c) HANDLE;

const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
const PIPE_ACCESS_INBOUND: DWORD = 0x0000_0001;
const PIPE_TYPE_MESSAGE: DWORD = 0x0000_0004;
const PIPE_READMODE_MESSAGE: DWORD = 0x0000_0002;
const PIPE_WAIT: DWORD = 0x0000_0000;
const GENERIC_WRITE: DWORD = 0x4000_0000;
const OPEN_EXISTING: DWORD = 3;

/// Posted by the IPC thread to the main window with the action tag in
/// `wParam`.
const WM_APP_IPC: UINT = 0x8000 + 2;

/// Named pipe the first instance listens on.
const ipc_pipe_name = std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\ghostty-win32");

const IpcTag = enum(u32) {
    new_window = 1,
    new_tab = 2,
};

extern "imm32" fn ImmGetContext(hWnd: HWND) callconv(.c) ?HIMC;
extern "imm32" fn ImmReleaseContext(hWnd: HWND, hIMC: HIMC) callconv(.c) BOOL;
extern "imm32" fn ImmGetCompositionStringW(
    hIMC: HIMC,
    dwIndex: DWORD,
    lpBuf: ?*anyopaque,
    dwBufLen: DWORD,
) callconv(.c) i32;
extern "user32" fn SetCapture(hWnd: HWND) callconv(.c) ?HWND;
extern "user32" fn OpenClipboard(hWndNewOwner: ?HWND) callconv(.c) BOOL;
extern "user32" fn CloseClipboard() callconv(.c) BOOL;
extern "user32" fn EmptyClipboard() callconv(.c) BOOL;
extern "user32" fn GetClipboardData(uFormat: UINT) callconv(.c) ?HANDLE;
extern "user32" fn SetClipboardData(uFormat: UINT, hMem: HANDLE) callconv(.c) ?HANDLE;
extern "kernel32" fn GlobalAlloc(uFlags: UINT, dwBytes: usize) callconv(.c) ?HANDLE;
extern "kernel32" fn GlobalLock(hMem: HANDLE) callconv(.c) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(hMem: HANDLE) callconv(.c) BOOL;
extern "kernel32" fn GlobalFree(hMem: HANDLE) callconv(.c) ?HANDLE;
extern "user32" fn ReleaseCapture() callconv(.c) BOOL;
extern "user32" fn LoadCursorW(hInstance: ?HINSTANCE, lpCursorName: LPCWSTR) callconv(.c) ?HCURSOR;
extern "user32" fn AdjustWindowRectEx(lpRect: *RECT, dwStyle: DWORD, bMenu: BOOL, dwExStyle: DWORD) callconv(.c) BOOL;
extern "user32" fn IsWindowVisible(hWnd: HWND) callconv(.c) BOOL;
extern "user32" fn IsZoomed(hWnd: HWND) callconv(.c) BOOL;

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

extern "gdi32" fn GetStockObject(i: c_int) callconv(.c) ?HANDLE;
extern "gdi32" fn SelectObject(hdc: HDC, h: ?HANDLE) callconv(.c) ?HANDLE;
extern "gdi32" fn DeleteObject(h: ?HANDLE) callconv(.c) BOOL;
extern "gdi32" fn SetBkMode(hdc: HDC, mode: c_int) callconv(.c) c_int;
extern "gdi32" fn SetTextColor(hdc: HDC, color: DWORD) callconv(.c) DWORD;
extern "gdi32" fn CreateSolidBrush(color: DWORD) callconv(.c) ?HANDLE;
extern "user32" fn FillRect(hdc: HDC, rect: *const RECT, brush: ?HANDLE) callconv(.c) c_int;
extern "user32" fn GetSysColor(index: c_int) callconv(.c) DWORD;
extern "user32" fn DrawTextW(hdc: HDC, text: [*]const u16, len: c_int, rect: *RECT, flags: UINT) callconv(.c) c_int;
extern "user32" fn BeginPaint(hwnd: HWND, ps: *PAINTSTRUCT) callconv(.c) ?HDC;
extern "user32" fn EndPaint(hwnd: HWND, ps: *const PAINTSTRUCT) callconv(.c) BOOL;

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
const WS_CHILD: DWORD = 0x4000_0000;
const WS_POPUP: DWORD = 0x8000_0000;
const WS_CLIPSIBLINGS: DWORD = 0x0400_0000;
const WS_CLIPCHILDREN: DWORD = 0x0200_0000;
const SWP_NOSIZE: UINT = 0x0001;
const SWP_NOMOVE: UINT = 0x0002;
const WS_EX_TOOLWINDOW: DWORD = 0x0000_0080;
const WM_MOVE: UINT = 0x0003;
const HWND_TOP: ?HWND = @ptrFromInt(0);
const LPWSTR = [*:0]u16;

const WM_CLOSE: UINT = 0x0010;
const WM_TIMER: UINT = 0x0113;
const WM_DPICHANGED: UINT = 0x02E0;
const WM_KEYDOWN: UINT = 0x0100;
const WM_KEYUP: UINT = 0x0101;
const WM_CHAR: UINT = 0x0102;
const WM_MOUSEMOVE: UINT = 0x0200;
const WM_LBUTTONDOWN: UINT = 0x0201;
const WM_LBUTTONUP: UINT = 0x0202;
const WM_RBUTTONDOWN: UINT = 0x0204;
const WM_RBUTTONUP: UINT = 0x0205;
const WM_MBUTTONDOWN: UINT = 0x0207;
const WM_MBUTTONUP: UINT = 0x0208;
const WM_MOUSEWHEEL: UINT = 0x020A;
const WM_XBUTTONDOWN: UINT = 0x020B;
const WM_XBUTTONUP: UINT = 0x020C;
const WM_SYSKEYDOWN: UINT = 0x0104;
const WM_SYSKEYUP: UINT = 0x0105;
const WM_SYSCHAR: UINT = 0x0106;
const WM_ERASEBKGND: UINT = 0x0014;
const WM_APP_WAKEUP: UINT = 0x8001;

const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF_0000;
const WS_VISIBLE: DWORD = 0x1000_0000;
const SWP_NOZORDER: UINT = 0x0004;

/// DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, a pseudo-handle with the
/// value -4.
const dpi_aware_v2: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -4))));

/// DPI that Windows considers 100% scaling.
const base_dpi: f32 = 96;
const SW_SHOW: c_int = 5;
const SW_HIDE: c_int = 0;
const GWLP_USERDATA: c_int = -21;
const IDC_ARROW: LPCWSTR = @ptrFromInt(32512);
const SRCCOPY: DWORD = 0x00CC_0020;

const WM_IME_SETCONTEXT: UINT = 0x0281;
const WM_IME_STARTCOMPOSITION: UINT = 0x010D;
const WM_IME_ENDCOMPOSITION: UINT = 0x010E;
const WM_IME_COMPOSITION: UINT = 0x010F;

/// Ask the IME not to draw its own composition window; Ghostty renders
/// the preedit inline in the terminal grid.
const ISC_SHOWUICOMPOSITIONWINDOW: LPARAM = 0x8000_0000;

const GCS_COMPSTR: DWORD = 0x0008;
const GCS_RESULTSTR: DWORD = 0x0800;

/// Windows reports this virtual key for keys the IME already consumed.
const VK_PROCESSKEY: u32 = 0xE5;

const CF_UNICODETEXT: UINT = 13;
const GMEM_MOVEABLE: UINT = 0x0002;

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

    /// Every open window.
    frames: std.ArrayListUnmanaged(*Frame) = .empty,

    /// Every open surface, across all windows.
    surfaces: std.ArrayListUnmanaged(*Surface) = .empty,

    /// Configurations replaced by a reload. Surfaces may keep references
    /// into the config they were updated with, so the replaced ones are only
    /// released when the app shuts down.
    retired_configs: std.ArrayListUnmanaged(Config) = .empty,

    /// Surfaces whose window is gone. The core may still hold references to
    /// them while it tears its own state down and while it runs callbacks
    /// from other threads, so the memory is only released at shutdown.
    /// Freeing it here crashed the process as soon as another window was
    /// created after closing a pane.
    retired_surfaces: std.ArrayListUnmanaged(*Surface) = .empty,

    pub const Options = struct {};

    /// There is no cross-process IPC channel on Windows yet, so CLI
    /// commands that would talk to a running Ghostty report "not
    /// delivered" instead of pretending to succeed.
    pub fn performIpc(
        _: Allocator,
        _: apprt.ipc.Target,
        comptime action: apprt.ipc.Action.Key,
        value: apprt.ipc.Action.Value(action),
    ) !bool {
        // Only actions this runtime can carry out are forwarded. Returning
        // false lets the CLI report that the action is unsupported rather
        // than pretending it was delivered.
        const tag: IpcTag = switch (action) {
            .new_window => .new_window,
            .new_tab => .new_tab,
            else => return false,
        };

        const file = CreateFileW(
            ipc_pipe_name,
            GENERIC_WRITE,
            0,
            null,
            OPEN_EXISTING,
            0,
            null,
        );
        if (file == INVALID_HANDLE_VALUE) return false;
        defer _ = CloseHandle(file);

        // Only the working directory is forwarded; other arguments are
        // still ignored.
        var directory: ?[]const u8 = null;
        if (value.arguments) |arguments| {
            for (arguments) |argument| {
                if (std.mem.startsWith(u8, argument, "--working-directory=")) {
                    directory = argument["--working-directory=".len..];
                    break;
                }
            }
        }

        const payload_len: usize = if (directory) |dir| dir.len else 0;
        const buf = std.heap.page_allocator.alloc(u8, 8 + payload_len) catch return false;
        defer std.heap.page_allocator.free(buf);

        std.mem.writeInt(u32, buf[0..4], @backingInt(tag), .little);
        std.mem.writeInt(u32, buf[4..8], @intCast(payload_len), .little);
        if (directory) |dir| @memcpy(buf[8..], dir);

        var written: DWORD = 0;
        if (WriteFile(file, buf.ptr, @intCast(buf.len), &written, null) == 0) return false;
        return written == buf.len;
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
        // The manifest already declares PerMonitorV2, so this normally
        // fails with access denied; call it anyway for builds that do not
        // carry the manifest.
        _ = SetProcessDpiAwarenessContext(dpi_aware_v2);

        // Create the initial window before entering the loop.
        _ = try self.createFrame(null);

        // Accept commands from other processes (`ghostty +new-window`).
        // The thread lives for the process lifetime; it blocks on
        // ConnectNamedPipe and has no clean shutdown, which is fine because
        // the process exit tears it down.
        if (std.Thread.spawn(.{}, ipcServerMain, .{self})) |thread| {
            thread.detach();
        } else |err| {
            log.warn("failed to start IPC thread err={}", .{err});
        }

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

        // Windows that were not closed through the normal path (a `.quit`
        // action, for example) still own runtime memory. Destroying a frame
        // closes its tabs, which frees everything.
        while (self.frames.items.len > 0) {
            _ = DestroyWindow(self.frames.items[0].hwnd);
        }
    }

    /// Create, show and focus a new window with one tab.
    fn createFrame(self: *App, working_directory: ?[]const u8) !*Frame {
        const frame = try Frame.create(self);
        errdefer self.destroyFrame(frame);

        // Show the frame before creating its first pane so the popup is
        // positioned and visible from the moment GL starts presenting.
        _ = ShowWindow(frame.hwnd, SW_SHOW);
        _ = ShowWindow(frame.hwnd, SW_SHOW);
        _ = UpdateWindow(frame.hwnd);

        try self.addTab(frame, working_directory);

        _ = SetForegroundWindow(frame.hwnd);
        _ = SetFocus(frame.hwnd);

        // One timer drives the core tick for the whole process, so it is
        // owned by the main window.
        if (self.main_hwnd == null) {
            self.main_hwnd = frame.hwnd;
            _ = SetTimer(frame.hwnd, 1, tick_interval_ms, null);
        }

        return frame;
    }

    /// Add a tab (with one pane) to `frame` and focus it.
    fn addTab(self: *App, frame: *Frame, working_directory: ?[]const u8) !void {
        try frame.addTab();
        _ = try self.createPane(frame, frame.tabs.items.len - 1, working_directory, .right);
    }

    /// Add a pane to an existing tab.
    fn createPane(
        self: *App,
        frame: *Frame,
        tab_index: usize,
        working_directory: ?[]const u8,
        direction: apprt.action.SplitDirection,
    ) !*Surface {
        const alloc = self.core_app.alloc;

        const surface = try alloc.create(Surface);
        errdefer alloc.destroy(surface);

        try surface.init(self, .{
            .owner = frame.hwnd,
            .rect = frame.contentRect(),
            .working_directory = working_directory,
        });
        errdefer alloc.destroy(surface);

        try self.surfaces.append(alloc, surface);
        errdefer _ = self.surfaces.pop();

        try frame.tabs.items[tab_index].panes.append(alloc, surface);
        try frame.tabs.items[tab_index].dirs.append(alloc, direction);

        // The new pane is the one the user asked for, so focus it.
        frame.tabs.items[tab_index].active = frame.tabs.items[tab_index].panes.items.len - 1;
        surface.frame = frame;

        // The core reports its initial title while the surface is still
        // initializing, before it knows which window it belongs to, so the
        // label is applied here instead.
        if (surface.title) |title| {
            frame.setTitle(surface, std.mem.sliceTo(title, 0));
        }

        frame.selectTab(tab_index);
        frame.layoutTab(tab_index);

        // Ask for a frame now that the pane is placed and on screen. The
        // pane must not be moved here: layoutTab already positioned it, and
        // resizing it to the whole content area would undo a split.
        _ = ShowWindow(surface.hwnd, SW_SHOW);
        surface.core_surface.refreshCallback() catch {};

        return surface;
    }

    /// Release a surface after its window has been destroyed.
    fn destroySurface(self: *App, surface: *Surface) void {
        const alloc = self.core_app.alloc;

        for (self.surfaces.items, 0..) |item, i| {
            if (item == surface) {
                _ = self.surfaces.swapRemove(i);
                break;
            }
        }

        if (surface.frame) |frame| frame.removeSurface(surface);

        if (surface.working_directory) |dir| alloc.free(dir);
        if (surface.pixels.len > 0) alloc.free(surface.pixels);
        if (surface.title) |title| alloc.free(title);

        self.retired_surfaces.append(alloc, surface) catch {
            // Nothing else to do: leaking the surface is better than freeing
            // memory the core might still reference.
        };
    }

    /// Release a frame after its window has been destroyed.
    fn destroyFrame(self: *App, frame: *Frame) void {
        const alloc = self.core_app.alloc;

        if (self.main_hwnd == frame.hwnd) {
            _ = KillTimer(frame.hwnd, 1);
            self.main_hwnd = null;
        }

        for (self.frames.items, 0..) |item, i| {
            if (item == frame) {
                _ = self.frames.swapRemove(i);
                break;
            }
        }

        if (self.main_hwnd == null) {
            if (self.frames.items.len > 0) {
                const next = self.frames.items[0];
                self.main_hwnd = next.hwnd;
                _ = SetTimer(next.hwnd, 1, tick_interval_ms, null);
            } else {
                PostQuitMessage(0);
            }
        }

        for (frame.tabs.items) |*tab| {
            tab.panes.deinit(alloc);
            tab.dirs.deinit(alloc);
        }
        frame.tabs.deinit(alloc);
        for (frame.titles.items) |title| alloc.free(title);
        frame.titles.deinit(alloc);
        alloc.destroy(frame);
    }

    /// The window a target belongs to.
    fn targetFrame(self: *App, target: apprt.Target) ?*Frame {
        return switch (target) {
            .surface => |surface| surface.rt_surface.frame,
            .app => if (self.frames.items.len > 0)
                self.frames.items[self.frames.items.len - 1]
            else
                null,
        };
    }

    /// Apply a command received over IPC.
    fn handleIpc(self: *App, tag_raw: u32, dir_ptr: usize) void {
        // The string was allocated by the IPC thread; free it here.
        const dir_z: ?[*:0]u8 = if (dir_ptr != 0) @ptrFromInt(dir_ptr) else null;
        const directory: ?[]const u8 = if (dir_z) |ptr| std.mem.span(ptr) else null;
        defer if (dir_z) |ptr| {
            std.heap.page_allocator.free(ptr[0..std.mem.span(ptr).len :0]);
        };

        const tag: IpcTag = switch (tag_raw) {
            1 => .new_window,
            2 => .new_tab,
            else => return,
        };
        switch (tag) {
            .new_window => _ = self.createFrame(directory) catch |err| {
                log.err("failed to open window for IPC err={}", .{err});
            },

            .new_tab => {
                if (self.frames.items.len > 0) {
                    const frame = self.frames.items[self.frames.items.len - 1];
                    self.addTab(frame, directory) catch |err| {
                        log.err("failed to open tab for IPC err={}", .{err});
                    };
                }
            },
        }
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
        switch (action) {
            .quit => {
                _ = PostQuitMessage(0);
                return true;
            },

            .new_window => {
                _ = try self.createFrame(null);
                return true;
            },

            .new_tab => {
                const frame: ?*Frame = switch (target) {
                    .surface => |surface| surface.rt_surface.frame,
                    .app => if (self.frames.items.len > 0)
                        self.frames.items[self.frames.items.len - 1]
                    else
                        null,
                };
                if (frame) |f| try self.addTab(f, null);
                return frame != null;
            },

            .new_split => {
                const surface: ?*Surface = switch (target) {
                    .surface => |surface| surface.rt_surface,
                    .app => null,
                };
                const frame = if (surface) |surf| surf.frame else null;
                if (frame) |f| {
                    const index = f.tabIndex(surface.?) orelse f.active;
                    _ = try self.createPane(f, index, null, value);
                    return true;
                }
                return false;
            },

            .close_tab => {
                if (target == .surface) {
                    const surface = target.surface.rt_surface;
                    if (surface.frame) |frame| {
                        if (frame.tabIndex(surface)) |index| frame.closeTab(index);
                    }
                }
                return true;
            },

            .close_window => {
                if (self.targetFrame(target)) |frame| frame.closeAll();
                return true;
            },

            .close_all_windows => {
                for (self.frames.items) |frame| frame.closeAll();
                return true;
            },

            .reload_config => {
                var config = Config.load(self.core_app.alloc) catch |err| {
                    log.warn("config reload failed err={}", .{err});
                    return false;
                };
                defer config.deinit();

                for (self.surfaces.items) |surface| {
                    surface.core_surface.updateConfig(&config) catch |err| {
                        log.warn("updateConfig failed err={}", .{err});
                    };
                }

                // Keep the replaced config alive: surfaces may still refer
                // into it.
                self.retired_configs.append(self.core_app.alloc, self.config) catch {
                    return true;
                };
                self.config = config;
                return true;
            },

            .toggle_maximize => {
                if (self.targetFrame(target)) |frame| toggleMaximize(frame);
                return true;
            },

            .toggle_fullscreen => {
                if (self.targetFrame(target)) |frame| {
                    frame.setFullscreen(!frame.fullscreen);
                }
                return true;
            },

            .goto_split => {
                const surface: ?*Surface = switch (target) {
                    .surface => |s| s.rt_surface,
                    else => null,
                };
                if (surface) |surf| {
                    if (surf.frame) |frame| {
                        if (frame.tabIndex(surf)) |index| {
                            frame.gotoSplit(index, value);
                        }
                    }
                }
                return true;
            },

            .set_title => {
                if (target == .surface) {
                    target.surface.rt_surface.setTitle(value.title);
                }
                return true;
            },

            .set_tab_title => {
                // Only the tab label changes; the window title stays.
                if (target == .surface) {
                    const surface = target.surface.rt_surface;
                    if (surface.frame) |frame| frame.setTitle(surface, value.title);
                }
                return true;
            },

            .set_window_title => {
                const surface: ?*Surface = switch (target) {
                    .surface => |s| s.rt_surface,
                    else => null,
                };
                if (surface) |surf| {
                    if (surf.frame) |frame| frame.setWindowTitle(value.title);
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

/// One tab: a set of panes laid out inside the frame's content area.
pub const Tab = struct {
    panes: std.ArrayListUnmanaged(*Surface) = .empty,

    /// Split direction that introduced each pane, parallel to `panes`. The
    /// entry for the first pane is unused.
    dirs: std.ArrayListUnmanaged(apprt.action.SplitDirection) = .empty,
    /// Focused pane.
    active: usize = 0,
};

/// A window hosting one or more tabbed terminal surfaces.
///
/// The frame owns the tab strip (drawn by us) and the popup windows that
/// make up the tab contents. Panes are top-level popups owned by the frame
/// rather than `WS_CHILD` windows because WGL only presents reliably on
/// top-level windows.
pub const Frame = struct {
    app: *App,
    hwnd: HWND,
    tab_bar: HWND,
    tabs: std.ArrayListUnmanaged(Tab) = .empty,
    /// Whether the frame is borderless fullscreen.
    fullscreen: bool = false,

    /// Window rect to go back to when leaving fullscreen.
    saved_rect: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

    /// Tab labels, UTF-16 so they can be drawn without conversion.
    titles: std.ArrayListUnmanaged([]u16) = .empty,
    active: usize = 0,

    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyFrame");
    const tab_class = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyTabBar");
    const tab_height: i32 = 28;
    const tab_width: i32 = 170;
    const close_width: i32 = 22;

    fn create(app: *App) !*Frame {
        const alloc = app.core_app.alloc;
        const hinstance = GetModuleHandleW(null);

        var wc: WNDCLASSEXW = .{
            .lpfnWndProc = frameProc,
            .hInstance = hinstance,
            .hCursor = LoadCursorW(null, IDC_ARROW),
            .lpszClassName = class_name,
        };
        _ = RegisterClassExW(&wc);

        var tab_wc: WNDCLASSEXW = .{
            .lpfnWndProc = tabBarProc,
            .hInstance = hinstance,
            .hCursor = LoadCursorW(null, IDC_ARROW),
            .lpszClassName = tab_class,
        };
        _ = RegisterClassExW(&tab_wc);

        const self = alloc.create(Frame) catch return error.OutOfMemory;
        errdefer alloc.destroy(self);
        self.* = .{ .app = app, .hwnd = undefined, .tab_bar = undefined };

        var rect: RECT = .{
            .left = 0,
            .top = 0,
            .right = @intCast(default_width),
            .bottom = @intCast(default_height),
        };
        _ = AdjustWindowRectEx(&rect, WS_OVERLAPPEDWINDOW, 0, 0);
        const win_w = rect.right - rect.left;
        const win_h = rect.bottom - rect.top;
        const pos_x = @max(0, @divTrunc(GetSystemMetrics(0) - win_w, 2));
        const pos_y = @max(0, @divTrunc(GetSystemMetrics(1) - win_h, 2));

        self.hwnd = CreateWindowExW(
            0,
            class_name,
            std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
            WS_OVERLAPPEDWINDOW | WS_VISIBLE | WS_CLIPCHILDREN,
            pos_x,
            pos_y,
            win_w,
            win_h,
            null,
            null,
            hinstance,
            self,
        ) orelse return error.WindowCreateFailed;
        _ = SetWindowLongPtrW(self.hwnd, GWLP_USERDATA, @bitCast(@intFromPtr(self)));

        self.tab_bar = CreateWindowExW(
            0,
            tab_class,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            WS_CHILD | WS_VISIBLE,
            0,
            0,
            win_w,
            tab_height,
            self.hwnd,
            null,
            hinstance,
            self,
        ) orelse return error.WindowCreateFailed;
        _ = SetWindowLongPtrW(self.tab_bar, GWLP_USERDATA, @bitCast(@intFromPtr(self)));

        try app.frames.append(alloc, self);
        return self;
    }

    /// Screen rectangle the tab contents occupy.
    fn contentRect(self: *Frame) RECT {
        var client: RECT = undefined;
        if (GetClientRect(self.hwnd, &client) == 0) {
            return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        }

        var origin = POINT{ .x = 0, .y = tab_height };
        if (ClientToScreen(self.hwnd, &origin) == 0) {
            return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        }

        return .{
            .left = origin.x,
            .top = origin.y,
            .right = origin.x + (client.right - client.left),
            .bottom = origin.y + (client.bottom - client.top - tab_height),
        };
    }

    /// Append an empty tab and make it current.
    fn addTab(self: *Frame) !void {
        const alloc = self.app.core_app.alloc;
        const label = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");

        try self.tabs.append(alloc, .{});
        try self.titles.append(alloc, try alloc.dupe(u16, label[0..]));

        self.selectTab(self.tabs.items.len - 1);
    }

    /// The tab a surface belongs to, if any.
    fn tabIndex(self: *Frame, surface: *Surface) ?usize {
        for (self.tabs.items, 0..) |tab, i| {
            for (tab.panes.items) |pane| {
                if (pane == surface) return i;
            }
        }
        return null;
    }

    fn selectTab(self: *Frame, index: usize) void {
        if (index >= self.tabs.items.len) return;
        self.active = index;

        for (self.tabs.items, 0..) |tab, ti| {
            for (tab.panes.items) |pane| {
                _ = ShowWindow(pane.hwnd, if (ti == index) SW_SHOW else SW_HIDE);
            }
        }

        self.layoutTab(index);

        const tab = &self.tabs.items[index];
        if (tab.panes.items.len > 0) {
            const active = tab.panes.items[tab.active];
            _ = SetWindowPos(active.hwnd, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE);
            _ = SetFocus(active.hwnd);
            active.core_surface.refreshCallback() catch {};
        }

        _ = InvalidateRect(self.tab_bar, null, 1);
    }

    /// Lay the panes of one tab out inside the content rectangle.
    fn layoutTab(self: *Frame, index: usize) void {
        if (index >= self.tabs.items.len) return;
        const rect = self.contentRect();

        const tab = &self.tabs.items[index];
        const panes = tab.panes.items;
        if (panes.len == 0) return;

        // Panes are grouped into rows: a pane that was split downwards or
        // upwards starts a new row, and every other pane joins the row
        // before it. Rows share the height, panes in a row share the width.
        var starts: [64]usize = undefined;
        var ends: [64]usize = undefined;
        var rows: usize = 0;
        for (panes, 0..) |_, i| {
            const starts_row = i == 0 or switch (tab.dirs.items[i]) {
                .down, .up => true,
                else => false,
            };

            if (starts_row) {
                if (rows >= starts.len) break;
                starts[rows] = i;
                ends[rows] = i + 1;
                rows += 1;
            } else {
                ends[rows - 1] = i + 1;
            }
        }
        if (rows == 0) return;

        const row_height = @divTrunc(rect.bottom - rect.top, @as(i32, @intCast(rows)));
        for (starts[0..rows], ends[0..rows], 0..) |row_start, row_end, row| {
            const count = row_end - row_start;
            if (count == 0) continue;

            const top = rect.top + @as(i32, @intCast(row)) * row_height;
            const bottom = if (row == rows - 1) rect.bottom else top + row_height;
            const col_width = @divTrunc(rect.right - rect.left, @as(i32, @intCast(count)));

            for (panes[row_start..row_end], 0..) |pane, col| {
                const left = rect.left + @as(i32, @intCast(col)) * col_width;
                const right = if (col == count - 1) rect.right else left + col_width;
                placePane(pane, .{
                    .left = left,
                    .top = top,
                    .right = right,
                    .bottom = bottom,
                });
            }
        }
    }

    /// Enter or leave borderless fullscreen: the window loses its frame and
    /// covers the monitor it is on, then goes back to exactly where it was.
    fn setFullscreen(self: *Frame, on: bool) void {
        if (self.fullscreen == on) return;

        var style: usize = @bitCast(GetWindowLongPtrW(self.hwnd, GWL_STYLE));
        const chrome: usize = WS_CAPTION | WS_THICKFRAME;

        if (on) {
            var rect: RECT = undefined;
            if (GetWindowRect(self.hwnd, &rect) == 0) return;
            self.saved_rect = rect;

            const monitor = MonitorFromWindow(self.hwnd, MONITOR_DEFAULTTONEAREST);
            var info: MONITORINFO = undefined;
            info.cbSize = @sizeOf(MONITORINFO);
            if (GetMonitorInfoW(monitor, &info) == 0) return;

            style &= ~chrome;
            _ = SetWindowLongPtrW(self.hwnd, GWL_STYLE, @bitCast(style));
            _ = SetWindowPos(
                self.hwnd,
                HWND_TOP,
                info.rcMonitor.left,
                info.rcMonitor.top,
                info.rcMonitor.right - info.rcMonitor.left,
                info.rcMonitor.bottom - info.rcMonitor.top,
                SWP_FRAMECHANGED | SWP_SHOWWINDOW,
            );
        } else {
            style |= chrome;
            _ = SetWindowLongPtrW(self.hwnd, GWL_STYLE, @bitCast(style));
            _ = SetWindowPos(
                self.hwnd,
                HWND_TOP,
                self.saved_rect.left,
                self.saved_rect.top,
                self.saved_rect.right - self.saved_rect.left,
                self.saved_rect.bottom - self.saved_rect.top,
                SWP_FRAMECHANGED | SWP_SHOWWINDOW,
            );
        }

        self.fullscreen = on;
        self.layout();
    }

    /// Ask the visible panes to paint. The core never tells the apprt that
    /// a new frame is ready on this platform, so the presentation is pumped
    /// from the window timer: a paint takes whatever frame the renderer has
    /// produced and blits it.
    fn invalidatePanes(self: *Frame) void {
        if (self.active >= self.tabs.items.len) return;
        for (self.tabs.items[self.active].panes.items) |pane| {
            // Wake the render thread so it draws whatever changed, then ask
            // for a paint so the newest frame is blitted.
            pane.core_surface.refreshCallback() catch {};
            _ = InvalidateRect(pane.hwnd, null, 0);
        }
    }

    fn layout(self: *Frame) void {
        var client: RECT = undefined;
        if (GetClientRect(self.hwnd, &client) == 0) return;

        _ = MoveWindow(self.tab_bar, 0, 0, client.right, tab_height, 1);
        self.layoutTab(self.active);
    }

    fn removeSurface(self: *Frame, surface: *Surface) void {
        const alloc = self.app.core_app.alloc;

        for (self.tabs.items, 0..) |*tab, ti| {
            for (tab.panes.items, 0..) |pane, pi| {
                if (pane != surface) continue;

                _ = tab.panes.orderedRemove(pi);
                if (pi < tab.dirs.items.len) _ = tab.dirs.orderedRemove(pi);
                surface.frame = null;

                if (tab.panes.items.len == 0) {
                    _ = self.tabs.orderedRemove(ti);
                    if (ti < self.titles.items.len) alloc.free(self.titles.orderedRemove(ti));

                    if (self.tabs.items.len == 0) {
                        _ = DestroyWindow(self.hwnd);
                        return;
                    }

                    if (self.active >= self.tabs.items.len) self.active = self.tabs.items.len - 1;
                    self.selectTab(self.active);
                } else {
                    if (tab.active >= tab.panes.items.len) tab.active = tab.panes.items.len - 1;
                    self.layoutTab(ti);
                }

                _ = InvalidateRect(self.tab_bar, null, 1);
                return;
            }
        }
    }

    /// Update the label of the tab a surface belongs to.
    fn setTitle(self: *Frame, surface: *Surface, title: []const u8) void {
        const index = self.tabIndex(surface) orelse return;
        if (index >= self.titles.items.len) return;

        const alloc = self.app.core_app.alloc;
        const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, title) catch return;
        defer alloc.free(wide);

        const copy = alloc.dupe(u16, wide[0..wide.len]) catch return;
        alloc.free(self.titles.items[index]);
        self.titles.items[index] = copy;

        _ = InvalidateRect(self.tab_bar, null, 1);
    }

    /// Set the host window title.
    fn setWindowTitle(self: *Frame, title: []const u8) void {
        const alloc = self.app.core_app.alloc;
        const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, title) catch return;
        defer alloc.free(wide);
        _ = SetWindowTextW(self.hwnd, wide.ptr);
    }

    /// Move focus to the pane in a direction.
    fn gotoSplit(self: *Frame, tab_index: usize, direction: apprt.action.GotoSplit) void {
        if (tab_index >= self.tabs.items.len) return;

        const tab = &self.tabs.items[tab_index];
        const count = tab.panes.items.len;
        if (count <= 1) return;

        // next/previous walk the pane list, the four directions move to the
        // nearest pane on that side of the focused one.
        switch (direction) {
            .next, .previous => {
                const step: usize = if (direction == .previous) count - 1 else 1;
                self.selectPane(tab_index, (tab.active + step) % count);
            },

            .left, .right, .up, .down => {
                const current = paneRect(tab.panes.items[tab.active]) orelse return;
                const current_cx = current.left + @divTrunc(current.right - current.left, 2);
                const current_cy = current.top + @divTrunc(current.bottom - current.top, 2);

                var best: ?usize = null;
                var best_distance: i64 = std.math.maxInt(i64);

                for (tab.panes.items, 0..) |pane, i| {
                    if (i == tab.active) continue;
                    const rect = paneRect(pane) orelse continue;

                    const in_direction = switch (direction) {
                        .left => rect.right <= current.left,
                        .right => rect.left >= current.right,
                        .up => rect.bottom <= current.top,
                        .down => rect.top >= current.bottom,
                        else => false,
                    };
                    if (!in_direction) continue;

                    const cx = rect.left + @divTrunc(rect.right - rect.left, 2);
                    const cy = rect.top + @divTrunc(rect.bottom - rect.top, 2);
                    const dx: i64 = cx - current_cx;
                    const dy: i64 = cy - current_cy;
                    const distance = dx * dx + dy * dy;
                    if (distance < best_distance) {
                        best_distance = distance;
                        best = i;
                    }
                }

                if (best) |index| self.selectPane(tab_index, index);
            },
        }
    }

    /// Screen rectangle of a pane window, if it has one.
    fn paneRect(pane: *Surface) ?RECT {
        var rect: RECT = undefined;
        if (GetWindowRect(pane.hwnd, &rect) == 0) return null;
        return rect;
    }

    fn selectPane(self: *Frame, tab_index: usize, pane_index: usize) void {
        if (tab_index >= self.tabs.items.len) return;

        const tab = &self.tabs.items[tab_index];
        if (pane_index >= tab.panes.items.len) return;

        tab.active = pane_index;

        const pane = tab.panes.items[pane_index];
        _ = SetWindowPos(pane.hwnd, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE);
        _ = SetFocus(pane.hwnd);
    }

    /// Close every pane of a tab.
    fn closeTab(self: *Frame, index: usize) void {
        if (index >= self.tabs.items.len) return;

        const alloc = self.app.core_app.alloc;
        const panes = alloc.dupe(*Surface, self.tabs.items[index].panes.items) catch return;
        defer alloc.free(panes);

        for (panes) |pane| pane.core_surface.close();
    }

    fn closeAll(self: *Frame) void {
        // Ask the core to close each pane; a surface destroys its own
        // window as it goes, and the last one destroys the frame.
        for (self.tabs.items) |tab| {
            for (tab.panes.items) |pane| pane.core_surface.close();
        }
    }
};

fn frameProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.c) isize {
    const frame = frameFromWindow(hwnd);
    switch (msg) {
        WM_SIZE, WM_MOVE => {
            if (frame) |f| f.layout();
            return 0;
        },

        WM_APP_IPC => {
            if (app_instance) |app| app.handleIpc(@intCast(wParam), @intCast(lParam));
            return 0;
        },

        WM_APP_WAKEUP => {
            // The core posts wakeups to the process-wide window, which is a
            // frame; without this the render threads never wake up.
            if (app_instance) |app| {
                app.core_app.tick(app) catch |err| {
                    log.err("core tick failed err={}", .{err});
                };
            }
            return 0;
        },

        WM_TIMER => {
            // The tick timer lives on the frame window, so this is where the
            // core tick and the presentation pump have to run.
            if (app_instance) |app| {
                app.core_app.tick(app) catch |err| {
                    log.err("core tick failed err={}", .{err});
                };
                if (frame) |f| f.invalidatePanes();
            }
            return 0;
        },

        WM_CLOSE => {
            if (frame) |f| f.closeAll();
            return 0;
        },

        WM_DESTROY => {
            if (frame) |f| f.app.destroyFrame(f);
            return 0;
        },

        WM_SETFOCUS => {
            if (frame) |f| {
                const tab = &f.tabs.items[f.active];
                if (tab.panes.items.len > 0) _ = SetFocus(tab.panes.items[tab.active].hwnd);
            }
            return 0;
        },

        else => {},
    }

    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

/// Draws the tab strip and switches tabs on click.
fn tabBarProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.c) isize {
    const frame = frameFromWindow(hwnd) orelse
        return DefWindowProcW(hwnd, msg, wParam, lParam);

    switch (msg) {
        WM_ERASEBKGND => return 1,

        WM_PAINT => {
            paintTabBar(frame, hwnd);
            return 0;
        },

        WM_LBUTTONDOWN => {
            const x: i32 = @intCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)))));
            const index = @divTrunc(x, Frame.tab_width);
            if (index >= 0 and index < frame.tabs.items.len) {
                // The right edge of a tab is its close button.
                const tab_right = (index + 1) * Frame.tab_width;
                if (x >= tab_right - Frame.close_width) {
                    frame.closeTab(@intCast(index));
                } else {
                    frame.selectTab(@intCast(index));
                }
            }
            return 0;
        },

        WM_MBUTTONDOWN => {
            const x: i32 = @intCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)))));
            const index = @divTrunc(x, Frame.tab_width);
            if (index >= 0 and index < frame.tabs.items.len) {
                frame.closeTab(@intCast(index));
            }
            return 0;
        },

        else => {},
    }

    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

fn paintTabBar(frame: *Frame, hwnd: HWND) void {
    var ps: PAINTSTRUCT = undefined;
    const dc = BeginPaint(hwnd, &ps) orelse return;
    defer _ = EndPaint(hwnd, &ps);

    var client: RECT = undefined;
    if (GetClientRect(hwnd, &client) == 0) return;

    const bg = GetSysColor(15); // COLOR_BTNFACE
    if (CreateSolidBrush(bg)) |brush| {
        _ = FillRect(dc, &client, brush);
        _ = DeleteObject(brush);
    }

    const font = GetStockObject(17); // DEFAULT_GUI_FONT
    const old_font = SelectObject(dc, font);
    defer _ = SelectObject(dc, old_font);
    _ = SetBkMode(dc, 1); // TRANSPARENT

    for (frame.titles.items, 0..) |title, i| {
        var rect: RECT = .{
            .left = @as(i32, @intCast(i)) * Frame.tab_width,
            .top = 0,
            .right = @as(i32, @intCast(i + 1)) * Frame.tab_width,
            .bottom = client.bottom,
        };

        if (i == frame.active) {
            if (CreateSolidBrush(GetSysColor(5))) |brush| { // COLOR_WINDOW
                _ = FillRect(dc, &rect, brush);
                _ = DeleteObject(brush);
            }
        }

        // Close button: a small x at the right edge of the tab.
        var close_rect: RECT = .{
            .left = rect.right - Frame.close_width,
            .top = 0,
            .right = rect.right,
            .bottom = client.bottom,
        };
        var close_label = std.unicode.utf8ToUtf16LeStringLiteral("x");
        _ = DrawTextW(
            dc,
            close_label[0..].ptr,
            1,
            &close_rect,
            0x1 | 0x4 | 0x20,
        );

        _ = SetTextColor(dc, GetSysColor(18)); // COLOR_BTNTEXT
        _ = DrawTextW(
            dc,
            title.ptr,
            @intCast(title.len),
            &rect,
            0x1 | 0x4 | 0x20, // CENTER | VCENTER | SINGLELINE
        );
    }
}

fn toggleMaximize(frame: *Frame) void {
    const SW_MAXIMIZE: c_int = 3;
    const SW_RESTORE: c_int = 9;
    _ = ShowWindow(frame.hwnd, if (IsZoomed(frame.hwnd) != 0) SW_RESTORE else SW_MAXIMIZE);
}

fn placePane(surface: *Surface, rect: RECT) void {
    _ = MoveWindow(
        surface.hwnd,
        rect.left,
        rect.top,
        @max(0, rect.right - rect.left),
        @max(0, rect.bottom - rect.top),
        1,
    );
}

fn frameFromWindow(hwnd: HWND) ?*Frame {
    const ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (ptr == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(ptr)));
}

pub const Surface = struct {
    app: *App,

    /// Host window this surface is a tab of, when it has one.
    frame: ?*Frame = null,
    core_surface: CoreSurface,
    hwnd: HWND,
    size: apprt.SurfaceSize,
    content_scale: apprt.ContentScale,
    cursor_pos: apprt.CursorPos,
    title: ?[:0]const u8 = null,

    /// True once the renderer has presented directly to this window with
    /// WGL `SwapBuffers`, which means GDI must not paint over it.
    gl_presented: bool = false,

    /// True while an IME composition string is active.
    composing: bool = false,

    /// Working directory requested for this surface. We own it because the
    /// core keeps a reference to it for the lifetime of the surface.
    working_directory: ?[:0]u8 = null,

    /// Scratch buffer for the BGRA, top-down copy we hand to GDI.
    pixels: []u8 = &.{},

    /// Frames presented so far, for rate-limited diagnostics.
    frame_count: u32 = 0,

    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWin32");

    pub const Options = struct {
        working_directory: ?[]const u8 = null,
        font_size: f32 = 0,

        /// When set, the surface is created as an owned popup window of
        /// this window instead of as a standalone window. Tabs use this:
        /// WGL presents reliably on top-level windows, but not on
        /// `WS_CHILD` windows, so tab content is a real popup positioned
        /// over the host window.
        owner: ?HWND = null,

        /// Screen rectangle for the popup, when `owner` is set.
        rect: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    };

    pub fn init(self: *Surface, app: *App, opts: Options) !void {
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

        const win_w = rect.right - rect.left;
        const win_h = rect.bottom - rect.top;
        const pos_x = @max(0, @divTrunc(GetSystemMetrics(0) - win_w, 2));
        const pos_y = @max(0, @divTrunc(GetSystemMetrics(1) - win_h, 2));

        const hwnd = if (opts.owner) |owner| popup: {
            self.size = .{
                .width = @intCast(@max(0, opts.rect.right - opts.rect.left)),
                .height = @intCast(@max(0, opts.rect.bottom - opts.rect.top)),
            };

            break :popup CreateWindowExW(
                WS_EX_TOOLWINDOW,
                class_name,
                std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
                WS_POPUP | WS_VISIBLE,
                opts.rect.left,
                opts.rect.top,
                @intCast(self.size.width),
                @intCast(self.size.height),
                owner,
                null,
                hinstance,
                self,
            ) orelse return error.WindowCreateFailed;
        } else top: {
            break :top CreateWindowExW(
                0,
                class_name,
                std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
                WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                pos_x,
                pos_y,
                win_w,
                win_h,
                null,
                null,
                hinstance,
                self,
            ) orelse return error.WindowCreateFailed;
        };
        errdefer _ = DestroyWindow(hwnd);
        self.hwnd = hwnd;

        _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, @bitCast(@intFromPtr(self)));

        // The client area is not necessarily the size we asked for: DPI
        // scaling and the non-client frame change it. Adopt the real size
        // before the core lays out its grid from it, otherwise the last
        // few rows and columns of the window are never painted.
        var client: RECT = undefined;
        if (GetClientRect(hwnd, &client) != 0) {
            self.size = .{
                .width = @intCast(client.right),
                .height = @intCast(client.bottom),
            };
        }

        const dpi = GetDpiForWindow(hwnd);
        if (dpi > 0) {
            const scale = @as(f32, @floatFromInt(dpi)) / base_dpi;
            self.content_scale = .{ .x = scale, .y = scale };
        }

        // Frames are presented by the renderer itself through WGL
        // SwapBuffers; GDI below is only the fallback for when the renderer
        // cannot present to the window.

        // Register with the core before initializing so that callbacks can
        // find us.
        try app.core_app.addSurface(self);
        errdefer app.core_app.deleteSurface(self);

        var config = try apprt.surface.newConfig(app.core_app, &app.config, .window);
        defer config.deinit();

        if (opts.working_directory) |dir| {
            if (self.app.core_app.alloc.dupeSentinel(u8, dir, 0)) |owned| {
                self.working_directory = owned;
                config.@"working-directory" = .{ .path = owned };
            } else |_| {}
        }

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

    /// Read text from the Windows clipboard and hand it to the core.
    ///
    /// The read is synchronous, and the core copies the contents during
    /// the completion call, so the buffer can be freed right after.
    pub fn clipboardRequest(
        self: *Surface,
        clipboard_type: apprt.Clipboard,
        state: apprt.ClipboardRequest,
    ) !apprt.ClipboardReadResult {
        // Windows has one clipboard; there is no primary selection.
        if (clipboard_type != .standard) return .unsupported;

        const alloc = self.app.core_app.alloc;
        const text = readClipboardText(alloc) orelse return .unavailable;
        defer alloc.free(text);

        const available = [_][]const u8{"text/plain"};
        self.core_surface.completeClipboardRequest(state, .{
            .contents = &.{.{ .mime = "text/plain", .data = text }},
            .available = &available,
            // TODO: surface Ghostty's unsafe-paste confirmation before
            // treating every paste as confirmed.
            .confirmed = true,
        }) catch |err| {
            log.warn("clipboard completion failed err={}", .{err});
            return .unsupported;
        };

        return .started;
    }

    pub fn setClipboard(
        self: *Surface,
        clipboard_type: apprt.Clipboard,
        contents: []const apprt.ClipboardContent,
        confirm: bool,
    ) !void {
        _ = confirm;
        if (clipboard_type != .standard) return;

        const alloc = self.app.core_app.alloc;
        for (contents) |content| {
            if (!std.mem.eql(u8, content.mime, "text/plain")) continue;

            writeClipboardText(alloc, content.data) catch |err| {
                log.warn("failed to write clipboard err={}", .{err});
                return err;
            };
            return;
        }
    }

    pub fn refresh(self: *Surface) void {
        // The renderer produced a new frame; ask the window to paint so the
        // UI thread pulls it and presents. Without this a surface that never
        // gets a paint (a window that is not being moved or uncovered) would
        // render frames that nobody ever shows.
        _ = InvalidateRect(self.hwnd, null, 0);

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
        return .{
            // Bind the GL context to this window so frames are presented
            // with SwapBuffers instead of a GPU->CPU readback.
            .window_handle = @ptrCast(self.hwnd),
        };
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
        log.debug("set_title {s}", .{title});
        const alloc = self.app.core_app.alloc;
        if (self.title) |v| alloc.free(v);

        const owned = alloc.dupeSentinel(u8, title, 0) catch return;
        self.title = owned;

        const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, owned) catch return;
        defer alloc.free(wide);
        _ = SetWindowTextW(self.hwnd, wide.ptr);

        if (self.frame) |frame| frame.setTitle(self, title);
    }

    /// Translate a Win32 virtual key into a core key event.
    ///
    /// Text is generated here rather than from WM_CHAR so that the core
    /// sees one event carrying both the physical key and the produced
    /// text, which is what its key encoder expects for things like
    /// Ctrl+C (physical `c` plus text is what makes 0x03).
    fn handleKey(self: *Surface, vk: u32, extended: bool, action: input.Action) bool {
        // The IME owns the keyboard while composing, and keys it already
        // consumed arrive as VK_PROCESSKEY; forwarding them would both
        // double-insert text and trigger spurious keybindings.
        if (self.composing) return true;
        if (vk == VK_PROCESSKEY) return true;

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

    /// Report a mouse move to the core. Coordinates are already device
    /// pixels because the window is per-monitor DPI aware.
    pub fn cursorPosCallback(self: *Surface, x: f64, y: f64) void {
        const pos: apprt.CursorPos = .{
            .x = @floatCast(x),
            .y = @floatCast(y),
        };

        // Platforms sometimes deliver a move to the same position (for
        // example when the title changes); ignore those so that
        // mouse-hide-while-typing does not flicker.
        if (@abs(self.cursor_pos.x - pos.x) < 1 and
            @abs(self.cursor_pos.y - pos.y) < 1) return;

        self.cursor_pos = pos;

        self.core_surface.cursorPosCallback(pos, currentMods()) catch |err| {
            log.err("error in cursor pos callback err={}", .{err});
        };
    }

    pub fn mouseButtonCallback(
        self: *Surface,
        state: input.MouseButtonState,
        button: input.MouseButton,
    ) void {
        _ = self.core_surface.mouseButtonCallback(state, button, currentMods()) catch |err| {
            log.err("error in mouse button callback err={}", .{err});
            return;
        };
    }

    pub fn scrollCallback(self: *Surface, xoff: f64, yoff: f64) void {
        self.core_surface.scrollCallback(xoff, yoff, .{}) catch |err| {
            log.err("error in scroll callback err={}", .{err});
        };
    }

    /// Replace the inline preedit text. A null/empty value clears it.
    fn setPreedit(self: *Surface, text: ?[]const u8) void {
        self.composing = text != null and text.?.len > 0;
        self.core_surface.preeditCallback(text) catch |err| {
            log.err("error in preedit callback err={}", .{err});
        };
    }

    /// Handle a WM_IME_COMPOSITION update.
    ///
    /// A committed result is inserted like pasted text; the remaining
    /// composition string becomes the inline preedit.
    fn imeComposition(self: *Surface, himc: HIMC, flags: DWORD) void {
        const alloc = self.app.core_app.alloc;

        if (flags & GCS_RESULTSTR != 0) {
            if (readImeString(alloc, himc, GCS_RESULTSTR)) |text| {
                defer alloc.free(text);
                self.core_surface.textCallback(text) catch |err| {
                    log.err("error in text callback err={}", .{err});
                };
                self.setPreedit(null);
            }
        }

        if (flags & GCS_COMPSTR != 0) {
            if (readImeString(alloc, himc, GCS_COMPSTR)) |text| {
                defer alloc.free(text);
                self.setPreedit(text);
            } else {
                self.setPreedit("");
            }
        }
    }

    /// Pull the latest exported frame and blit it into the window.
    fn presentFrame(self: *Surface) void {
        const frame = self.core_surface.renderer.takeFrame() orelse {
            return;
        };

        defer frame.deinit();

        switch (frame) {
            .memory => |m| {
                self.blit(m);
            },
            // Presented by the renderer itself (WGL SwapBuffers).
            .presented => self.gl_presented = true,
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

        // `readPixels` returns bottom-up BGRA; both presentation paths want
        // it the other way up, so only the rows have to be reversed.
        const src_stride = @as(usize, m.width) * 4;
        const dst_stride = src_stride;
        var y: usize = 0;
        while (y < m.height) : (y += 1) {
            const src_row = m.pixels[(m.height - 1 - y) * src_stride ..][0..src_stride];
            const dst_row = self.pixels[y * dst_stride ..][0..dst_stride];
            @memcpy(dst_row, src_row);
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

        WM_MOUSEMOVE => {
            const p = mousePos(lParam);
            self.cursorPosCallback(p.x, p.y);
            return 0;
        },

        WM_LBUTTONDOWN, WM_RBUTTONDOWN, WM_MBUTTONDOWN, WM_XBUTTONDOWN => {
            const p = mousePos(lParam);
            self.cursorPosCallback(p.x, p.y);
            _ = SetCapture(hwnd);
            self.mouseButtonCallback(.press, buttonFromMsg(msg, wParam));
            return 0;
        },

        WM_LBUTTONUP, WM_RBUTTONUP, WM_MBUTTONUP, WM_XBUTTONUP => {
            const p = mousePos(lParam);
            self.cursorPosCallback(p.x, p.y);
            _ = ReleaseCapture();
            self.mouseButtonCallback(.release, buttonFromMsg(msg, wParam));
            return 0;
        },

        WM_MOUSEWHEEL => {
            // The high word of wParam is a signed delta in multiples of
            // 120; one notch is one line, and the core applies the user's
            // scroll multiplier on top.
            const raw: i16 = @bitCast(@as(u16, @truncate((wParam >> 16) & 0xFFFF)));
            const yoff = @as(f64, @floatFromInt(raw)) / 120.0;
            self.scrollCallback(0, yoff);
            return 0;
        },

        WM_IME_SETCONTEXT => {
            return DefWindowProcW(
                hwnd,
                msg,
                wParam,
                lParam & ~ISC_SHOWUICOMPOSITIONWINDOW,
            );
        },

        WM_IME_STARTCOMPOSITION => {
            self.setPreedit("");
            return 0;
        },

        WM_IME_COMPOSITION => {
            const himc = ImmGetContext(hwnd) orelse return 0;
            defer _ = ImmReleaseContext(hwnd, himc);

            const flags: DWORD = @truncate(@as(usize, @bitCast(lParam)));
            self.imeComposition(himc, flags);
            return 0;
        },

        WM_IME_ENDCOMPOSITION => {
            self.setPreedit(null);
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
            // Once frames are presented by the renderer there is no frame
            // to blit here: the window back buffer already holds the last
            // one. A paint request therefore means the window lost its
            // contents (occlusion, unminimize), so ask the core to render
            // again instead of leaving a stale or blank window.
            if (self.gl_presented) {
                self.core_surface.refreshCallback() catch |err| {
                    log.err("error requesting refresh err={}", .{err});
                };
            } else {
                self.presentFrame();
            }

            _ = ValidateRect(hwnd, null);
            return 0;
        },

        WM_ERASEBKGND => {
            // Nothing to erase once frames are presented directly: the
            // window back buffer covers the client area, and GDI painting
            // here would flash between frames.
            if (self.gl_presented) return 1;

            self.clearBackground();
            return 1;
        },

        WM_APP_IPC => {
            if (app_instance) |app| app.handleIpc(@intCast(wParam), @intCast(lParam));
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
            if (app_instance) |app| app.destroySurface(self);
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

/// Read an IME composition string as NUL-terminated UTF-8.
///
/// `ImmGetCompositionStringW` reports a byte length, and returns the
/// number of bytes copied, so both calls are converted to UTF-16 units.
fn readImeString(alloc: Allocator, himc: HIMC, index: DWORD) ?[:0]u8 {
    const bytes = ImmGetCompositionStringW(himc, index, null, 0);
    if (bytes <= 0) return null;

    const units = alloc.alloc(u16, @intCast(@divTrunc(bytes, 2))) catch return null;
    defer alloc.free(units);

    const got = ImmGetCompositionStringW(himc, index, @ptrCast(units.ptr), @intCast(bytes));
    if (got <= 0) return null;

    const slice = units[0..@intCast(@divTrunc(got, 2))];
    const utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, slice) catch return null;
    defer alloc.free(utf8);

    return alloc.dupeSentinel(u8, utf8, 0) catch null;
}

/// Read the clipboard as a NUL-terminated UTF-8 string, or null when it
/// holds no text.
fn readClipboardText(alloc: Allocator) ?[:0]u8 {
    if (OpenClipboard(null) == 0) return null;
    defer _ = CloseClipboard();

    const handle = GetClipboardData(CF_UNICODETEXT) orelse return null;
    const locked = GlobalLock(handle) orelse return null;
    defer _ = GlobalUnlock(handle);

    const wide: [*:0]const u16 = @ptrCast(@alignCast(locked));
    const units = std.mem.span(wide);

    const utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, units) catch return null;
    defer alloc.free(utf8);

    return alloc.dupeSentinel(u8, utf8, 0) catch null;
}

/// Replace the clipboard contents with `text`.
///
/// The system takes ownership of the global memory block on success, so
/// it must not be freed here in that case.
fn writeClipboardText(alloc: Allocator, text: []const u8) !void {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, text);
    defer alloc.free(wide);

    if (OpenClipboard(null) == 0) return error.ClipboardBusy;
    defer _ = CloseClipboard();

    if (EmptyClipboard() == 0) return error.ClipboardBusy;

    const bytes = (wide.len + 1) * @sizeOf(u16);
    const mem = GlobalAlloc(GMEM_MOVEABLE, bytes) orelse return error.OutOfMemory;
    errdefer _ = GlobalFree(mem);

    const locked = GlobalLock(mem) orelse return error.OutOfMemory;
    defer _ = GlobalUnlock(mem);

    const src: [*]const u8 = @ptrCast(wide.ptr);
    const dst: [*]u8 = @ptrCast(locked);
    @memcpy(dst[0..bytes], src[0..bytes]);

    if (SetClipboardData(CF_UNICODETEXT, mem) == null) return error.ClipboardBusy;
}

/// Cursor position, in device pixels, from a mouse message's lParam.
fn mousePos(lParam: LPARAM) struct { x: f64, y: f64 } {
    const value: usize = @bitCast(lParam);
    const x: i16 = @bitCast(@as(u16, @truncate(value & 0xFFFF)));
    const y: i16 = @bitCast(@as(u16, @truncate((value >> 16) & 0xFFFF)));
    return .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
}

/// Map a button message to the core's button enum. Side buttons map to
/// the extra buttons terminal mouse reporting tracks.
fn buttonFromMsg(msg: UINT, wParam: WPARAM) input.MouseButton {
    return switch (msg) {
        WM_LBUTTONDOWN, WM_LBUTTONUP => .left,
        WM_RBUTTONDOWN, WM_RBUTTONUP => .right,
        WM_MBUTTONDOWN, WM_MBUTTONUP => .middle,
        else => switch (@as(u16, @truncate((wParam >> 16) & 0xFFFF))) {
            1 => .four,
            2 => .five,
            else => .unknown,
        },
    };
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

/// Named-pipe server used to receive commands from other processes.
fn ipcServerMain(app: *App) void {
    while (true) {
        const pipe = CreateNamedPipeW(
            ipc_pipe_name,
            PIPE_ACCESS_INBOUND,
            PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT,
            1,
            0,
            1024,
            0,
            null,
        );
        if (pipe == INVALID_HANDLE_VALUE) {
            log.err("failed to create IPC pipe error={d}", .{GetLastError()});
            return;
        }

        const connected = ConnectNamedPipe(pipe, null) != 0 or
            GetLastError() == 535; // ERROR_PIPE_CONNECTED
        if (connected) {
            var buf: [1024]u8 = undefined;
            var read: DWORD = 0;
            if (ReadFile(pipe, &buf, buf.len, &read, null) != 0 and read >= 8) {
                const tag = std.mem.readInt(u32, buf[0..4], .little);
                const len = std.mem.readInt(u32, buf[4..8], .little);

                // The UI thread takes ownership of this string.
                const dir: usize = if (len > 0 and len <= buf.len - 8) blk: {
                    const copy = std.heap.page_allocator.allocSentinel(u8, len, 0) catch break :blk 0;
                    @memcpy(copy[0..len], buf[8 .. 8 + len]);
                    break :blk @intFromPtr(copy.ptr);
                } else 0;

                if (app.main_hwnd) |hwnd| {
                    _ = PostMessageW(hwnd, WM_APP_IPC, @intCast(tag), @intCast(dir));
                }
            }
        }

        _ = DisconnectNamedPipe(pipe);
        _ = CloseHandle(pipe);
    }
}
