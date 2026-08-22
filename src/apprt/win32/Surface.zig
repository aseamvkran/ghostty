/// Win32 surface - represents a terminal surface within a window.
/// Each surface is a child window with its own WGL OpenGL context.
/// Manages the WGL OpenGL context and provides the interface
/// expected by CoreSurface.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const input = @import("../../input.zig");
const internal_os = @import("../../os/main.zig");
const global = @import("../../global.zig");
const CoreSurface = @import("../../Surface.zig");
const CoreApp = @import("../../App.zig");
const windows = internal_os.win32;

const log = std.log.scoped(.win32_surface);

const App = @import("App.zig");

/// The child window for this surface.
child_hwnd: ?windows.HWND = null,

/// Pointer back to the App.
app: ?*App = null,

/// GDI device context.
hdc: ?windows.HDC = null,

/// OpenGL rendering context.
hglrc: ?windows.HGLRC = null,

/// The core surface, if initialized.
core_surface: ?*CoreSurface = null,

/// Window dimensions.
width: u32 = 800,
height: u32 = 600,

/// Cached cursor position.
cursor_pos: apprt.CursorPos = .{ .x = 0, .y = 0 },

/// True while an IME composition is in progress. Key events are forwarded with
/// this set so the core suppresses them: the IME owns the keystrokes until it
/// commits, and we deliver the result as text via WM_IME_COMPOSITION.
composing: bool = false,

/// The surface child window class name.
const SURFACE_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhosttySurface");

