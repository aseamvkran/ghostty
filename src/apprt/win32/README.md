# Ghostty Win32 Application Runtime

This is the native Win32 application runtime for [Ghostty](../../../README.md),
providing a GPU-accelerated terminal emulator on Windows using the Win32 API
and OpenGL.

## Architecture

The Win32 apprt implements Ghostty's cross-platform `apprt` interface using:

- **Win32 API** for window management, input handling, and UI
- **OpenGL 4.3+** via WGL for GPU-accelerated rendering (reuses Ghostty's existing renderer)
- **ConPTY** for the pseudo-terminal backend (implemented in `src/pty.zig`)

### Module Structure

| File | Purpose |
|------|---------|
| `App.zig` | Main application: window, tabs, search, context menu, message loop |
| `Surface.zig` | Terminal surface: child window with own GL context, input handling |
| `Tab.zig` | Split tree data structure for managing multiple surfaces per tab |
| `Tab_test.zig` | Unit tests for split tree logic |

### Features

- Multiple tabs with a custom-drawn tab bar
- Horizontal and vertical splits within each tab
- Search bar (Ctrl+F)
- Right-click context menu (Copy, Paste, New Tab, Split, Close, Search)
- Keyboard shortcuts: Ctrl+T (new tab), Ctrl+W (close tab), Ctrl+1-9 (switch tabs)
- OpenGL rendering via Ghostty's `GenericRenderer`
- Full keyboard and mouse input translation

## Building

Requires **Zig 0.15.2** and the Windows SDK (MSVC).

```powershell
# Release build (recommended)
zig build -Doptimize=ReleaseFast

# Debug build
zig build
```

The executable is output to `zig-out/bin/ghostty.exe`.

## Testing

```powershell
# Run Tab split tree tests
zig build test -Dtest-filter="Tab"

# Run all tests (slow)
zig build test
```

## Configuration

Place a config file at:
```
%LOCALAPPDATA%\ghostty\config.ghostty
```

Example:
```
theme = catppuccin-mocha
font-family = JetBrains Mono
font-size = 12
background-opacity = 0.95
command = powershell.exe
```

## Credits

Authored by **Claude Opus 4.6** via **GitHub Copilot**.

Built on top of the Ghostty project by Mitchell Hashimoto and contributors.
Licensed under the MIT License.
