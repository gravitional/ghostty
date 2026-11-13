# Ghostty on Windows

This is a personal port of Ghostty to Windows. It is not upstream and does not
aim to match upstream's platform choices; the goal is a terminal that is usable
day to day on Windows.

## Build and run

```sh
zig build
./zig-out/bin/ghostty.exe
```

The executable is built as a GUI subsystem binary, so it does not open a console
window. For development, switching `exe.subsystem` to `.console` in
`src/build/GhosttyExe.zig` makes logs visible on stderr.

## What works

- Rendering through the CPU path, at low idle cost
- Keyboard input, including the Windows IME for Chinese
- Mouse selection, copy, and paste (keyboard binding and middle click)
- Scrollback: wheel and keyboard
- Tabs, splits (side by side and stacked), focus movement, fullscreen, maximize
- Multiple windows and single-instance IPC (`+new-tab`, `+new-window`)
- Config reload at runtime, font zoom, working directory passthrough
- The shell's title reaching the tab label and the window title
- Minimize and restore without losing the screen; the process exits when the
  last shell does

## Measured behaviour

Debug build on a 2560x1440 display at 100% scale:

| Scenario | CPU |
| --- | --- |
| Idle | ~3% of one core |
| A burst of output (`set` in cmd) | ~10% |
| Back to idle after the burst | ~3% |

Memory settled around 100 MB with 15 threads.

The presentation tick asks the renderer to draw every 16 ms, because nothing
else pulls frames. After a second without a presented frame it backs off to
every eighth tick, and any key press or presented frame restores the fast
cadence.


## Architecture notes

These are the decisions that took the most iteration. Read them before changing
the Windows runtime.

### A window is a frame plus child panes

`Frame` is the top-level window and draws the tab strip. Each terminal pane is
created as a `WS_CHILD` window. This keeps the frame active when the terminal
has keyboard focus, allowing Windows to apply its window management shortcuts
to the frame. Pane positions are converted from screen to frame coordinates.

An earlier WGL presentation experiment used owned popup panes because direct
presentation to child windows failed. The current GDI presentation path works
with child windows; enabling direct WGL presentation would require revisiting
that constraint.

### Presentation is a CPU copy, not WGL

`src/renderer/OpenGL.zig` has `present_with_wgl = false` on Windows.
`presentWindow` returns false, the renderer exports memory frames, and the
runtime blits them with GDI.

The WGL path silently produced blank frames. A Direct3D 11 path built on
`WGL_NV_DX_interop` was abandoned as well: interop textures reported
`GL_TEXTURE_INTERNAL_FORMAT = 0`, so the frame could not be shared.

### The tick timer lives on the frame window

Nothing in the core calls `surface.refresh()` on its own, so the runtime drives
presentation itself: a 16 ms timer on the frame, whose `WM_TIMER` handler ticks
the core and invalidates every pane of the active tab.

This handler must be in `frameProc`, not in `windowProc`. Panes never get a
timer, and for a long time the `WM_TIMER` case sat in the surface procedure,
where it could never run. The symptom was a window that only painted when
Windows invalidated it for its own reasons, which looked like "the terminal is
blank until I type".

### ConPTY runs with passthrough

The pseudo console is created with `PSEUDOCONSOLE_PASSTHROUGH` and falls back
to the translated mode when the call is rejected. Without it, the child's OSC
title sequences are consumed by conhost and never reach the terminal, so tabs
always showed the default title.

### Closing a surface keeps its memory

`App.retired_surfaces` and `App.retired_configs` exist because the core can
still reference a surface or a configuration after the apprt is done with it.
Freeing either right away crashed the process: closing a pane and then opening
a window took the whole application down. Both lists are released in
`App.terminate`.

### Single instance IPC

A named pipe (`\\.\pipe\ghostty-win32`) is served by a detached thread. It posts
`WM_APP_IPC` to the UI thread, which then runs the requested action. Payloads
carry an 8-byte header and optional UTF-8 arguments such as
`--working-directory`.

## Smoke test

`dist/windows/smoke-test.ps1` drives the paths that unit tests cannot reach:
a real window, a real shell, a real message loop.

```powershell
pwsh -NoProfile -File dist/windows/smoke-test.ps1
```

It backs up and restores the user's config, appends only the keybindings it
needs, and reports each check. It exits non-zero when something fails.

Notes for anyone extending it:

- Capture panes with `PrintWindow`. Screen grabs depend on window position and
  occlusion and were the source of several flaky checks.
- Scroll with a key binding. Synthetic wheel events depend on which window is
  under the cursor.
- The typing helper only sends letters, so commands used as output generators
  must avoid punctuation (`set` works, `for /l ...` does not).
- The process must be DPI aware (`SetProcessDpiAwarenessContext(-4)`) or every
  coordinate is off by the scale factor.

## Window chrome regression test

`dist/windows/test-window-chrome.ps1` uses real mouse and keyboard input to
check tab and basic split controls, caption buttons, resizing, Windows arrow shortcuts and
closing a window with multiple tabs. It verifies that closing exits with code
zero. It reads caption button bounds from Windows instead of assuming their
positions from the window size.

```powershell
pwsh -NoProfile -File dist/windows/test-window-chrome.ps1
```

Close existing Ghostty instances first, use an unlocked interactive desktop,
and leave the mouse and keyboard alone while the test runs. The test moves its
window to each connected monitor and checks the tab bar and pane geometry at
that monitor's DPI. It restores the cursor position afterward and retains an
application log in the temporary directory if a check fails.

## Known gaps

- Split layouts support dragging the divider to resize panes. The current divider position is shared across the frame, and arbitrary nested split layouts are not implemented.
- The tab strip scrolls overflowing tabs with left and right controls, keeps
  the active tab visible, and reserves a fixed `+` button at the right edge.
  The desktop regression test covers scrolling, tab closing, and both `+`
  button actions while the strip overflows.
- Window titles update from the shell, but shells that report a title only
  through the console API (rather than OSC) are not covered.
- Window movement and layout were tested on two monitors at 100% and 150%
  scaling. Other scaling factors and IME candidate placement need further
  manual validation.
- No Windows-specific default key bindings are provided; configure shortcuts in
  the config file as you would on any other platform.
- The desktop regression script covers tab creation and overflow interactions,
  split resizing, DPI changes, caption controls, window sizing, and normal
  process exit. Some shell and platform-specific behaviors still need manual
  validation.

## Measuring geometry

Measure window rectangles only from a DPI-aware process. A DPI-unaware caller
gets virtualized values (28 physical pixels at 150% reads back as 19), which
once looked like a layout bug for several rounds. `SetProcessDpiAwarenessContext(-4)`
before any measurement.

