# Interactive clipboard regression. Keep the desktop unlocked and avoid input.
param([string]$Exe = (Join-Path $PSScriptRoot '..\..\zig-out\bin\ghostty.exe'))
$ErrorActionPreference = 'Stop'
$targetExe = (Resolve-Path $Exe).Path
. (Join-Path $PSScriptRoot 'test-window-chrome.ps1') -LibraryOnly
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class GhosttyClipboardDialog {
    [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr dialog, int id);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr hwnd, uint msg, IntPtr w, IntPtr l);
    public static void Choose(IntPtr dialog, int id) {
        var button = GetDlgItem(dialog, id);
        if (button == IntPtr.Zero) throw new Exception("Confirmation button not found");
        PostMessageW(button, 0xF5, IntPtr.Zero, IntPtr.Zero);
    }
}
'@
if (Get-Process ghostty -ErrorAction SilentlyContinue) { throw 'Close existing Ghostty instances first.' }
[GhosttyChrome]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
$work = Join-Path $env:TEMP ('ghostty-clipboard-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory $work | Out-Null
$config = Join-Path $work 'config'
@'
command = direct:pwsh.exe -NoLogo -NoProfile
clipboard-paste-bracketed-safe = false
keybind = f6=select_all
'@ | Set-Content $config -Encoding utf8
$previous = Get-Clipboard -Raw
$cursor = [GhosttyChrome]::Cursor()
$process = $null
$passed = $false
try {
    $process = Start-Process $targetExe -ArgumentList '--config-default-files=false', "--config-file=$config" -PassThru -RedirectStandardError (Join-Path $work 'app.log')
    Assert 'clipboard test frame appears' (Wait-Until { [GhosttyChrome]::Find($process.Id, 'GhosttyFrame') -ne [IntPtr]::Zero })
    Start-Sleep -Seconds 3
    $frame = [GhosttyChrome]::Find($process.Id, 'GhosttyFrame')
    [GhosttyChrome]::SetForegroundWindow($frame) | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $output = Join-Path $work 'unicode.txt'
    $text = '中文剪贴板 Maple 😀'
    Set-Clipboard -Value "[IO.File]::WriteAllText('$output', '$text')"
    $shell.SendKeys('^+v')
    Start-Sleep -Milliseconds 400
    $shell.SendKeys('{ENTER}')
    Assert 'Unicode paste executes' (Wait-Until { Test-Path $output })
    Assert 'Chinese and emoji survive paste' (Wait-Until { [IO.File]::ReadAllText($output) -ceq $text })
    Set-Clipboard -Value "Write-Output '$text'"
    $shell.SendKeys('^+v')
    Start-Sleep -Milliseconds 300
    $shell.SendKeys('{ENTER}')
    Start-Sleep -Milliseconds 600
    $shell.SendKeys('{F6}')
    $shell.SendKeys('^+c')
    Assert 'copy shortcut preserves Chinese and emoji' (Wait-Until { (Get-Clipboard -Raw).Contains($text) })
    $shell.SendKeys('^c')
    Start-Sleep -Milliseconds 300
    $marker = Join-Path $work 'multiline.txt'
    Set-Clipboard -Value "[IO.File]::WriteAllText('$marker', 'confirmed')`r`nWrite-Output 'second line'"
    $shell.SendKeys('^+v')
    Assert 'multiline paste requests confirmation' (Wait-Until { [GhosttyChrome]::Find($process.Id, '#32770') -ne [IntPtr]::Zero })
    $shell.SendKeys('{ENTER}')
    Assert 'cancel closes confirmation' (Wait-Until { [GhosttyChrome]::Find($process.Id, '#32770') -eq [IntPtr]::Zero })
    Assert 'cancel does not execute pasted commands' (-not (Test-Path $marker))
    $shell.SendKeys('^+v')
    Assert 'retry requests confirmation' (Wait-Until { [GhosttyChrome]::Find($process.Id, '#32770') -ne [IntPtr]::Zero })
    [GhosttyClipboardDialog]::Choose([GhosttyChrome]::Find($process.Id, '#32770'), 6)
    Assert 'accept closes confirmation' (Wait-Until { [GhosttyChrome]::Find($process.Id, '#32770') -eq [IntPtr]::Zero })
    Start-Sleep -Milliseconds 400
    $shell.SendKeys('{ENTER}')
    if (-not (Wait-Until { Test-Path $marker })) {
        $shell.SendKeys('{F6}')
        $shell.SendKeys('^+c')
        Start-Sleep -Milliseconds 500
        Get-Clipboard -Raw | Set-Content (Join-Path $work 'screen.txt')
        throw 'Confirmed multiline paste did not execute; see screen.txt'
    }
    Assert 'confirmed multiline paste executes' $true
    Assert 'confirmed content is intact' ([IO.File]::ReadAllText($marker) -eq 'confirmed')
    $passed = $true
} finally {
    if ($process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id
        $process.WaitForExit()
    }
    if ($null -ne $previous) { Set-Clipboard -Value $previous } else { Set-Clipboard -Value '' }
    [GhosttyChrome]::SetCursorPos($cursor.X, $cursor.Y) | Out-Null
    if ($passed) { Remove-Item $work -Recurse -Force } else { Write-Host "Test artifacts: $work" }
}
