# Ghostty for Windows

<p align="center">
  <img src="https://github.com/user-attachments/assets/fe853809-ba8b-400b-83ab-a9a0da25be8a" alt="Ghostty Logo" width="96">
</p>

This is a fork of [Ghostty](https://ghostty.org) that adds **native Windows
support** via a Win32 application runtime. The goal is to bring Ghostty's
fast, GPU-accelerated, feature-rich terminal experience to Windows users
with a fully native UI — no Electron, no cross-platform toolkit overhead.

> For the original project documentation, see [README.md](README.md).

## Why

Ghostty officially supports macOS and Linux (GTK). This fork implements a
third application runtime (`win32`) that uses the Win32 API directly,
giving Windows users:

- **GPU-accelerated rendering** via OpenGL 4.3+ (same renderer as macOS/Linux)
- **Native window management** — real Win32 windows, menus, and controls
- **ConPTY integration** — the modern Windows pseudo-terminal API
- **Full feature parity** — tabs, splits, search, configurable fonts/themes

## Quick Start

### Requirements

- **Zig 0.16.0** — install via `scoop install zig@0.16.0` or from [ziglang.org](https://ziglang.org/download/)
- **Windows SDK** (MSVC) — included with Visual Studio Build Tools
- **OpenGL 4.3+** capable GPU

### Build

```powershell
# Release build (recommended)
zig build -Doptimize=ReleaseFast

# The executable
.\zig-out\bin\ghostty.exe
```

### Configure

Create `%LOCALAPPDATA%\ghostty\config.ghostty`:

```
theme = catppuccin-mocha
font-family = JetBrains Mono
font-size = 12
background-opacity = 0.95
command = pwsh.exe
```

### Test

```powershell
# Split tree, divider drag, and search count tests
zig build test -Dtest-filter="Tab."
zig build test -Dtest-filter="App.formatSearchCount"

# Full suite
zig build test
```

## Architecture

The Win32 runtime lives in `src/apprt/win32/` and implements the same
`apprt` interface as macOS (AppKit) and Linux (GTK):

```
src/apprt/win32/
├── App.zig          # Window, menu bar, tabs, search, event loop
├── Surface.zig      # Terminal surface with own WGL context
├── Tab.zig          # Binary split tree for pane management
└── Tab_test.zig     # Split tree + search count unit tests
src/os/win32.zig     # Win32 API declarations
```

## Features

| Feature | Status |
|---------|--------|
| OpenGL rendering | ✅ |
| ConPTY terminal | ✅ |
| Multiple tabs | ✅ |
| Horizontal/vertical splits | ✅ |
| Incremental search with match count | ✅ |
| Full menu bar (Ghostty/File/Edit/View/Window/Help) | ✅ |
| Right-click context menu | ✅ |
| Fullscreen (F11 / menu) | ✅ |
| Float on top | ✅ |
| Font configuration | ✅ |
| Theme support | ✅ |
| Config reload | ✅ |
| Navigate/equalize splits | ✅ |
| Graceful surface close (exit in pane) | ✅ |
| Keyboard/mouse input | ✅ |
| Clipboard (copy/paste) | ✅ |
| Per-monitor DPI awareness | ✅ |
| IME composition (CJK input) | ✅ |
| Drag split dividers to resize | ✅ |
| Multiple windows | 🔧 Planned |
| Split zoom | 🔧 Planned |

## Bug Fixes (Post-Initial)

### Surface close / ConPTY pipe crash

Typing `exit` in a shell pane used to crash the entire application.
The root cause was in the IO reader thread (`src/termio/Exec.zig`):
when a ConPTY child process exits, Windows closes the output pipe and
`ReadFile` returns `ERROR_BROKEN_PIPE`. This error was unhandled and
hit an `unreachable`, crashing the process.

The fix adds a `.BROKEN_PIPE` handler that exits the read thread
gracefully, allowing the normal `childExited` → `closeSurface` flow
to remove only the affected pane.

Additional changes in this fix:

- **`Surface.close()`** now posts `WM_CLOSE_SURFACE` to the main
  window, deferring destruction until after the core's `tick()` completes.
- **`App.closeSurface()`** walks the tab split tree to find and remove
  only the target surface. If other surfaces remain in the tab, the tab
  stays open. Only quits when the last tab's last surface is closed.
- **Tab bar visibility** fixed when switching back to a single-surface
  tab (`gotoTab` now calls `updateLayout()`).

## Credits

Win32 port authored by **Claude Opus 4.6** via **GitHub Copilot**.

Built on the [Ghostty](https://ghostty.org) project by Mitchell Hashimoto
and contributors. Licensed under the MIT License.
