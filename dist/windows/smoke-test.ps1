# Smoke test for the Windows apprt.
#
# Exercises the paths that cannot be covered by `zig build test` because they
# need a real window, a real shell and a real message loop: rendering at
# startup, splits, closing a pane, tabs, a second window through the single
# instance IPC, fullscreen, and pasting.
#
# Usage:
#   pwsh -File dist/windows/smoke-test.ps1 [-Exe zig-out\bin\ghostty.exe]
#
# Every check prints PASS or FAIL and the script exits non-zero if any failed.
# The user's config is backed up and restored, and the temporary keybindings it
# needs are appended only for the duration of the run.

param(
    [string]$Exe = (Join-Path $PSScriptRoot '..\..\zig-out\bin\ghostty.exe'),
    [string]$Config = (Join-Path $env:LOCALAPPDATA 'ghostty\config.ghostty')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Exe = (Resolve-Path $Exe).Path
$results = [System.Collections.Generic.List[object]]::new()

function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    $results.Add([pscustomobject]@{ Test = $Name; Pass = $Ok })
    $status = if ($Ok) { 'PASS' } else { 'FAIL' }
    Write-Host ('{0,-34} {1} {2}' -f $Name, $status, $Detail)
}

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class GhosttySmoke {
    public delegate bool EnumProc(IntPtr hwnd, IntPtr param);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr param);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hwnd, StringBuilder buf, int size);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr hwnd, uint msg, IntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern uint MapVirtualKeyW(uint code, uint mapType);

    public static List<IntPtr> ByClass(uint pid, string cls) {
        var found = new List<IntPtr>();
        EnumWindows((hwnd, param) => {
            uint owner;
            GetWindowThreadProcessId(hwnd, out owner);
            if (owner != pid) return true;
            var name = new StringBuilder(64);
            GetClassNameW(hwnd, name, 64);
            if (name.ToString() == cls && IsWindowVisible(hwnd)) found.Add(hwnd);
            return true;
        }, IntPtr.Zero);
        return found;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Explicit)]
    public struct INPUT { [FieldOffset(0)] public uint type; [FieldOffset(8)] public MOUSEINPUT mi; }

    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);

    // Wheel messages have to come from the real input queue: a posted
    // WM_MOUSEWHEEL is not delivered to the surface.
    public static void Wheel(int x, int y, int notches) {
        SetCursorPos(x, y);
        for (int i = 0; i < notches; i++) {
            var input = new INPUT { type = 0 };
            input.mi.mouseData = 120;
            input.mi.dwFlags = 0x0800;
            SendInput(1, new[] { input }, Marshal.SizeOf(typeof(INPUT)));
            System.Threading.Thread.Sleep(60);
        }
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowTextW(IntPtr hwnd, StringBuilder buf, int size);

    public static string WindowTitle(IntPtr hwnd) {
        var buf = new StringBuilder(512);
        GetWindowTextW(hwnd, buf, buf.Capacity);
        return buf.ToString();
    }

    public static void Type(IntPtr hwnd, string text) {
        foreach (char c in text) {
            Key(hwnd, (uint)char.ToUpperInvariant(c));
            System.Threading.Thread.Sleep(40);
        }
    }

    public static void Key(IntPtr hwnd, uint vk) {
        uint scan = MapVirtualKeyW(vk, 0) & 0xff;
        PostMessageW(hwnd, 0x0100, (IntPtr)vk, (IntPtr)((long)(scan << 16) | 1));
        PostMessageW(hwnd, 0x0101, (IntPtr)vk, (IntPtr)((long)(scan << 16) | 0xC0000001));
    }

    public static RECT Rect(IntPtr hwnd) {
        RECT rect;
        GetWindowRect(hwnd, out rect);
        return rect;
    }
}
'@

[GhosttySmoke]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null

$VK = @{
    F4  = 0x73  # paste
    F5  = 0x74  # close surface
    F9  = 0x78  # new split right
    F11 = 0x7A  # toggle fullscreen
}

$extraKeybinds = @(
    'keybind = f9=new_split:right',
    'keybind = f5=close_surface',
    'keybind = f11=toggle_fullscreen',
    'keybind = f4=paste_from_clipboard'
)

function Wait-Until {
    param([scriptblock]$Condition, [int]$TimeoutMs = 8000)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        $value = & $Condition
        if ($value) { return $value }
        Start-Sleep -Milliseconds 150
    }
    return $null
}