/// Register the child window class for surfaces. Called once by App.init.
pub fn registerClass() !void {
    const hinstance = windows.GetModuleHandleW(null);
    const wc: windows.WNDCLASSEXW = .{
        .cbSize = @sizeOf(windows.WNDCLASSEXW),
        .style = windows.CS_HREDRAW | windows.CS_VREDRAW | windows.CS_OWNDC,
        .lpfnWndProc = surfaceWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = windows.LoadCursorW(null, windows.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = SURFACE_CLASS_NAME,
        .hIconSm = null,
    };

    if (windows.RegisterClassExW(&wc) == 0) {
        const err = windows.GetLastError();
        // Class already registered is OK (error 1410)
        if (err != 1410) {
            log.err("RegisterClassExW for surface failed: err={d}", .{err});
            return error.Win32Error;
        }
    }
}

pub fn core(self: *Self) *CoreSurface {
    return self.core_surface.?;
}

pub fn rtApp(self: *Self) *App {
    return self.app.?;
}

/// Initialize the surface by creating a child window.
pub fn init(self: *Self, parent_hwnd: windows.HWND, app_ptr: *App) !void {
    const hinstance = windows.GetModuleHandleW(null);

    self.* = .{
        .app = app_ptr,
    };

    self.child_hwnd = windows.CreateWindowExW(
        0,
        SURFACE_CLASS_NAME,
        null,
        windows.WS_CHILD | windows.WS_VISIBLE | windows.WS_CLIPSIBLINGS,
        0,
        0,
        800,
        600,
        parent_hwnd,
        null,
        hinstance,
        null,
    );

    if (self.child_hwnd == null) {
        log.err("CreateWindowExW for surface failed: err={d}", .{windows.GetLastError()});
        return error.Win32Error;
    }

    // Store self pointer in child window
    _ = windows.SetWindowLongPtrW(
        self.child_hwnd.?,
        windows.GWLP_USERDATA,
        @bitCast(@intFromPtr(self)),
    );

    try self.initOpenGL();
}

pub fn deinit(self: *Self) void {
    if (self.hglrc) |hglrc| {
        _ = windows.wglMakeCurrent(null, null);
        _ = windows.wglDeleteContext(hglrc);
        self.hglrc = null;
    }
    if (self.hdc) |hdc| {
        if (self.child_hwnd) |child| {
            _ = windows.ReleaseDC(child, hdc);
        }
        self.hdc = null;
    }
    if (self.child_hwnd) |child| {
        _ = windows.DestroyWindow(child);
        self.child_hwnd = null;
    }
}

fn initOpenGL(self: *Self) !void {
    const hwnd = self.child_hwnd orelse return error.NoWindow;
    self.hdc = windows.GetDC(hwnd);
    if (self.hdc == null) {
        log.err("GetDC failed: err={d}", .{windows.GetLastError()});
        return error.Win32Error;
    }

    var pfd: windows.PIXELFORMATDESCRIPTOR = std.mem.zeroes(windows.PIXELFORMATDESCRIPTOR);
    pfd.nSize = @sizeOf(windows.PIXELFORMATDESCRIPTOR);
    pfd.nVersion = 1;
    pfd.dwFlags = windows.PFD_DRAW_TO_WINDOW | windows.PFD_SUPPORT_OPENGL | windows.PFD_DOUBLEBUFFER;
    pfd.iPixelType = windows.PFD_TYPE_RGBA;
    pfd.cColorBits = 32;
    pfd.cDepthBits = 24;
    pfd.cStencilBits = 8;
    pfd.iLayerType = windows.PFD_MAIN_PLANE;

    const pixel_format = windows.ChoosePixelFormat(self.hdc, &pfd);
    if (pixel_format == 0) {
        log.err("ChoosePixelFormat failed: err={d}", .{windows.GetLastError()});
        return error.Win32Error;
    }

    if (windows.SetPixelFormat(self.hdc, pixel_format, &pfd) == 0) {
        log.err("SetPixelFormat failed: err={d}", .{windows.GetLastError()});
        return error.Win32Error;
    }

    self.hglrc = windows.wglCreateContext(self.hdc);
    if (self.hglrc == null) {
        log.err("wglCreateContext failed: err={d}", .{windows.GetLastError()});
        return error.Win32Error;
    }

    if (windows.wglMakeCurrent(self.hdc, self.hglrc) == 0) {
        log.err("wglMakeCurrent failed: err={d}", .{windows.GetLastError()});
        return error.Win32Error;
    }

    log.info("WGL OpenGL context created for surface", .{});
}

pub fn swapBuffers(self: *Self) void {
    if (self.hdc) |hdc| {
        if (windows.SwapBuffers(hdc) == 0) {
            log.warn("SwapBuffers failed: err={d}", .{windows.GetLastError()});
        }
    }
}

/// Make the WGL context current on the calling thread.
pub fn makeContextCurrent(self: *Self) void {
    if (self.hdc) |hdc| {
        if (self.hglrc) |hglrc| {
            if (windows.wglMakeCurrent(hdc, hglrc) == 0) {
                log.warn("wglMakeCurrent failed: err={d}", .{windows.GetLastError()});
            }
        }
    }
}

/// Release the WGL context from the calling thread. WGL contexts are
/// per-thread, so this serves both the main thread handing off to the
/// renderer thread and the renderer thread exiting.
pub fn releaseContext() void {
    if (windows.wglMakeCurrent(null, null) == 0) {
        log.warn("wglMakeCurrent(null) failed: err={d}", .{windows.GetLastError()});
    }
}

// --- Interface methods required by CoreSurface ---

pub fn getContentScale(self: *const Self) !apprt.ContentScale {
    // The app manifest declares PerMonitorV2 DPI awareness, so Windows does
    // not scale us and we must report the real scale or everything renders
    // at 96 DPI (tiny text on any display above 100%).
    const hwnd = self.child_hwnd orelse return .{ .x = 1.0, .y = 1.0 };
    const dpi = windows.GetDpiForWindow(hwnd);
    if (dpi == 0) return .{ .x = 1.0, .y = 1.0 };
    const scale: f32 = @as(f32, @floatFromInt(dpi)) / 96.0;
    return .{ .x = scale, .y = scale };
}

pub fn getSize(self: *const Self) !apprt.SurfaceSize {
    return .{
        .width = self.width,
        .height = self.height,
    };
}

pub fn getCursorPos(self: *const Self) !apprt.CursorPos {
    return self.cursor_pos;
}

pub fn getTitle(_: *Self) ?[:0]const u8 {
    return null;
}

pub fn close(self: *Self, _: bool) void {
    // Post a message to the main window to close this surface.
    // We use a message rather than calling closeSurface directly because
    // close() may be called from the core on any thread.
    if (self.app) |app| {
        if (app.hwnd) |hwnd| {
            _ = windows.PostMessageW(hwnd, App.WM_CLOSE_SURFACE, @intFromPtr(self), 0);
        }
    }
}

pub fn supportsClipboard(_: *Self, clipboard: apprt.Clipboard) bool {
    return clipboard == .standard;
}

pub fn clipboardRequest(
    self: *Self,
    _: apprt.Clipboard,
    req: apprt.ClipboardRequest,
) !bool {
    const hwnd = self.child_hwnd orelse return false;
    const core_sfc = self.core_surface orelse return false;
    const alloc = self.rtApp().alloc;

    if (windows.OpenClipboard(hwnd) == 0) return false;
    defer _ = windows.CloseClipboard();

    const handle = windows.GetClipboardData(windows.CF_UNICODETEXT) orelse return false;
    const raw_ptr = windows.GlobalLock(handle) orelse return false;
    defer _ = windows.GlobalUnlock(handle);
    const utf16: [*:0]const u16 = @ptrCast(@alignCast(raw_ptr));

    // No fixed-size buffer: the clipboard has no size limit worth guessing at,
    // and utf16LeToUtf8Alloc handles surrogate pairs (emoji) correctly.
    const data = std.unicode.utf16LeToUtf8AllocZ(
        alloc,
        std.mem.sliceTo(utf16, 0),
    ) catch |err| {
        log.warn("clipboard paste decode failed: {}", .{err});
        return false;
    };
    defer alloc.free(data);

    try core_sfc.completeClipboardRequest(req, data, false);
    return true;
}

pub fn setClipboard(
    self: *Self,
    _: apprt.Clipboard,
    contents: []const apprt.ClipboardContent,
    _: bool,
) !void {
    if (contents.len == 0) return;
    const hwnd = self.child_hwnd orelse return;
    const alloc = self.rtApp().alloc;

    const utf16 = std.unicode.utf8ToUtf16LeAllocZ(alloc, contents[0].data) catch |err| {
        log.warn("clipboard copy encode failed: {}", .{err});
        return;
    };
    defer alloc.free(utf16);

    if (windows.OpenClipboard(hwnd) == 0) return;
    defer _ = windows.CloseClipboard();
    _ = windows.EmptyClipboard();

    const size = (utf16.len + 1) * @sizeOf(u16);
    const hmem = windows.GlobalAlloc(windows.GMEM_MOVEABLE, size) orelse return;
    const dest: [*]u16 = @ptrCast(@alignCast(windows.GlobalLock(hmem) orelse {
        _ = windows.GlobalFree(hmem);
        return;
    }));
    @memcpy(dest[0 .. utf16.len + 1], utf16[0 .. utf16.len + 1]);
    _ = windows.GlobalUnlock(hmem);

    // Ownership of hmem transfers to the clipboard on success only.
    if (windows.SetClipboardData(windows.CF_UNICODETEXT, hmem) == null) {
        _ = windows.GlobalFree(hmem);
    }
}

pub fn defaultTermioEnv(_: *Self) !std.process.Environ.Map {
    return global.environMap() catch |err| {
        log.err("failed to get environment: {}", .{err});
        return err;
    };
}

// -----------------------------------------------------------------------
// Child Window Procedure - handles input for this surface
// -----------------------------------------------------------------------

fn surfaceWndProc(
    hwnd: windows.HWND,
    msg: u32,
    wparam: windows.WPARAM,
    lparam: windows.LPARAM,
) callconv(windows.WINAPI) windows.LRESULT {
    const self = getSelf(hwnd) orelse return windows.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        windows.WM_SIZE => {
            const w: u32 = @intCast(lparam & 0xFFFF);
            const h: u32 = @intCast((lparam >> 16) & 0xFFFF);
            if (w > 0 and h > 0) {
                self.width = w;
                self.height = h;
                if (self.core_surface) |cs| {
                    cs.sizeCallback(.{ .width = w, .height = h }) catch {};
                }
            }
            return 0;
        },
        windows.WM_PAINT => {
            // The GL renderer owns these pixels, so there is nothing to paint
            // with GDI. We still must Begin/EndPaint to clear the update
            // region, and we ask the core for a frame: the renderer is
            // damage-driven, so without this an expose (uncovered window,
            // restored from minimize, a neighbouring pane closing) leaves
            // stale or black pixels until the terminal next changes.
            var ps: windows.PAINTSTRUCT = std.mem.zeroes(windows.PAINTSTRUCT);
            _ = windows.BeginPaint(hwnd, &ps);
            _ = windows.EndPaint(hwnd, &ps);
            if (self.core_surface) |cs| cs.refreshCallback() catch {};
            return 0;
        },
        windows.WM_SETFOCUS => {
            if (self.core_surface) |cs| {
                cs.focusCallback(true) catch {};
            }
            // Notify App about focus change
            if (self.app) |app| {
                app.surfaceGotFocus(self);
            }
            return 0;
        },
        windows.WM_KILLFOCUS => {
            if (self.core_surface) |cs| {
                cs.focusCallback(false) catch {};
            }
            return 0;
        },
        windows.WM_KEYDOWN,
        windows.WM_SYSKEYDOWN,
        => {
            const action: input.Action = if ((lparam >> 30) & 1 == 1) .repeat else .press;
            self.handleKeyEvent(action, wparam, lparam);
            if (msg == windows.WM_SYSKEYDOWN) {
                return windows.DefWindowProcW(hwnd, msg, wparam, lparam);
            }
            return 0;
        },
        windows.WM_KEYUP,
        windows.WM_SYSKEYUP,
        => {
            self.handleKeyEvent(.release, wparam, lparam);
            if (msg == windows.WM_SYSKEYUP) {
                return windows.DefWindowProcW(hwnd, msg, wparam, lparam);
            }
            return 0;
        },
        windows.WM_CHAR,
        windows.WM_SYSCHAR,
        => {
            return 0;
        },
        windows.WM_MOUSEMOVE => {
            if (self.core_surface) |cs| {
                const x: f64 = @floatFromInt(windows.GET_X_LPARAM(lparam));
                const y: f64 = @floatFromInt(windows.GET_Y_LPARAM(lparam));
                self.cursor_pos = .{ .x = @floatCast(x), .y = @floatCast(y) };
                const mods = App.getModifiers();
                cs.cursorPosCallback(self.cursor_pos, mods) catch {};
            }
            return 0;
        },
        windows.WM_LBUTTONDOWN,
        windows.WM_MBUTTONDOWN,
        => {
            // WS_CHILD windows don't receive keyboard focus automatically
            // on click — we must call SetFocus explicitly.
            _ = windows.SetFocus(hwnd);
            if (self.core_surface) |cs| {
                const button: input.MouseButton = if (msg == windows.WM_LBUTTONDOWN) .left else .middle;
                const mods = App.getModifiers();
                _ = cs.mouseButtonCallback(.press, button, mods) catch {};
            }
            return 0;
        },
        windows.WM_RBUTTONDOWN => {
            // Right-click: send to core first, if not consumed show context menu
            if (self.core_surface) |cs| {
                const mods = App.getModifiers();
                const consumed = cs.mouseButtonCallback(.press, .right, mods) catch false;
                if (!consumed) {
                    if (self.app) |app| {
                        // Get screen coordinates for context menu
                        var pt: windows.POINT = .{
                            .x = windows.GET_X_LPARAM(lparam),
                            .y = windows.GET_Y_LPARAM(lparam),
                        };
                        _ = windows.ClientToScreen(hwnd, &pt);
                        app.showContextMenu(pt.x, pt.y);
                    }
                }
            }
            return 0;
        },
        windows.WM_LBUTTONUP,
        windows.WM_RBUTTONUP,
        windows.WM_MBUTTONUP,
        => {
            if (self.core_surface) |cs| {
                const button: input.MouseButton = switch (msg) {
                    windows.WM_LBUTTONUP => .left,
                    windows.WM_RBUTTONUP => .right,
                    windows.WM_MBUTTONUP => .middle,
                    else => unreachable,
                };
                const mods = App.getModifiers();
                _ = cs.mouseButtonCallback(.release, button, mods) catch {};
            }
            return 0;
        },
        windows.WM_MOUSEWHEEL => {
            if (self.core_surface) |cs| {
                const delta = windows.GET_WHEEL_DELTA_WPARAM(wparam);
                const scroll_y: f64 = @as(f64, @floatFromInt(delta)) / @as(f64, @floatFromInt(windows.WHEEL_DELTA));
                cs.scrollCallback(0, scroll_y, .{}) catch {};
            }
            return 0;
        },
        windows.WM_MOUSEHWHEEL => {
            if (self.core_surface) |cs| {
                const delta = windows.GET_WHEEL_DELTA_WPARAM(wparam);
                const scroll_x: f64 = @as(f64, @floatFromInt(delta)) / @as(f64, @floatFromInt(windows.WHEEL_DELTA));
                cs.scrollCallback(scroll_x, 0, .{}) catch {};
            }
            return 0;
        },
        windows.WM_CONTEXTMENU => {
            // Already handled in WM_RBUTTONDOWN
            return 0;
        },
        windows.WM_IME_STARTCOMPOSITION => {
            self.composing = true;
            self.imeUpdatePosition();
            // Swallow this: the default handler would draw its own composition
            // window on top of the terminal.
            return 0;
        },
        windows.WM_IME_COMPOSITION => {
            self.handleImeComposition(@truncate(@as(usize, @bitCast(lparam))));
            return 0;
        },
        windows.WM_IME_ENDCOMPOSITION => {
            self.composing = false;
            if (self.core_surface) |cs| cs.preeditCallback(null) catch {};
            return 0;
        },
        else => return windows.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

/// Read a composition string (`GCS_COMPSTR` or `GCS_RESULTSTR`) as UTF-8 into
/// `buf`. Returns null when empty or too long to fit.
fn imeString(himc: windows.HIMC, index: windows.DWORD, buf: []u8) ?[]const u8 {
    // A null buffer queries the required size, in bytes.
    const bytes = windows.ImmGetCompositionStringW(himc, index, null, 0);
    if (bytes <= 0) return null;

    var utf16: [256]u16 = undefined;
    const units = @as(usize, @intCast(bytes)) / @sizeOf(u16);
    if (units == 0 or units > utf16.len) return null;

    if (windows.ImmGetCompositionStringW(
        himc,
        index,
        @ptrCast(&utf16),
        @intCast(bytes),
    ) <= 0) return null;

    const len = std.unicode.utf16LeToUtf8(buf, utf16[0..units]) catch return null;
    return buf[0..len];
}

fn handleImeComposition(self: *Self, flags: u32) void {
    const hwnd = self.child_hwnd orelse return;
    const cs = self.core_surface orelse return;
    const himc = windows.ImmGetContext(hwnd) orelse return;
    defer _ = windows.ImmReleaseContext(hwnd, himc);

    // Worst case 3 UTF-8 bytes per UTF-16 unit of imeString's 256-unit buffer.
    var buf: [256 * 3]u8 = undefined;

    // Committed text first. Clear the preedit before delivering it so the
    // composition doesn't briefly render alongside the committed result.
    if (flags & windows.GCS_RESULTSTR != 0) {
        if (imeString(himc, windows.GCS_RESULTSTR, &buf)) |text| {
            cs.preeditCallback(null) catch {};
            // A key event carrying only text: no key, no mods, not composing.
            // This is how committed IME output reaches the terminal.
            _ = cs.keyCallback(.{
                .action = .press,
                .key = .unidentified,
                .mods = .{},
                .consumed_mods = .{},
                .composing = false,
                .utf8 = text,
                .unshifted_codepoint = 0,
            }) catch |err| {
                log.warn("IME commit failed: {}", .{err});
            };
        }
    }

    if (flags & windows.GCS_COMPSTR != 0) {
        cs.preeditCallback(imeString(himc, windows.GCS_COMPSTR, &buf)) catch {};
        self.imeUpdatePosition();
    }
}

/// Park the IME composition and candidate windows at the terminal cursor.
/// Without this they land in the window's top-left corner.
fn imeUpdatePosition(self: *Self) void {
    const hwnd = self.child_hwnd orelse return;
    const cs = self.core_surface orelse return;
    const himc = windows.ImmGetContext(hwnd) orelse return;
    defer _ = windows.ImmReleaseContext(hwnd, himc);

    // imePoint returns logical coordinates (it divides by the content scale),
    // but Win32 wants physical client pixels, so scale it back up.
    const pos = cs.imePoint();
    const scale = self.getContentScale() catch .{ .x = 1, .y = 1 };
    const pt: windows.POINT = .{
        .x = @intFromFloat(pos.x * scale.x),
        .y = @intFromFloat(pos.y * scale.y),
    };

    _ = windows.ImmSetCompositionWindow(himc, &.{
        .dwStyle = windows.CFS_POINT,
        .ptCurrentPos = pt,
    });
    _ = windows.ImmSetCandidateWindow(himc, &.{
        .dwIndex = 0,
        .dwStyle = windows.CFS_CANDIDATEPOS,
        .ptCurrentPos = pt,
    });
}

fn getSelf(hwnd: windows.HWND) ?*Self {
    const ptr: usize = @bitCast(windows.GetWindowLongPtrW(hwnd, windows.GWLP_USERDATA));
    if (ptr == 0) return null;
    return @ptrFromInt(ptr);
}

/// Handle a key event (press, repeat, release).
fn handleKeyEvent(self: *Self, action: input.Action, wparam: windows.WPARAM, lparam: windows.LPARAM) void {
    const core_surface = self.core_surface orelse return;
    const child = self.child_hwnd orelse return;

    // Translate scancode to Ghostty key
    const key = App.translateScancode(lparam);

    // Get modifier state
    const mods = App.getModifiers();

    // Get text from pending WM_CHAR messages (only for press/repeat).
    // While an IME composition is active there is no WM_CHAR to consume: the
    // text arrives through WM_IME_COMPOSITION instead.
    var utf8_buf: [4]u8 = undefined;
    var utf8_len: u3 = 0;
    var consumed_mods: input.Mods = .{};
    if (action != .release and !self.composing) {
        var char_msg: windows.MSG = undefined;
        if (windows.PeekMessageW(&char_msg, child, windows.WM_CHAR, windows.WM_CHAR, windows.PM_REMOVE) != 0) {
            const codepoint: u21 = @intCast(char_msg.wParam);
            if (codepoint >= 0x20) {
                utf8_len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch 0;
                if (utf8_len > 0 and mods.shift) {
                    consumed_mods.shift = true;
                }
            }
        }
        if (utf8_len == 0) {
            if (windows.PeekMessageW(&char_msg, child, windows.WM_SYSCHAR, windows.WM_SYSCHAR, windows.PM_REMOVE) != 0) {
                const codepoint: u21 = @intCast(char_msg.wParam);
                if (codepoint >= 0x20) {
                    utf8_len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch 0;
                }
            }
        }
    }

    // Get unshifted codepoint
    const unshifted_codepoint: u21 = unshifted: {
        const vk: u32 = @intCast(wparam & 0xFF);
        const mapped = windows.MapVirtualKeyW(vk, windows.MAPVK_VK_TO_CHAR);
        const ch = mapped & 0x7FFFFFFF;
        break :unshifted if (ch > 0 and ch <= 0x10FFFF) @intCast(ch) else 0;
    };

    const effect = core_surface.keyCallback(.{
        .action = action,
        .key = key,
        .mods = mods,
        .consumed_mods = consumed_mods,
        .composing = self.composing,
        .utf8 = utf8_buf[0..utf8_len],
        .unshifted_codepoint = unshifted_codepoint,
    }) catch |err| {
        log.warn("key callback error: {}", .{err});
        return;
    };

    switch (effect) {
        .closed => {
            // The core already called rt_surface.close() before returning
            // .closed, so we don't need to do anything here.
        },
        .consumed, .ignored => {},
    }
}
