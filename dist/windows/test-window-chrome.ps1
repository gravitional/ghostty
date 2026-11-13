# Real mouse regression checks for frame activation, caption buttons and sizing.
# Run on an interactive desktop without moving the mouse during the test.
# Unlike posting WM_SYSCOMMAND, these clicks exercise non-client activation.
param([string]$Exe = (Join-Path $PSScriptRoot '..\..\zig-out\bin\ghostty.exe'))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class GhosttyChrome {
    public delegate bool EnumProc(IntPtr hwnd, IntPtr param);
    [StructLayout(LayoutKind.Sequential)]
    public struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct Point { public int X, Y; }

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr param);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hwnd, StringBuilder buf, int size);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(Point point);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int command);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeoutW(IntPtr hwnd, uint msg, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);

    public static IntPtr Find(int pid, string cls) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((hwnd, param) => {
            uint owner;
            GetWindowThreadProcessId(hwnd, out owner);
            var name = new StringBuilder(128);
            GetClassNameW(hwnd, name, name.Capacity);
            if (owner == pid && name.ToString() == cls && IsWindowVisible(hwnd)) found = hwnd;
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static Rect Bounds(IntPtr hwnd) {
        Rect rect;
        if (!GetWindowRect(hwnd, out rect)) throw new Exception("Cannot read window bounds");
        return rect;
    }

    public static Point Cursor() { Point p; GetCursorPos(out p); return p; }

    [StructLayout(LayoutKind.Sequential)]
    public struct TitleBarInfo {
        public uint Size;
        public Rect Bounds;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 6)] public uint[] State;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 6)] public Rect[] Buttons;
    }
    [DllImport("user32.dll", EntryPoint = "SendMessageTimeoutW")]
    public static extern IntPtr ReadTitleBar(IntPtr hwnd, uint msg, IntPtr w, ref TitleBarInfo info, uint flags, uint timeout, out IntPtr result);

    // Use the actual caption button rectangles. DefWindowProc hit-test
    // regions can differ from the DWM-painted buttons after resizing.
    public static Point HitPoint(IntPtr hwnd, int hit) {
        if (hit == 8 || hit == 9 || hit == 20) {
            var info = new TitleBarInfo();
            info.Size = (uint)Marshal.SizeOf<TitleBarInfo>();
            info.State = new uint[6]; info.Buttons = new Rect[6];
            IntPtr result;
            if (ReadTitleBar(hwnd, 0x33F, IntPtr.Zero, ref info, 2, 1000, out result) == IntPtr.Zero)
                throw new Exception("Cannot read caption button bounds");
            var button = info.Buttons[hit == 8 ? 2 : hit == 9 ? 3 : 5];
            if (button.Right <= button.Left || button.Bottom <= button.Top)
                throw new Exception("Caption button has no area");
            return new Point { X = (button.Left + button.Right) / 2, Y = (button.Top + button.Bottom) / 2 };
        }
        var r = Bounds(hwnd);
        int yStart = hit == 11 ? (r.Top + r.Bottom) / 2 : r.Top;
        int yEnd = hit == 11 ? yStart + 1 : Math.Min(r.Top + 80, r.Bottom);
        int minX = int.MaxValue, maxX = int.MinValue, minY = int.MaxValue, maxY = int.MinValue;
        for (int y = yStart; y < yEnd; y += 2) {
            for (int x = r.Right - 1; x >= Math.Max(r.Left, r.Right - 300); x -= 2) {
                long packed = (ushort)x | ((long)(ushort)y << 16);
                IntPtr result;
                if (SendMessageTimeoutW(hwnd, 0x84, IntPtr.Zero, (IntPtr)packed, 2, 1000, out result) == IntPtr.Zero)
                    throw new Exception("Window did not respond to hit testing");
                if (result.ToInt64() == hit) {
                    minX = Math.Min(minX, x); maxX = Math.Max(maxX, x);
                    minY = Math.Min(minY, y); maxY = Math.Max(maxY, y);
                }
            }
        }
        if (minX != int.MaxValue) return new Point { X = (minX + maxX) / 2, Y = (minY + maxY) / 2 };
        throw new Exception("Cannot find non-client hit target " + hit);
    }

    public static void Click(Point p, IntPtr expected) {
        if (WindowFromPoint(p) != expected) throw new Exception("Test window is obscured");
        SetCursorPos(p.X, p.Y);
        System.Threading.Thread.Sleep(100);
        mouse_event(2, 0, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(100);
        mouse_event(4, 0, 0, 0, UIntPtr.Zero);
    }

    public static void Drag(Point p) {
        SetCursorPos(p.X, p.Y);
        mouse_event(2, 0, 0, 0, UIntPtr.Zero);
        try {
            System.Threading.Thread.Sleep(100);
            for (int i = 1; i <= 10; i++) {
                SetCursorPos(p.X + i * 8, p.Y);
                System.Threading.Thread.Sleep(30);
            }
        } finally { mouse_event(4, 0, 0, 0, UIntPtr.Zero); }
    }
}
'@