function Capture-Pane {
    param([IntPtr]$Pane, [string]$Path)
    # The window has to be on top for a screen grab to show it.
    [GhosttySmoke]::SetWindowPos($Pane, [IntPtr](-1), 0, 0, 0, 0, 0x0013) | Out-Null
    Start-Sleep -Milliseconds 400
    $rect = [GhosttySmoke]::Rect($Pane)
    $width = $rect.Right - $rect.Left
    $height = [Math]::Min(160, $rect.Bottom - $rect.Top)
    if ($width -le 0 -or $height -le 0) {
        [GhosttySmoke]::SetWindowPos($Pane, [IntPtr](-2), 0, 0, 0, 0, 0x0013) | Out-Null
        throw "pane has no area: ${width}x${height}"
    }
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $full = New-Object System.Drawing.Bitmap $screen.Width, $screen.Height
    $graphics = [System.Drawing.Graphics]::FromImage($full)
    $graphics.CopyFromScreen(0, 0, 0, 0, $screen.Size)
    $crop = New-Object System.Drawing.Bitmap $width, $height
    $cropGraphics = [System.Drawing.Graphics]::FromImage($crop)
    $cropGraphics.DrawImage(
        $full,
        (New-Object System.Drawing.Rectangle 0, 0, $width, $height),
        (New-Object System.Drawing.Rectangle $rect.Left, $rect.Top, $width, $height),
        [System.Drawing.GraphicsUnit]::Pixel)
    $crop.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    [GhosttySmoke]::SetWindowPos($Pane, [IntPtr](-2), 0, 0, 0, 0, 0x0013) | Out-Null
    $graphics.Dispose()
    $cropGraphics.Dispose()
    $full.Dispose()
    $crop.Dispose()
}

# Count how many distinct colours a capture contains. A terminal that painted
# text has many more colours than one that only cleared to its background.
# Capture the tab strip of a frame window (below its title bar) so a label
# change shows up as a different image.
function Capture-TabStrip {
    param([IntPtr]$Frame, [string]$Path)
    [GhosttySmoke]::SetWindowPos($Frame, [IntPtr](-1), 0, 0, 0, 0, 0x0013) | Out-Null
    Start-Sleep -Milliseconds 400
    $rect = [GhosttySmoke]::Rect($Frame)
    $width = $rect.Right - $rect.Left
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $full = New-Object System.Drawing.Bitmap $screen.Width, $screen.Height
    $graphics = [System.Drawing.Graphics]::FromImage($full)
    $graphics.CopyFromScreen(0, 0, 0, 0, $screen.Size)
    $height = 34
    $crop = New-Object System.Drawing.Bitmap $width, $height
    $cropGraphics = [System.Drawing.Graphics]::FromImage($crop)
    $destination = New-Object System.Drawing.Rectangle 0, 0, $width, $height
    $source = New-Object System.Drawing.Rectangle $rect.Left, ($rect.Top + 32), $width, $height
    $cropGraphics.DrawImage($full, $destination, $source, [System.Drawing.GraphicsUnit]::Pixel)
    $crop.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    [GhosttySmoke]::SetWindowPos($Frame, [IntPtr](-2), 0, 0, 0, 0, 0x0013) | Out-Null
    $graphics.Dispose(); $cropGraphics.Dispose(); $full.Dispose(); $crop.Dispose()
}

function Get-ColourCount {
    param([string]$Path)
    $bitmap = [System.Drawing.Bitmap]::FromFile($Path)
    $seen = [System.Collections.Generic.HashSet[int]]::new()
    for ($y = 0; $y -lt $bitmap.Height; $y += 2) {
        for ($x = 0; $x -lt $bitmap.Width; $x += 2) {
            $seen.Add($bitmap.GetPixel($x, $y).ToArgb()) | Out-Null
        }
    }
    $bitmap.Dispose()
    return $seen.Count
}

$backup = $null
$process = $null
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('ghostty-smoke-' + [guid]::NewGuid().ToString('n'))