function Wait-Until([scriptblock]$Condition) {
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        if (& $Condition) { return $true }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Assert([string]$Name, [bool]$Ok) {
    if (-not $Ok) { throw "FAIL: $Name" }
    Write-Host "PASS: $Name"
}

# Single-instance IPC would otherwise send this test's actions to an existing
# session. Refuse to run rather than interfere with the user's terminal.
if (Get-Process ghostty -ErrorAction SilentlyContinue) {
    throw 'Close existing Ghostty instances before running this test.'
}

[GhosttyChrome]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
$cursor = [GhosttyChrome]::Cursor()
$log = Join-Path $env:TEMP ('ghostty-chrome-' + [guid]::NewGuid().ToString('n') + '.log')
$passed = $false
$process = Start-Process -FilePath (Resolve-Path $Exe).Path -PassThru -RedirectStandardError $log
try {
    Assert 'frame appears' (Wait-Until {
        [GhosttyChrome]::Find($process.Id, 'GhosttyFrame') -ne [IntPtr]::Zero
    })
    Assert 'pane appears' (Wait-Until {
        [GhosttyChrome]::Find($process.Id, 'GhosttyWin32') -ne [IntPtr]::Zero
    })
    Start-Sleep -Seconds 2
    $frame = [GhosttyChrome]::Find($process.Id, 'GhosttyFrame')

    function Focus-Pane {
        $pane = [GhosttyChrome]::Find($process.Id, 'GhosttyWin32')
        [GhosttyChrome]::SetForegroundWindow($pane) | Out-Null
        Start-Sleep -Milliseconds 200
        $r = [GhosttyChrome]::Bounds($pane)
        $point = New-Object GhosttyChrome+Point
        $point.X = $r.Left + 20
        $point.Y = $r.Top + 20
        [GhosttyChrome]::Click($point, $pane)
    }

    Focus-Pane
    [GhosttyChrome]::Click([GhosttyChrome]::HitPoint($frame, 9), $frame)
    Assert 'caption maximize after terminal focus' (Wait-Until { [GhosttyChrome]::IsZoomed($frame) })
    [GhosttyChrome]::Click([GhosttyChrome]::HitPoint($frame, 9), $frame)
    Assert 'caption restore' (Wait-Until { -not [GhosttyChrome]::IsZoomed($frame) })

    Focus-Pane
    $before = [GhosttyChrome]::Bounds($frame)
    [GhosttyChrome]::Drag([GhosttyChrome]::HitPoint($frame, 11))
    Assert 'right border drag resizes frame' (Wait-Until {
        $after = [GhosttyChrome]::Bounds($frame)
        ($after.Right - $after.Left) -gt ($before.Right - $before.Left + 30)
    })

    Focus-Pane
    [GhosttyChrome]::Click([GhosttyChrome]::HitPoint($frame, 8), $frame)
    Assert 'caption minimize after terminal focus' (Wait-Until { [GhosttyChrome]::IsIconic($frame) })
    [GhosttyChrome]::ShowWindow($frame, 9) | Out-Null
    Assert 'restore after minimize' (Wait-Until { -not [GhosttyChrome]::IsIconic($frame) })

    # Exercise closing a frame with multiple tabs as well as a live shell.
    $ipc = Start-Process -FilePath (Resolve-Path $Exe).Path -ArgumentList '+new-tab' -PassThru
    Assert 'new tab command exits' ($ipc.WaitForExit(10000))
    Assert 'new tab command succeeds' ($ipc.ExitCode -eq 0)
    Start-Sleep -Seconds 1
    Focus-Pane
    [GhosttyChrome]::Click([GhosttyChrome]::HitPoint($frame, 20), $frame)
    Assert 'caption close exits process with multiple tabs' (Wait-Until {
        $process.Refresh()
        $process.HasExited
    })
    $process.WaitForExit()
    Write-Host "Process exit code: $($process.ExitCode)"
    Assert 'clean process exit' ($process.ExitCode -eq 0)
    $passed = $true
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    [GhosttyChrome]::SetCursorPos($cursor.X, $cursor.Y) | Out-Null
    if ($passed) {
        Remove-Item $log -ErrorAction SilentlyContinue
    } else {
        Write-Host "Application log: $log"
    }
}