try {
    New-Item -ItemType Directory -Path $work | Out-Null

    # Install the keybindings the test needs, keeping the user's config.
    if (Test-Path $Config) {
        $backup = "$Config.smoke-backup"
        Copy-Item $Config $backup -Force
    }
    foreach ($line in $extraKeybinds) { Add-Content -Path $Config -Value $line }

    $process = Start-Process -FilePath $Exe -PassThru
    $pid0 = [uint32]$process.Id

    $frame = Wait-Until { ([GhosttySmoke]::ByClass($pid0, 'GhosttyFrame') | Select-Object -First 1) } 15000
    Check 'startup: window appears' ($null -ne $frame)

    $pane = Wait-Until { ([GhosttySmoke]::ByClass($pid0, 'GhosttyWin32') | Select-Object -First 1) } 15000
    Check 'startup: surface appears' ($null -ne $pane)

    # Give the shell a moment to print its banner, then require real content.
    Start-Sleep -Seconds 4
    $shot = Join-Path $work 'startup.png'
    Capture-Pane -Pane $pane -Path $shot
    $colours = Get-ColourCount -Path $shot
    Check 'startup: terminal draws text' ($colours -gt 8) "colours=$colours"

    # The shell's title reaches the window title.
    [GhosttySmoke]::Type($pane, 'title SMOKETITLE')
    [GhosttySmoke]::Key($pane, 0x0D)
    $title = ''
    $deadline = [DateTime]::UtcNow.AddSeconds(6)
    while ([DateTime]::UtcNow -lt $deadline) {
        $title = [GhosttySmoke]::WindowTitle($frame)
        if ($title -match 'smoketitle') { break }
        Start-Sleep -Milliseconds 200
    }
    Check 'title: window title follows the shell' ($title -match 'smoketitle') "title=$title"

    # Scrolling back through history changes what is on screen. `set` is used
    # as the output generator because the typing helper can only send letters.
    [GhosttySmoke]::Type($pane, 'set')
    [GhosttySmoke]::Key($pane, 0x0D)
    Start-Sleep -Seconds 3
    [GhosttySmoke]::SetForegroundWindow($pane) | Out-Null
    $scrollBefore = Join-Path $work 'scroll-before.png'
    Capture-Pane -Pane $pane -Path $scrollBefore
    $rect = [GhosttySmoke]::Rect($pane)
    [GhosttySmoke]::Wheel(
        $rect.Left + [int](($rect.Right - $rect.Left) / 2),
        $rect.Top + [int](($rect.Bottom - $rect.Top) / 2),
        15)
    Start-Sleep -Seconds 1
    $scrollAfter = Join-Path $work 'scroll-after.png'
    Capture-Pane -Pane $pane -Path $scrollAfter
    Check 'scrollback: wheel changes the view' (
        (Get-FileHash $scrollBefore -Algorithm SHA256).Hash -ne
        (Get-FileHash $scrollAfter -Algorithm SHA256).Hash)

    # A split must produce two panes that do not overlap.
    [GhosttySmoke]::Key($pane, $VK.F9)
    $panes = Wait-Until {
        $found = [GhosttySmoke]::ByClass($pid0, 'GhosttyWin32')
        if ($found.Count -ge 2) { , $found } else { $null }
    } 8000
    Check 'split: second pane appears' ($null -ne $panes)
    if ($panes) {
        Start-Sleep -Seconds 1
        $a = [GhosttySmoke]::Rect($panes[0])
        $b = [GhosttySmoke]::Rect($panes[1])
        $disjoint = ($a.Right -le $b.Left) -or ($b.Right -le $a.Left) -or
                    ($a.Bottom -le $b.Top) -or ($b.Bottom -le $a.Top)
        Check 'split: panes are side by side' $disjoint
    }

    # Closing goes back to a single pane. Send the key to a pane that still
    # exists: the handles gathered before the split may already be stale.
    $livePanes = [GhosttySmoke]::ByClass($pid0, 'GhosttyWin32')
    $closeTarget = $livePanes[$livePanes.Count - 1]
    [GhosttySmoke]::Key($closeTarget, $VK.F5)
    $single = Wait-Until {
        $found = [GhosttySmoke]::ByClass($pid0, 'GhosttyWin32')
        if ($found.Count -eq 1) { $true } else { $null }
    } 8000
    Check 'close pane: back to one pane' ($null -ne $single)

    function Write-State([string]$label) {
        $f = ([GhosttySmoke]::ByClass($pid0, 'GhosttyFrame')).Count
        $q = ([GhosttySmoke]::ByClass($pid0, 'GhosttyWin32')).Count
        $alive = (Get-Process -Id $pid0 -ErrorAction SilentlyContinue) -ne $null
        Write-Host ("    [{0}] frames={1} panes={2} alive={3}" -f $label, $f, $q, $alive)
    }

    Write-State 'before ipc'
    # A tab through the single instance IPC.
    $tabExit = (Start-Process -FilePath $Exe -ArgumentList '+new-tab' -Wait -PassThru).ExitCode
    Start-Sleep -Seconds 2
    Write-State "after new-tab exit=$tabExit" 
    $paneAfterTab = [GhosttySmoke]::ByClass($pid0, 'GhosttyWin32') | Select-Object -First 1
    Check 'ipc: new tab accepted' ($tabExit -eq 0 -and $null -ne $paneAfterTab) "exit=$tabExit"

    # A second window through the same IPC, and it must render too.
    $windowExit = (Start-Process -FilePath $Exe -ArgumentList '+new-window' -Wait -PassThru).ExitCode
    Start-Sleep -Seconds 3
    Write-State "after new-window exit=$windowExit" 
    $twoFrames = Wait-Until {
        $found = [GhosttySmoke]::ByClass($pid0, 'GhosttyFrame')
        $allPanes = [GhosttySmoke]::ByClass($pid0, 'GhosttyWin32')
        if ($found.Count -ge 2 -and $allPanes.Count -ge 2) { $true } else { $null }
    } 20000
    $frameCount = ([GhosttySmoke]::ByClass($pid0, 'GhosttyFrame')).Count
    Check 'ipc: new window accepted' ($windowExit -eq 0 -and $null -ne $twoFrames) "exit=$windowExit frames=$frameCount"

    if ($twoFrames) {
        $panes2 = [GhosttySmoke]::ByClass($pid0, 'GhosttyWin32')
        $last = $panes2[$panes2.Count - 1]
        Start-Sleep -Seconds 3
        $shot2 = Join-Path $work 'second.png'
        Capture-Pane -Pane $last -Path $shot2
        $colours2 = Get-ColourCount -Path $shot2
        Check 'second window: draws text' ($colours2 -gt 8) "colours=$colours2"
    }

    # Fullscreen covers the monitor it is on.
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $focused = [GhosttySmoke]::ByClass($pid0, 'GhosttyWin32') | Where-Object {
        $rect = [GhosttySmoke]::Rect($_)
        ($rect.Right - $rect.Left) -gt 100 -and ($rect.Bottom - $rect.Top) -gt 100
    } | Select-Object -First 1
    if (-not $focused) { $focused = [GhosttySmoke]::ByClass($pid0, 'GhosttyWin32') | Select-Object -First 1 }
    [GhosttySmoke]::Key($focused, $VK.F11)
    $fullscreen = Wait-Until {
        foreach ($candidate in [GhosttySmoke]::ByClass($pid0, 'GhosttyFrame')) {
            $rect = [GhosttySmoke]::Rect($candidate)
            if (($rect.Right - $rect.Left) -ge ($screen.Width - 2)) { return $true }
        }
        return $null
    } 6000
    Check 'fullscreen: window covers monitor' ($null -ne $fullscreen)
    [GhosttySmoke]::Key($paneAfterTab, $VK.F11)
    Start-Sleep -Seconds 1

    # Pasting has to change what is on screen.
    Set-Clipboard -Value 'echo SMOKE_PASTE'
    $before = Join-Path $work 'before-paste.png'
    Capture-Pane -Pane $paneAfterTab -Path $before
    [GhosttySmoke]::Key($paneAfterTab, $VK.F4)
    Start-Sleep -Seconds 2
    $after = Join-Path $work 'after-paste.png'
    Capture-Pane -Pane $paneAfterTab -Path $after
    $beforeHash = (Get-FileHash $before -Algorithm SHA256).Hash
    $afterHash = (Get-FileHash $after -Algorithm SHA256).Hash
    Check 'paste: screen changes' ($beforeHash -ne $afterHash)


}
finally {
    if ($process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
    if ($backup) {
        Copy-Item $backup $Config -Force
        Remove-Item $backup -Force
    }
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { -not $_.Pass })
Write-Host ''
Write-Host ('{0}/{1} checks passed' -f ($results.Count - $failed.Count), $results.Count)
if ($failed.Count -gt 0) {
    Write-Host ('failed: ' + (($failed | ForEach-Object { $_.Test }) -join ', '))
    exit 1
}
exit 0
