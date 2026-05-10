/// Win32 application runtime for Ghostty. This is a native Windows
/// application using the Win32 API with OpenGL rendering.
/// Supports tabs, splits, search overlay, and right-click context menu.
const App = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const input = @import("../../input.zig");
const Config = configpkg.Config;
const CoreApp = @import("../../App.zig");
const CoreSurface = @import("../../Surface.zig");
const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");
const renderer = @import("../../renderer.zig");
const windows = @import("../../os/main.zig").win32;

const log = std.log.scoped(.win32);

/// User-defined wakeup message sent via PostMessage to break out of
/// GetMessage and run the core app's tick.
const WM_WAKEUP: u32 = 0x0400 + 1; // WM_USER + 1

/// Tab bar height in pixels.
const TAB_BAR_HEIGHT: i32 = 30;
/// Search bar height in pixels.
const SEARCH_BAR_HEIGHT: i32 = 30;
/// Width of the search count label (e.g. "3/42").
const SEARCH_COUNT_WIDTH: i32 = 100;
/// SS_RIGHT style for STATIC control (right-aligned text).
const SS_RIGHT: u32 = 0x00000002;

/// Context menu command IDs.
const CMD_COPY: u32 = 1001;
const CMD_PASTE: u32 = 1002;
const CMD_NEW_TAB: u32 = 1003;
const CMD_SPLIT_RIGHT: u32 = 1004;
const CMD_SPLIT_DOWN: u32 = 1005;
const CMD_CLOSE_TAB: u32 = 1006;
const CMD_SEARCH: u32 = 1007;

// -- Menu bar command IDs --
// Ghostty menu
const CMD_SETTINGS: u32 = 2001;
const CMD_RELOAD_CONFIG: u32 = 2002;
// File menu
const CMD_NEW_WINDOW: u32 = 2010;
const CMD_SPLIT_LEFT: u32 = 2011;
const CMD_SPLIT_UP: u32 = 2012;
const CMD_CLOSE_SURFACE: u32 = 2013;
const CMD_CLOSE_WINDOW: u32 = 2014;
const CMD_CLOSE_ALL_WINDOWS: u32 = 2015;
// Edit menu
const CMD_SELECT_ALL: u32 = 2020;
const CMD_FIND: u32 = 2021;
// View menu
const CMD_INCREASE_FONT: u32 = 2030;
const CMD_DECREASE_FONT: u32 = 2031;
const CMD_RESET_FONT: u32 = 2032;
const CMD_TERMINAL_INSPECTOR: u32 = 2033;
const CMD_TOGGLE_FULLSCREEN: u32 = 2034;
// Window menu
const CMD_MINIMIZE: u32 = 2040;
const CMD_ZOOM: u32 = 2041;
const CMD_TOGGLE_FLOAT: u32 = 2042;
const CMD_PREV_SPLIT: u32 = 2043;
const CMD_NEXT_SPLIT: u32 = 2044;
const CMD_EQUALIZE_SPLITS: u32 = 2045;
const CMD_ZOOM_SPLIT: u32 = 2046;
const CMD_PREV_TAB: u32 = 2047;
const CMD_NEXT_TAB: u32 = 2048;
// Help menu
const CMD_ABOUT: u32 = 2090;

/// The core app instance.
core_app: *CoreApp,

/// The configuration.
config: *Config,

/// The allocator.
alloc: Allocator,

/// Whether the app is running.
running: bool = true,

/// The main window handle.
hwnd: ?windows.HWND = null,

/// All tabs managed by this window.
tabs: std.ArrayList(Tab),

/// Index of the currently active tab.
active_tab: usize = 0,

/// All surfaces (needed for cleanup and routing).
surfaces: std.ArrayList(*Surface),

/// Search bar state.
search_hwnd: ?windows.HWND = null,
search_active: bool = false,
search_font: ?windows.HFONT = null,

/// Search count label (shows "X/Y" next to the search box).
search_count_hwnd: ?windows.HWND = null,
search_total: ?usize = null,
search_selected: ?usize = null,

/// Font for the tab bar.
tab_font: ?windows.HFONT = null,

/// Menu bar handle.
menu_bar: ?windows.HMENU = null,

/// Fullscreen state.
is_fullscreen: bool = false,
pre_fullscreen_style: windows.DWORD = 0,
pre_fullscreen_rect: windows.RECT = .{},

/// Float-on-top state.
is_float_on_top: bool = false,

pub fn init(
    self: *App,
    core_app: *CoreApp,
    opts: struct {},
) !void {
    _ = opts;

    const alloc = core_app.alloc;

    // Set working directory to user's home if not already configured
    if (std.process.getEnvVarOwned(alloc, "USERPROFILE")) |home| {
        defer alloc.free(home);
        std.posix.chdir(home) catch {};
    } else |_| {}

    // Load configuration
    var config = try Config.load(alloc);
    errdefer config.deinit();

    const config_ptr = try alloc.create(Config);
    config_ptr.* = config;

    self.* = .{
        .core_app = core_app,
        .config = config_ptr,
        .alloc = alloc,
        .tabs = .empty,
        .surfaces = .empty,
    };

    // Create fonts
    self.tab_font = windows.CreateFontW(
        -14, 0, 0, 0, windows.FW_NORMAL, 0, 0, 0,
        windows.DEFAULT_CHARSET, 0, 0, 0, 0,
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
    );
    self.search_font = windows.CreateFontW(
        -16, 0, 0, 0, windows.FW_NORMAL, 0, 0, 0,
        windows.DEFAULT_CHARSET, 0, 0, 0, 0,
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
    );

    // Create the main window
    try self.createWindow();

    // Register child window class for surfaces
    try Surface.registerClass();

    // Store self pointer in window for use in wndProc
    _ = windows.SetWindowLongPtrW(
        self.hwnd.?,
        windows.GWLP_USERDATA,
        @bitCast(@intFromPtr(self)),
    );

    // Create the search bar (initially hidden)
    self.createSearchBar();

    // Create the menu bar
    self.createMenuBar();

    // Create the first tab with a surface
    try self.createNewTab();
}

pub fn run(self: *App) !void {
    log.info("starting Win32 event loop", .{});

    while (self.running) {
        var msg: windows.MSG = std.mem.zeroes(windows.MSG);
        const ret = windows.GetMessageW(&msg, null, 0, 0);
        if (ret == 0) {
            // WM_QUIT
            self.running = false;
            break;
        }
        if (ret == -1) {
            log.err("GetMessage failed: err={d}", .{windows.GetLastError()});
            return error.Win32Error;
        }
        // Intercept key messages targeted at the search EDIT control.
        // The EDIT control is a child window and receives WM_KEYDOWN
        // directly, bypassing the parent wndProc, so we must handle
        // Escape and Enter here in the message loop.
        if (self.search_active and self.search_hwnd != null and
            msg.hwnd == self.search_hwnd.? and msg.message == windows.WM_KEYDOWN)
        {
            if (msg.wParam == @as(usize, @intCast(windows.VK_ESCAPE))) {
                if (self.getFocusedCoreSurface()) |core| {
                    _ = core.performBindingAction(.end_search) catch {};
                }
                self.hideSearch();
                continue;
            }
            if (msg.wParam == @as(usize, @intCast(windows.VK_RETURN))) {
                if (self.getFocusedCoreSurface()) |core| {
                    const mods = getModifiers();
                    if (mods.shift) {
                        _ = core.performBindingAction(.{ .navigate_search = .previous }) catch {};
                    } else {
                        _ = core.performBindingAction(.{ .navigate_search = .next }) catch {};
                    }
                }
                continue;
            }
        }

        _ = windows.TranslateMessage(&msg);
        _ = windows.DispatchMessageW(&msg);
    }
}

pub fn terminate(self: *App) void {
    // Destroy the window first while surfaces are still alive
    if (self.hwnd) |hwnd| {
        self.hwnd = null;
        if (windows.DestroyWindow(hwnd) == 0) {
            log.warn("DestroyWindow failed: err={d}", .{windows.GetLastError()});
        }
    }

    // Clean up all surfaces
    for (self.surfaces.items) |surface| {
        if (surface.core_surface) |core| {
            core.deinit();
            self.alloc.destroy(core);
        }
        self.core_app.deleteSurface(surface);
        surface.deinit();
        self.alloc.destroy(surface);
    }
    self.surfaces.deinit(self.alloc);

    // Clean up tabs
    for (self.tabs.items) |*tab| {
        tab.deinit();
    }
    self.tabs.deinit(self.alloc);

    // Clean up fonts
    if (self.tab_font) |f| _ = windows.DeleteObject(@ptrCast(f));
    if (self.search_font) |f| _ = windows.DeleteObject(@ptrCast(f));

    self.config.deinit();
    self.alloc.destroy(self.config);
}

pub fn wakeup(self: *App) void {
    if (self.hwnd) |hwnd| {
        if (windows.PostMessageW(hwnd, WM_WAKEUP, 0, 0) == 0) {
            log.warn("PostMessage(WM_WAKEUP) failed: err={d}", .{windows.GetLastError()});
        }
    }
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    switch (action) {
        .quit => {
            windows.PostQuitMessage(0);
            return true;
        },
        .new_window => {
            // TODO: implement multiple windows
            return false;
        },
        .new_tab => {
            self.createNewTab() catch |err| {
                log.err("failed to create new tab: {}", .{err});
                return false;
            };
            return true;
        },
        .close_tab => {
            self.closeTab(value) catch |err| {
                log.err("failed to close tab: {}", .{err});
                return false;
            };
            return true;
        },
        .goto_tab => {
            self.gotoTab(value);
            return true;
        },
        .goto_split => {
            self.gotoSplit(value);
            return true;
        },
        .new_split => {
            self.createNewSplit(value) catch |err| {
                log.err("failed to create new split: {}", .{err});
                return false;
            };
            return true;
        },
        .toggle_fullscreen => {
            self.toggleFullscreen();
            return true;
        },
        .close_window => {
            if (self.hwnd) |hwnd| {
                _ = windows.SendMessageW(hwnd, windows.WM_CLOSE, 0, 0);
            }
            return true;
        },
        .close_all_windows => {
            windows.PostQuitMessage(0);
            return true;
        },
        .toggle_split_zoom => {
            // TODO: implement split zoom
            return false;
        },
        .equalize_splits => {
            if (self.tabs.items.len > self.active_tab) {
                var tab = &self.tabs.items[self.active_tab];
                tab.equalize();
                const hwnd = self.hwnd orelse return false;
                var client_rect: windows.RECT = undefined;
                if (windows.GetClientRect(hwnd, &client_rect) == 0) return false;
                var content_top: i32 = 0;
                if (self.tabs.items.len > 1) content_top = TAB_BAR_HEIGHT;
                if (self.search_active) content_top += SEARCH_BAR_HEIGHT;
                const content_rect: windows.RECT = .{
                    .left = client_rect.left,
                    .top = content_top,
                    .right = client_rect.right,
                    .bottom = client_rect.bottom,
                };
                tab.layout(content_rect);
            }
            return true;
        },
        .float_window => {
            self.toggleFloat();
            return true;
        },
        .open_config => {
            self.openConfig();
            return true;
        },
        .reload_config => {
            self.reloadConfig();
            return true;
        },
        .start_search => {
            self.showSearch(value.needle);
            return true;
        },
        .end_search => {
            self.hideSearch();
            return true;
        },
        .set_title => {
            _ = target;
            if (self.hwnd) |hwnd| {
                const title_slice = value.title;
                var buf: [256]u16 = undefined;
                const len = std.unicode.utf8ToUtf16Le(&buf, title_slice) catch 0;
                if (len < buf.len) {
                    buf[len] = 0;
                    _ = windows.SetWindowTextW(hwnd, @ptrCast(&buf));
                }
            }
            return true;
        },
        .search_total => {
            self.search_total = value.total;
            self.updateSearchCount();
            return true;
        },
        .search_selected => {
            self.search_selected = value.selected;
            self.updateSearchCount();
            return true;
        },
        .mouse_shape => {
            return false;
        },
        .render_inspector => {
            return false;
        },
        else => return false,
    }
}

pub fn performIpc(
    _: Allocator,
    _: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    _: apprt.ipc.Action.Value(action),
) !bool {
    return false;
}

pub fn redrawInspector(_: *App, surface: *Surface) void {
    surface.redrawInspector();
}

// -----------------------------------------------------------------------
// Tab Management
// -----------------------------------------------------------------------

fn createNewTab(self: *App) !void {
    const surface = try self.createSurface();
    errdefer self.destroySurface(surface);

    var tab = try Tab.init(self.alloc, surface);
    try self.tabs.append(self.alloc, tab);
    _ = &tab;

    self.active_tab = self.tabs.items.len - 1;
    self.updateLayout();
    self.updateTabVisibility();
    self.invalidateTabBar();

    // Focus the new surface
    if (surface.child_hwnd) |child| {
        _ = windows.SetFocus(child);
    }
}

fn closeTab(self: *App, mode: apprt.action.CloseTabMode) !void {
    if (self.tabs.items.len == 0) return;

    switch (mode) {
        .this => {
            self.closeTabAt(self.active_tab);
        },
        .other => {
            // Close all tabs except the active one
            var i: usize = self.tabs.items.len;
            while (i > 0) {
                i -= 1;
                if (i != self.active_tab) {
                    self.closeTabAt(i);
                    if (i < self.active_tab) self.active_tab -= 1;
                }
            }
        },
        .right => {
            // Close all tabs to the right
            var i: usize = self.tabs.items.len;
            while (i > self.active_tab + 1) {
                i -= 1;
                self.closeTabAt(i);
            }
        },
    }
}

fn closeTabAt(self: *App, idx: usize) void {
    if (idx >= self.tabs.items.len) return;

    var tab = &self.tabs.items[idx];
    // Destroy all surfaces in this tab
    self.destroySurfacesInTab(tab);
    tab.deinit();
    _ = self.tabs.orderedRemove(idx);

    if (self.tabs.items.len == 0) {
        windows.PostQuitMessage(0);
        return;
    }

    if (self.active_tab >= self.tabs.items.len) {
        self.active_tab = self.tabs.items.len - 1;
    }

    self.updateLayout();
    self.updateTabVisibility();
    self.invalidateTabBar();
}

fn destroySurfacesInTab(self: *App, tab: *Tab) void {
    // Walk the split tree and destroy each surface
    self.destroySurfacesInNode(tab.root);
}

fn destroySurfacesInNode(self: *App, node: *Tab.SplitNode) void {
    switch (node.*) {
        .leaf => |surface| {
            self.destroySurface(surface);
        },
        .split => |s| {
            self.destroySurfacesInNode(s.first);
            self.destroySurfacesInNode(s.second);
        },
    }
}

fn gotoTab(self: *App, target: apprt.action.GotoTab) void {
    const new_idx: usize = switch (target) {
        .previous => if (self.active_tab > 0) self.active_tab - 1 else self.tabs.items.len - 1,
        .next => if (self.active_tab + 1 < self.tabs.items.len) self.active_tab + 1 else 0,
        .last => self.tabs.items.len - 1,
        _ => idx: {
            const val: i32 = @intFromEnum(target);
            if (val >= 0 and @as(usize, @intCast(val)) < self.tabs.items.len) {
                break :idx @intCast(val);
            }
            return;
        },
    };

    if (new_idx == self.active_tab) return;
    self.active_tab = new_idx;
    self.updateTabVisibility();
    self.invalidateTabBar();

    // Focus the active tab's focused surface
    if (self.tabs.items.len > self.active_tab) {
        const tab = &self.tabs.items[self.active_tab];
        if (tab.focused.child_hwnd) |child| {
            _ = windows.SetFocus(child);
        }
    }
}

// -----------------------------------------------------------------------
// Split Management
// -----------------------------------------------------------------------

fn createNewSplit(self: *App, direction: apprt.action.SplitDirection) !void {
    if (self.tabs.items.len == 0) return error.NoTabs;

    const surface = try self.createSurface();
    errdefer self.destroySurface(surface);

    var tab = &self.tabs.items[self.active_tab];
    const split_dir: Tab.SplitNode.Direction = switch (direction) {
        .right, .left => .horizontal,
        .down, .up => .vertical,
    };

    try tab.splitFocused(surface, split_dir);
    self.updateLayout();

    // Focus the new surface
    if (surface.child_hwnd) |child| {
        _ = windows.SetFocus(child);
    }
}

// -----------------------------------------------------------------------
// Surface Lifecycle
// -----------------------------------------------------------------------

fn createSurface(self: *App) !*Surface {
    const surface = try self.alloc.create(Surface);
    errdefer self.alloc.destroy(surface);

    // Initialize with a child window
    try surface.init(self.hwnd.?, self);
    errdefer surface.deinit();

    // Create and register the core surface
    const core_surface = try self.alloc.create(CoreSurface);
    errdefer self.alloc.destroy(core_surface);

    try self.core_app.addSurface(surface);
    errdefer self.core_app.deleteSurface(surface);

    var config = try apprt.surface.newConfig(
        self.core_app,
        self.config,
        .window,
    );
    defer config.deinit();

    core_surface.init(
        self.alloc,
        &config,
        self.core_app,
        self,
        surface,
    ) catch |err| {
        log.err("failed to initialize core surface: {}", .{err});
        return err;
    };

    surface.core_surface = core_surface;

    try self.surfaces.append(self.alloc, surface);
    log.info("new surface created (total: {d})", .{self.surfaces.items.len});
    return surface;
}

fn destroySurface(self: *App, surface: *Surface) void {
    // Remove from our list
    for (self.surfaces.items, 0..) |s, i| {
        if (s == surface) {
            _ = self.surfaces.orderedRemove(i);
            break;
        }
    }

    if (surface.core_surface) |core| {
        core.deinit();
        self.alloc.destroy(core);
        surface.core_surface = null;
    }
    self.core_app.deleteSurface(surface);
    surface.deinit();
    self.alloc.destroy(surface);
}

// -----------------------------------------------------------------------
// Search
// -----------------------------------------------------------------------

fn showSearch(self: *App, needle: [:0]const u8) void {
    self.search_active = true;
    self.search_total = null;
    self.search_selected = null;
    if (self.search_hwnd) |search| {
        _ = windows.ShowWindow(search, windows.SW_SHOWNORMAL);
        _ = windows.SetFocus(search);
        // Set needle text if provided
        if (needle.len > 0) {
            var buf: [256]u16 = undefined;
            const len = std.unicode.utf8ToUtf16Le(&buf, needle) catch 0;
            if (len < buf.len) {
                buf[len] = 0;
                _ = windows.SendMessageW(search, windows.WM_SETTEXT, 0, @bitCast(@intFromPtr(@as([*:0]const u16, @ptrCast(&buf)))));
                // Select all text
                _ = windows.SendMessageW(search, windows.EM_SETSEL, 0, -1);
            }
        }
    }
    if (self.search_count_hwnd) |label| {
        _ = windows.ShowWindow(label, windows.SW_SHOWNORMAL);
    }
    self.updateSearchCount();
    self.updateLayout();
}

fn hideSearch(self: *App) void {
    self.search_active = false;
    self.search_total = null;
    self.search_selected = null;
    if (self.search_hwnd) |search| {
        _ = windows.ShowWindow(search, windows.SW_HIDE);
    }
    if (self.search_count_hwnd) |label| {
        _ = windows.ShowWindow(label, windows.SW_HIDE);
    }
    self.updateLayout();

    // Return focus to the active surface
    if (self.tabs.items.len > self.active_tab) {
        const tab = &self.tabs.items[self.active_tab];
        if (tab.focused.child_hwnd) |child| {
            _ = windows.SetFocus(child);
        }
    }
}

fn createSearchBar(self: *App) void {
    const hwnd = self.hwnd orelse return;
    const hinstance = windows.GetModuleHandleW(null);

    self.search_hwnd = windows.CreateWindowExW(
        windows.WS_EX_CLIENTEDGE,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        null,
        windows.WS_CHILD | windows.ES_LEFT | windows.ES_AUTOHSCROLL,
        0,
        0,
        800,
        SEARCH_BAR_HEIGHT,
        hwnd,
        null,
        hinstance,
        null,
    );

    if (self.search_hwnd) |search| {
        if (self.search_font) |font| {
            _ = windows.SendMessageW(search, windows.WM_SETFONT, @intFromPtr(@as(*anyopaque, @ptrCast(font))), 1);
        }
    }

    // Create a STATIC label for search count display (e.g. "3/42")
    self.search_count_hwnd = windows.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        null,
        windows.WS_CHILD | SS_RIGHT,
        0,
        0,
        SEARCH_COUNT_WIDTH,
        SEARCH_BAR_HEIGHT,
        hwnd,
        null,
        hinstance,
        null,
    );

    if (self.search_count_hwnd) |label| {
        if (self.search_font) |font| {
            _ = windows.SendMessageW(label, windows.WM_SETFONT, @intFromPtr(@as(*anyopaque, @ptrCast(font))), 1);
        }
    }
}

fn handleSearchInput(self: *App) void {
    const search = self.search_hwnd orelse return;
    if (!self.search_active) return;

    // Get text from the EDIT control
    var buf: [256]u16 = undefined;
    const len: usize = @intCast(windows.SendMessageW(search, windows.WM_GETTEXT, buf.len, @bitCast(@intFromPtr(@as([*]u16, &buf)))));
    if (len == 0) {
        // Empty search - clear
        if (self.tabs.items.len > self.active_tab) {
            const tab = &self.tabs.items[self.active_tab];
            if (tab.focused.core_surface) |core| {
                _ = core.performBindingAction(.{ .search = "" }) catch {};
            }
        }
        return;
    }

    // Convert UTF-16 to UTF-8
    var utf8_buf: [1024]u8 = undefined;
    var utf8_len: usize = 0;
    for (buf[0..len]) |wc| {
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(wc), &tmp) catch continue;
        if (utf8_len + n > utf8_buf.len - 1) break;
        @memcpy(utf8_buf[utf8_len..][0..n], tmp[0..n]);
        utf8_len += n;
    }
    utf8_buf[utf8_len] = 0;
    const needle: [:0]const u8 = utf8_buf[0..utf8_len :0];

    // Send to focused surface
    if (self.tabs.items.len > self.active_tab) {
        const tab = &self.tabs.items[self.active_tab];
        if (tab.focused.core_surface) |core| {
            _ = core.performBindingAction(.{ .search = needle }) catch {};
        }
    }
}

fn updateSearchCount(self: *App) void {
    const label = self.search_count_hwnd orelse return;
    if (!self.search_active) return;

    var text_buf: [32]u8 = undefined;
    const text = if (self.search_total) |total|
        if (self.search_selected) |sel|
            std.fmt.bufPrint(&text_buf, "{d}/{d}", .{ sel + 1, total }) catch ""
        else
            std.fmt.bufPrint(&text_buf, "0/{d}", .{total}) catch ""
    else
        "";

    var utf16_buf: [64]u16 = undefined;
    const utf16_len = std.unicode.utf8ToUtf16Le(&utf16_buf, text) catch 0;
    if (utf16_len < utf16_buf.len) {
        utf16_buf[utf16_len] = 0;
        _ = windows.SendMessageW(label, windows.WM_SETTEXT, 0, @bitCast(@intFromPtr(@as([*:0]const u16, @ptrCast(&utf16_buf)))));
    }
}

// -----------------------------------------------------------------------
// Menu Bar
// -----------------------------------------------------------------------

fn createMenuBar(self: *App) void {
    @setEvalBranchQuota(50000);
    const hwnd = self.hwnd orelse return;
    const menu_bar = windows.CreateMenu() orelse return;
    self.menu_bar = menu_bar;

    // -- Ghostty menu --
    if (windows.CreatePopupMenu()) |ghostty| {
        _ = windows.AppendMenuW(ghostty, windows.MF_STRING, CMD_SETTINGS, std.unicode.utf8ToUtf16LeStringLiteral("Settings...\tCtrl+,"));
        _ = windows.AppendMenuW(ghostty, windows.MF_STRING, CMD_RELOAD_CONFIG, std.unicode.utf8ToUtf16LeStringLiteral("Reload Configuration\tCtrl+Shift+,"));
        _ = windows.AppendMenuW(ghostty, windows.MF_SEPARATOR, 0, null);
        _ = windows.AppendMenuW(ghostty, windows.MF_STRING, CMD_CLOSE_ALL_WINDOWS, std.unicode.utf8ToUtf16LeStringLiteral("Quit Ghostty\tAlt+F4"));
        _ = windows.AppendMenuW(menu_bar, windows.MF_POPUP, @intFromPtr(ghostty), std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"));
    }

    // -- File menu --
    if (windows.CreatePopupMenu()) |file| {
        _ = windows.AppendMenuW(file, windows.MF_STRING, CMD_NEW_WINDOW, std.unicode.utf8ToUtf16LeStringLiteral("New Window\tCtrl+Shift+N"));
        _ = windows.AppendMenuW(file, windows.MF_STRING, CMD_NEW_TAB, std.unicode.utf8ToUtf16LeStringLiteral("New Tab\tCtrl+Shift+T"));
        _ = windows.AppendMenuW(file, windows.MF_SEPARATOR, 0, null);
        _ = windows.AppendMenuW(file, windows.MF_STRING, CMD_SPLIT_RIGHT, std.unicode.utf8ToUtf16LeStringLiteral("Split Right\tCtrl+Shift+D"));
        _ = windows.AppendMenuW(file, windows.MF_STRING, CMD_SPLIT_LEFT, std.unicode.utf8ToUtf16LeStringLiteral("Split Left"));
        _ = windows.AppendMenuW(file, windows.MF_STRING, CMD_SPLIT_DOWN, std.unicode.utf8ToUtf16LeStringLiteral("Split Down\tCtrl+Shift+E"));
        _ = windows.AppendMenuW(file, windows.MF_STRING, CMD_SPLIT_UP, std.unicode.utf8ToUtf16LeStringLiteral("Split Up"));
        _ = windows.AppendMenuW(file, windows.MF_SEPARATOR, 0, null);
        _ = windows.AppendMenuW(file, windows.MF_STRING, CMD_CLOSE_SURFACE, std.unicode.utf8ToUtf16LeStringLiteral("Close\tCtrl+Shift+W"));
        _ = windows.AppendMenuW(file, windows.MF_STRING, CMD_CLOSE_TAB, std.unicode.utf8ToUtf16LeStringLiteral("Close Tab"));
        _ = windows.AppendMenuW(file, windows.MF_STRING, CMD_CLOSE_WINDOW, std.unicode.utf8ToUtf16LeStringLiteral("Close Window"));
        _ = windows.AppendMenuW(file, windows.MF_STRING, CMD_CLOSE_ALL_WINDOWS, std.unicode.utf8ToUtf16LeStringLiteral("Close All Windows"));
        _ = windows.AppendMenuW(menu_bar, windows.MF_POPUP, @intFromPtr(file), std.unicode.utf8ToUtf16LeStringLiteral("File"));
    }

    // -- Edit menu --
    if (windows.CreatePopupMenu()) |edit| {
        _ = windows.AppendMenuW(edit, windows.MF_STRING, CMD_COPY, std.unicode.utf8ToUtf16LeStringLiteral("Copy\tCtrl+Shift+C"));
        _ = windows.AppendMenuW(edit, windows.MF_STRING, CMD_PASTE, std.unicode.utf8ToUtf16LeStringLiteral("Paste\tCtrl+Shift+V"));
        _ = windows.AppendMenuW(edit, windows.MF_STRING, CMD_SELECT_ALL, std.unicode.utf8ToUtf16LeStringLiteral("Select All\tCtrl+Shift+A"));
        _ = windows.AppendMenuW(edit, windows.MF_SEPARATOR, 0, null);
        _ = windows.AppendMenuW(edit, windows.MF_STRING, CMD_FIND, std.unicode.utf8ToUtf16LeStringLiteral("Find...\tCtrl+Shift+F"));
        _ = windows.AppendMenuW(menu_bar, windows.MF_POPUP, @intFromPtr(edit), std.unicode.utf8ToUtf16LeStringLiteral("Edit"));
    }

    // -- View menu --
    if (windows.CreatePopupMenu()) |view| {
        _ = windows.AppendMenuW(view, windows.MF_STRING, CMD_INCREASE_FONT, std.unicode.utf8ToUtf16LeStringLiteral("Increase Font Size\tCtrl+="));
        _ = windows.AppendMenuW(view, windows.MF_STRING, CMD_DECREASE_FONT, std.unicode.utf8ToUtf16LeStringLiteral("Decrease Font Size\tCtrl+-"));
        _ = windows.AppendMenuW(view, windows.MF_STRING, CMD_RESET_FONT, std.unicode.utf8ToUtf16LeStringLiteral("Reset Font Size\tCtrl+0"));
        _ = windows.AppendMenuW(view, windows.MF_SEPARATOR, 0, null);
        _ = windows.AppendMenuW(view, windows.MF_STRING, CMD_TERMINAL_INSPECTOR, std.unicode.utf8ToUtf16LeStringLiteral("Terminal Inspector"));
        _ = windows.AppendMenuW(view, windows.MF_SEPARATOR, 0, null);
        _ = windows.AppendMenuW(view, windows.MF_STRING, CMD_TOGGLE_FULLSCREEN, std.unicode.utf8ToUtf16LeStringLiteral("Toggle Full Screen\tF11"));
        _ = windows.AppendMenuW(menu_bar, windows.MF_POPUP, @intFromPtr(view), std.unicode.utf8ToUtf16LeStringLiteral("View"));
    }

    // -- Window menu --
    if (windows.CreatePopupMenu()) |win| {
        _ = windows.AppendMenuW(win, windows.MF_STRING, CMD_MINIMIZE, std.unicode.utf8ToUtf16LeStringLiteral("Minimize"));
        _ = windows.AppendMenuW(win, windows.MF_STRING, CMD_ZOOM, std.unicode.utf8ToUtf16LeStringLiteral("Zoom"));
        _ = windows.AppendMenuW(win, windows.MF_STRING, CMD_TOGGLE_FULLSCREEN, std.unicode.utf8ToUtf16LeStringLiteral("Toggle Full Screen\tF11"));
        _ = windows.AppendMenuW(win, windows.MF_SEPARATOR, 0, null);
        _ = windows.AppendMenuW(win, windows.MF_STRING, CMD_PREV_SPLIT, std.unicode.utf8ToUtf16LeStringLiteral("Select Previous Split\tCtrl+Shift+["));
        _ = windows.AppendMenuW(win, windows.MF_STRING, CMD_NEXT_SPLIT, std.unicode.utf8ToUtf16LeStringLiteral("Select Next Split\tCtrl+Shift+]"));
        _ = windows.AppendMenuW(win, windows.MF_STRING, CMD_EQUALIZE_SPLITS, std.unicode.utf8ToUtf16LeStringLiteral("Equalize Splits"));
        _ = windows.AppendMenuW(win, windows.MF_STRING, CMD_ZOOM_SPLIT, std.unicode.utf8ToUtf16LeStringLiteral("Zoom Split"));
        _ = windows.AppendMenuW(win, windows.MF_SEPARATOR, 0, null);
        _ = windows.AppendMenuW(win, windows.MF_STRING, CMD_PREV_TAB, std.unicode.utf8ToUtf16LeStringLiteral("Previous Tab\tCtrl+Shift+Tab"));
        _ = windows.AppendMenuW(win, windows.MF_STRING, CMD_NEXT_TAB, std.unicode.utf8ToUtf16LeStringLiteral("Next Tab\tCtrl+Tab"));
        _ = windows.AppendMenuW(win, windows.MF_SEPARATOR, 0, null);
        _ = windows.AppendMenuW(win, windows.MF_STRING, CMD_TOGGLE_FLOAT, std.unicode.utf8ToUtf16LeStringLiteral("Float on Top"));
        _ = windows.AppendMenuW(menu_bar, windows.MF_POPUP, @intFromPtr(win), std.unicode.utf8ToUtf16LeStringLiteral("Window"));
    }

    // -- Help menu --
    if (windows.CreatePopupMenu()) |help| {
        _ = windows.AppendMenuW(help, windows.MF_STRING, CMD_ABOUT, std.unicode.utf8ToUtf16LeStringLiteral("About Ghostty"));
        _ = windows.AppendMenuW(menu_bar, windows.MF_POPUP, @intFromPtr(help), std.unicode.utf8ToUtf16LeStringLiteral("Help"));
    }

    _ = windows.SetMenu(hwnd, menu_bar);
    _ = windows.DrawMenuBar(hwnd);
}

// -----------------------------------------------------------------------
// Context Menu
// -----------------------------------------------------------------------

pub fn showContextMenu(self: *App, x: i32, y: i32) void {
    const hwnd = self.hwnd orelse return;
    const menu = windows.CreatePopupMenu() orelse return;
    defer _ = windows.DestroyMenu(menu);

    _ = windows.AppendMenuW(menu, windows.MF_STRING, CMD_COPY, std.unicode.utf8ToUtf16LeStringLiteral("Copy\tCtrl+Shift+C"));
    _ = windows.AppendMenuW(menu, windows.MF_STRING, CMD_PASTE, std.unicode.utf8ToUtf16LeStringLiteral("Paste\tCtrl+Shift+V"));
    _ = windows.AppendMenuW(menu, windows.MF_SEPARATOR, 0, null);
    _ = windows.AppendMenuW(menu, windows.MF_STRING, CMD_SEARCH, std.unicode.utf8ToUtf16LeStringLiteral("Search\tCtrl+Shift+F"));
    _ = windows.AppendMenuW(menu, windows.MF_SEPARATOR, 0, null);
    _ = windows.AppendMenuW(menu, windows.MF_STRING, CMD_NEW_TAB, std.unicode.utf8ToUtf16LeStringLiteral("New Tab\tCtrl+Shift+T"));
    _ = windows.AppendMenuW(menu, windows.MF_STRING, CMD_SPLIT_RIGHT, std.unicode.utf8ToUtf16LeStringLiteral("Split Right"));
    _ = windows.AppendMenuW(menu, windows.MF_STRING, CMD_SPLIT_DOWN, std.unicode.utf8ToUtf16LeStringLiteral("Split Down"));
    _ = windows.AppendMenuW(menu, windows.MF_SEPARATOR, 0, null);
    _ = windows.AppendMenuW(menu, windows.MF_STRING, CMD_CLOSE_TAB, std.unicode.utf8ToUtf16LeStringLiteral("Close Tab\tCtrl+Shift+W"));

    const cmd = windows.TrackPopupMenu(
        menu,
        windows.TPM_LEFTALIGN | windows.TPM_TOPALIGN | windows.TPM_RETURNCMD,
        x, y, 0, hwnd, null,
    );

    if (cmd != 0) {
        self.handleMenuCommand(@intCast(@as(u32, @bitCast(cmd))));
    }
}

fn handleMenuCommand(self: *App, cmd: u32) void {
    switch (cmd) {
        CMD_COPY => {
            if (self.getFocusedCoreSurface()) |core_sfc| {
                _ = core_sfc.performBindingAction(.{ .copy_to_clipboard = .mixed }) catch {};
            }
        },
        CMD_PASTE => {
            if (self.getFocusedCoreSurface()) |core_sfc| {
                _ = core_sfc.performBindingAction(.paste_from_clipboard) catch {};
            }
        },
        CMD_SELECT_ALL => {
            if (self.getFocusedCoreSurface()) |core_sfc| {
                _ = core_sfc.performBindingAction(.select_all) catch {};
            }
        },
        CMD_SEARCH, CMD_FIND => {
            if (self.getFocusedCoreSurface()) |core_sfc| {
                _ = core_sfc.performBindingAction(.start_search) catch {};
            }
        },
        CMD_NEW_WINDOW => {
            // TODO: multiple windows
        },
        CMD_NEW_TAB => {
            self.createNewTab() catch {};
        },
        CMD_SPLIT_RIGHT => {
            self.createNewSplit(.right) catch {};
        },
        CMD_SPLIT_LEFT => {
            self.createNewSplit(.left) catch {};
        },
        CMD_SPLIT_DOWN => {
            self.createNewSplit(.down) catch {};
        },
        CMD_SPLIT_UP => {
            self.createNewSplit(.up) catch {};
        },
        CMD_CLOSE_SURFACE => {
            // Close the focused split surface (or the whole tab if only one)
            self.closeTab(.this) catch {};
        },
        CMD_CLOSE_TAB => {
            self.closeTab(.this) catch {};
        },
        CMD_CLOSE_WINDOW => {
            if (self.hwnd) |hwnd| {
                _ = windows.SendMessageW(hwnd, windows.WM_CLOSE, 0, 0);
            }
        },
        CMD_CLOSE_ALL_WINDOWS => {
            windows.PostQuitMessage(0);
        },
        CMD_SETTINGS => {
            self.openConfig();
        },
        CMD_RELOAD_CONFIG => {
            self.reloadConfig();
        },
        CMD_INCREASE_FONT => {
            if (self.getFocusedCoreSurface()) |core_sfc| {
                _ = core_sfc.performBindingAction(.{ .increase_font_size = 1 }) catch {};
            }
        },
        CMD_DECREASE_FONT => {
            if (self.getFocusedCoreSurface()) |core_sfc| {
                _ = core_sfc.performBindingAction(.{ .decrease_font_size = 1 }) catch {};
            }
        },
        CMD_RESET_FONT => {
            if (self.getFocusedCoreSurface()) |core_sfc| {
                _ = core_sfc.performBindingAction(.reset_font_size) catch {};
            }
        },
        CMD_TERMINAL_INSPECTOR => {
            if (self.getFocusedCoreSurface()) |core_sfc| {
                _ = core_sfc.performBindingAction(.{ .inspector = .toggle }) catch {};
            }
        },
        CMD_TOGGLE_FULLSCREEN => {
            self.toggleFullscreen();
        },
        CMD_MINIMIZE => {
            if (self.hwnd) |hwnd| {
                _ = windows.ShowWindow(hwnd, windows.SW_MINIMIZE);
            }
        },
        CMD_ZOOM => {
            if (self.hwnd) |hwnd| {
                if (windows.IsZoomed(hwnd) != 0) {
                    _ = windows.ShowWindow(hwnd, windows.SW_RESTORE);
                } else {
                    _ = windows.ShowWindow(hwnd, windows.SW_MAXIMIZE);
                }
            }
        },
        CMD_TOGGLE_FLOAT => {
            self.toggleFloat();
        },
        CMD_PREV_SPLIT => {
            self.gotoSplit(.previous);
        },
        CMD_NEXT_SPLIT => {
            self.gotoSplit(.next);
        },
        CMD_EQUALIZE_SPLITS => {
            _ = self.performAction(.{ .app = {} }, .equalize_splits, {}) catch {};
        },
        CMD_ZOOM_SPLIT => {
            // TODO: implement split zoom
        },
        CMD_PREV_TAB => {
            self.gotoTab(.previous);
        },
        CMD_NEXT_TAB => {
            self.gotoTab(.next);
        },
        CMD_ABOUT => {
            self.showAbout();
        },
        else => {},
    }
}

// -----------------------------------------------------------------------
// Layout
// -----------------------------------------------------------------------

fn updateLayout(self: *App) void {
    const hwnd = self.hwnd orelse return;
    var client_rect: windows.RECT = undefined;
    if (windows.GetClientRect(hwnd, &client_rect) == 0) return;

    const total_w = client_rect.right - client_rect.left;

    // Position tab bar at top (drawn in WM_PAINT, no child window needed)
    var content_top: i32 = 0;

    // Only show tab bar if there's more than one tab
    if (self.tabs.items.len > 1) {
        content_top = TAB_BAR_HEIGHT;
    }

    // Position search bar below tab bar if active
    if (self.search_active) {
        const search_edit_w = total_w - SEARCH_COUNT_WIDTH;
        if (self.search_hwnd) |search| {
            _ = windows.MoveWindow(search, 0, content_top, search_edit_w, SEARCH_BAR_HEIGHT, 1);
        }
        if (self.search_count_hwnd) |label| {
            _ = windows.MoveWindow(label, search_edit_w, content_top, SEARCH_COUNT_WIDTH, SEARCH_BAR_HEIGHT, 1);
        }
        content_top += SEARCH_BAR_HEIGHT;
    }

    // Content area for the active tab's surfaces
    const content_rect: windows.RECT = .{
        .left = client_rect.left,
        .top = content_top,
        .right = client_rect.right,
        .bottom = client_rect.bottom,
    };

    if (self.tabs.items.len > self.active_tab) {
        var tab = &self.tabs.items[self.active_tab];
        tab.layout(content_rect);
    }
}

fn updateTabVisibility(self: *App) void {
    // Show surfaces in the active tab, hide others
    for (self.tabs.items, 0..) |*tab, i| {
        const visible = (i == self.active_tab);
        self.setTabVisibility(tab, visible);
    }
}

fn setTabVisibility(self: *App, tab: *Tab, visible: bool) void {
    self.setNodeVisibility(tab.root, visible);
}

fn setNodeVisibility(_: *App, node: *Tab.SplitNode, visible: bool) void {
    switch (node.*) {
        .leaf => |surface| {
            if (surface.child_hwnd) |child| {
                _ = windows.ShowWindow(child, if (visible) windows.SW_SHOWNORMAL else 0);
            }
        },
        .split => |s| {
            setNodeVisibility(undefined, s.first, visible);
            setNodeVisibility(undefined, s.second, visible);
        },
    }
}

fn invalidateTabBar(self: *App) void {
    if (self.hwnd) |hwnd| {
        var rect: windows.RECT = .{
            .left = 0,
            .top = 0,
            .right = 2000,
            .bottom = TAB_BAR_HEIGHT,
        };
        _ = windows.InvalidateRect(hwnd, &rect, 1);
        _ = &rect;
    }
}

// -----------------------------------------------------------------------
// Tab Bar Drawing
// -----------------------------------------------------------------------

fn drawTabBar(self: *App, hdc: windows.HDC) void {
    if (self.tabs.items.len <= 1) return;

    const hwnd = self.hwnd orelse return;
    var client_rect: windows.RECT = undefined;
    if (windows.GetClientRect(hwnd, &client_rect) == 0) return;

    // Draw background
    const bg_color: u32 = 0x00282828; // Dark grey (BGR)
    const bg_brush = windows.CreateSolidBrush(bg_color) orelse return;
    defer _ = windows.DeleteObject(@ptrCast(bg_brush));
    var bar_rect: windows.RECT = .{
        .left = 0,
        .top = 0,
        .right = client_rect.right,
        .bottom = TAB_BAR_HEIGHT,
    };
    _ = windows.FillRect(hdc, &bar_rect, bg_brush);

    // Select font
    var old_font: ?*anyopaque = null;
    if (self.tab_font) |font| {
        old_font = windows.SelectObject(hdc, @ptrCast(font));
    }
    defer if (old_font) |f| {
        _ = windows.SelectObject(hdc, f);
    };

    _ = windows.SetBkMode(hdc, windows.TRANSPARENT);

    // Draw each tab
    const tab_width: i32 = @min(200, @divTrunc(client_rect.right, @as(i32, @intCast(self.tabs.items.len))));
    for (self.tabs.items, 0..) |_, i| {
        const x: i32 = @as(i32, @intCast(i)) * tab_width;
        const is_active = (i == self.active_tab);

        // Tab background
        const tab_color: u32 = if (is_active) 0x00404040 else 0x00303030;
        const tab_brush = windows.CreateSolidBrush(tab_color) orelse continue;
        defer _ = windows.DeleteObject(@ptrCast(tab_brush));
        var tab_rect: windows.RECT = .{
            .left = x + 1,
            .top = 2,
            .right = x + tab_width - 1,
            .bottom = TAB_BAR_HEIGHT - 2,
        };
        _ = windows.FillRect(hdc, &tab_rect, tab_brush);

        // Tab title
        _ = windows.SetTextColor(hdc, if (is_active) 0x00FFFFFF else 0x00AAAAAA);
        var title_buf: [32]u16 = undefined;
        const title_text = std.fmt.bufPrint(
            std.mem.asBytes(&title_buf),
            "Tab {d}",
            .{i + 1},
        ) catch "Tab";
        _ = title_text;

        // Use a simple number label
        var num_buf: [16]u16 = undefined;
        const idx_val = i + 1;
        const digit_count: usize = if (idx_val < 10) 1 else if (idx_val < 100) 2 else 3;
        var temp_val = idx_val;
        var d: usize = digit_count;
        while (d > 0) {
            d -= 1;
            num_buf[d] = @intCast('0' + (temp_val % 10));
            temp_val /= 10;
        }
        // Prefix with "Tab "
        const prefix = std.unicode.utf8ToUtf16LeStringLiteral("Tab ");
        var full_buf: [20]u16 = undefined;
        @memcpy(full_buf[0..4], prefix[0..4]);
        @memcpy(full_buf[4..][0..digit_count], num_buf[0..digit_count]);
        const text_len: i32 = @intCast(4 + digit_count);

        _ = windows.TextOutW(hdc, x + 10, 7, &full_buf, text_len);
    }
}

fn handleTabBarClick(self: *App, x: i32) void {
    if (self.tabs.items.len <= 1) return;

    const hwnd = self.hwnd orelse return;
    var client_rect: windows.RECT = undefined;
    if (windows.GetClientRect(hwnd, &client_rect) == 0) return;

    const tab_width: i32 = @min(200, @divTrunc(client_rect.right, @as(i32, @intCast(self.tabs.items.len))));
    const clicked_tab: usize = @intCast(@divTrunc(x, tab_width));

    if (clicked_tab < self.tabs.items.len and clicked_tab != self.active_tab) {
        self.active_tab = clicked_tab;
        self.updateTabVisibility();
        self.updateLayout();
        self.invalidateTabBar();

        // Focus the new active tab's surface
        const tab = &self.tabs.items[self.active_tab];
        if (tab.focused.child_hwnd) |child| {
            _ = windows.SetFocus(child);
        }
    }
}

// -----------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------

fn getFocusedCoreSurface(self: *App) ?*CoreSurface {
    if (self.tabs.items.len <= self.active_tab) return null;
    const tab = &self.tabs.items[self.active_tab];
    return tab.focused.core_surface;
}

/// Called by a Surface's child window when it receives focus.
pub fn surfaceGotFocus(self: *App, surface: *Surface) void {
    // Update the focused surface in the active tab
    if (self.tabs.items.len > self.active_tab) {
        var tab = &self.tabs.items[self.active_tab];
        tab.focused = surface;
    }
}

// -----------------------------------------------------------------------
// Fullscreen, Float, Config, Navigation
// -----------------------------------------------------------------------

fn toggleFullscreen(self: *App) void {
    const hwnd = self.hwnd orelse return;

    if (self.is_fullscreen) {
        // Restore from fullscreen
        _ = windows.SetWindowLongPtrW(hwnd, windows.GWL_STYLE, @bitCast(@as(isize, @intCast(self.pre_fullscreen_style))));
        _ = windows.SetWindowPos(
            hwnd,
            null,
            self.pre_fullscreen_rect.left,
            self.pre_fullscreen_rect.top,
            self.pre_fullscreen_rect.right - self.pre_fullscreen_rect.left,
            self.pre_fullscreen_rect.bottom - self.pre_fullscreen_rect.top,
            windows.SWP_NOZORDER | windows.SWP_FRAMECHANGED,
        );
        if (self.menu_bar) |mb| {
            _ = windows.SetMenu(hwnd, mb);
        }
        self.is_fullscreen = false;
    } else {
        // Save current state
        self.pre_fullscreen_style = @bitCast(@as(u32, @truncate(@as(usize, @bitCast(windows.GetWindowLongPtrW(hwnd, windows.GWL_STYLE))))));
        _ = windows.GetWindowRect(hwnd, &self.pre_fullscreen_rect);

        // Remove title bar and borders
        const new_style = self.pre_fullscreen_style & ~@as(windows.DWORD, windows.WS_OVERLAPPEDWINDOW);
        _ = windows.SetWindowLongPtrW(hwnd, windows.GWL_STYLE, @bitCast(@as(isize, @intCast(new_style))));

        // Get monitor dimensions
        const monitor = windows.MonitorFromWindow(hwnd, windows.MONITOR_DEFAULTTONEAREST) orelse return;
        var mi: windows.MONITORINFO = .{};
        if (windows.GetMonitorInfoW(monitor, &mi) != 0) {
            _ = windows.SetWindowPos(
                hwnd,
                null,
                mi.rcMonitor.left,
                mi.rcMonitor.top,
                mi.rcMonitor.right - mi.rcMonitor.left,
                mi.rcMonitor.bottom - mi.rcMonitor.top,
                windows.SWP_NOZORDER | windows.SWP_FRAMECHANGED,
            );
        }
        // Hide menu bar in fullscreen
        _ = windows.SetMenu(hwnd, null);
        self.is_fullscreen = true;
    }
    self.updateLayout();
}

fn toggleFloat(self: *App) void {
    const hwnd = self.hwnd orelse return;
    self.is_float_on_top = !self.is_float_on_top;
    _ = windows.SetWindowPos(
        hwnd,
        if (self.is_float_on_top) windows.HWND_TOPMOST else windows.HWND_NOTOPMOST,
        0, 0, 0, 0,
        windows.SWP_NOMOVE | windows.SWP_NOSIZE,
    );
}

fn openConfig(self: *App) void {
    _ = self;
    // Open the config file in the default editor
    const config_path = std.process.getEnvVarOwned(
        std.heap.page_allocator,
        "LOCALAPPDATA",
    ) catch return;
    defer std.heap.page_allocator.free(config_path);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const full_path = std.fmt.bufPrintZ(
        &path_buf,
        "{s}\\ghostty\\config.ghostty",
        .{config_path},
    ) catch return;

    // Use ShellExecute via std to open the config file
    var buf16: [512]u16 = undefined;
    const len = std.unicode.utf8ToUtf16Le(&buf16, full_path) catch return;
    if (len >= buf16.len) return;
    buf16[len] = 0;

    _ = ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("open"), @ptrCast(&buf16), null, null, windows.SW_SHOWNORMAL);
}

extern "shell32" fn ShellExecuteW(
    hwnd: ?windows.HWND,
    lpOperation: ?[*:0]const u16,
    lpFile: [*:0]const u16,
    lpParameters: ?[*:0]const u16,
    lpDirectory: ?[*:0]const u16,
    nShowCmd: windows.INT,
) callconv(windows.WINAPI) isize;

fn reloadConfig(self: *App) void {
    var config = Config.load(self.alloc) catch |err| {
        log.err("failed to reload config: {}", .{err});
        return;
    };
    self.config.deinit();
    self.config.* = config;
    _ = &config;
    log.info("configuration reloaded", .{});
}

fn gotoSplit(self: *App, direction: apprt.action.GotoSplit) void {
    if (self.tabs.items.len <= self.active_tab) return;
    const tab = &self.tabs.items[self.active_tab];
    const current = tab.focused;

    // Collect all leaf surfaces in tree order
    var leaves: [64]*Surface = undefined;
    var count: usize = 0;
    collectLeaves(tab.root, &leaves, &count);

    if (count <= 1) return;

    // Find current surface index
    var current_idx: usize = 0;
    for (leaves[0..count], 0..) |s, i| {
        if (s == current) {
            current_idx = i;
            break;
        }
    }

    const new_idx: usize = switch (direction) {
        .previous => if (current_idx > 0) current_idx - 1 else count - 1,
        .next => if (current_idx + 1 < count) current_idx + 1 else 0,
        else => return,
    };

    tab.focused = leaves[new_idx];
    if (leaves[new_idx].child_hwnd) |child| {
        _ = windows.SetFocus(child);
    }
}

fn collectLeaves(node: *Tab.SplitNode, buf: *[64]*Surface, count: *usize) void {
    switch (node.*) {
        .leaf => |surface| {
            if (count.* < buf.len) {
                buf[count.*] = surface;
                count.* += 1;
            }
        },
        .split => |s| {
            collectLeaves(s.first, buf, count);
            collectLeaves(s.second, buf, count);
        },
    }
}

fn showAbout(_: *App) void {
    @setEvalBranchQuota(10000);
    _ = MessageBoxW(
        null,
        std.unicode.utf8ToUtf16LeStringLiteral(
            "Ghostty Terminal Emulator\n\n" ++
                "A fast, native, feature-rich terminal emulator.\n\n" ++
                "Win32 port authored by Claude Opus 4.6 via GitHub Copilot.\n\n" ++
                "https://ghostty.org",
        ),
        std.unicode.utf8ToUtf16LeStringLiteral("About Ghostty"),
        0, // MB_OK
    );
}

extern "user32" fn MessageBoxW(
    hWnd: ?windows.HWND,
    lpText: [*:0]const u16,
    lpCaption: [*:0]const u16,
    uType: windows.UINT,
) callconv(windows.WINAPI) windows.INT;

// -----------------------------------------------------------------------
// Window Creation
// -----------------------------------------------------------------------

fn createWindow(self: *App) !void {
    const class_name = comptime std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWindow");
    const hinstance = windows.GetModuleHandleW(null);

    // Load the application icon from the embedded resource (ID 1)
    const icon = windows.LoadIconW(hinstance, @ptrFromInt(1));
    const icon_sm = windows.LoadIconW(hinstance, @ptrFromInt(1));

    const wc: windows.WNDCLASSEXW = .{
        .cbSize = @sizeOf(windows.WNDCLASSEXW),
        .style = windows.CS_HREDRAW | windows.CS_VREDRAW,
        .lpfnWndProc = wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = icon,
        .hCursor = windows.LoadCursorW(null, windows.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = icon_sm,
    };

    if (windows.RegisterClassExW(&wc) == 0) {
        log.err("RegisterClassExW failed: err={d}", .{windows.GetLastError()});
        return error.Win32Error;
    }

    const title = comptime std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");

    self.hwnd = windows.CreateWindowExW(
        0, // dwExStyle
        class_name,
        title,
        windows.WS_OVERLAPPEDWINDOW | windows.WS_CLIPCHILDREN,
        windows.CW_USEDEFAULT,
        windows.CW_USEDEFAULT,
        800,
        600,
        null,
        null,
        hinstance,
        null,
    );

    if (self.hwnd == null) {
        log.err("CreateWindowExW failed: err={d}", .{windows.GetLastError()});
        return error.Win32Error;
    }

    _ = windows.ShowWindow(self.hwnd.?, windows.SW_SHOWNORMAL);
    _ = windows.UpdateWindow(self.hwnd.?);
}

fn getApp(hwnd: windows.HWND) ?*App {
    const ptr: usize = @bitCast(windows.GetWindowLongPtrW(hwnd, windows.GWLP_USERDATA));
    if (ptr == 0) return null;
    return @ptrFromInt(ptr);
}

// -----------------------------------------------------------------------
// Window Procedure
// -----------------------------------------------------------------------

fn wndProc(
    hwnd: windows.HWND,
    msg: u32,
    wparam: windows.WPARAM,
    lparam: windows.LPARAM,
) callconv(windows.WINAPI) windows.LRESULT {
    switch (msg) {
        windows.WM_CLOSE => {
            windows.PostQuitMessage(0);
            return 0;
        },
        windows.WM_ACTIVATE => {
            // When the window is reactivated (e.g. alt-tab back),
            // restore focus to the active tab's surface child window
            // so keyboard input resumes working.
            const activate_state = windows.LOWORD(@as(isize, @intCast(wparam)));
            if (activate_state != 0) { // WA_ACTIVE or WA_CLICKACTIVE
                if (getApp(hwnd)) |app| {
                    if (app.search_active) {
                        if (app.search_hwnd) |search| {
                            _ = windows.SetFocus(search);
                        }
                    } else if (app.tabs.items.len > app.active_tab) {
                        const tab = &app.tabs.items[app.active_tab];
                        if (tab.focused.child_hwnd) |child| {
                            _ = windows.SetFocus(child);
                        }
                    }
                }
            }
            return 0;
        },
        windows.WM_SIZE => {
            if (getApp(hwnd)) |app| {
                app.updateLayout();
            }
            return 0;
        },
        windows.WM_PAINT => {
            if (getApp(hwnd)) |app| {
                var ps: windows.PAINTSTRUCT = std.mem.zeroes(windows.PAINTSTRUCT);
                const hdc = windows.BeginPaint(hwnd, &ps);
                if (hdc) |dc| {
                    app.drawTabBar(dc);
                }
                _ = windows.EndPaint(hwnd, &ps);
            } else {
                var ps: windows.PAINTSTRUCT = std.mem.zeroes(windows.PAINTSTRUCT);
                _ = windows.BeginPaint(hwnd, &ps);
                _ = windows.EndPaint(hwnd, &ps);
            }
            return 0;
        },
        windows.WM_COMMAND => {
            if (getApp(hwnd)) |app| {
                const notify_code = windows.HIWORD(@as(isize, @intCast(wparam)));
                if (notify_code == @as(u16, @truncate(windows.EN_CHANGE))) {
                    // EN_CHANGE notification from the search EDIT control
                    app.handleSearchInput();
                } else if (notify_code == 0 or notify_code == 1) {
                    // Menu command or accelerator
                    const cmd_id = windows.LOWORD(@as(isize, @intCast(wparam)));
                    app.handleMenuCommand(@as(u32, cmd_id));
                }
            }
            return 0;
        },
        windows.WM_CONTEXTMENU => {
            if (getApp(hwnd)) |app| {
                const x = windows.GET_X_LPARAM(lparam);
                const y = windows.GET_Y_LPARAM(lparam);
                app.showContextMenu(x, y);
            }
            return 0;
        },
        windows.WM_LBUTTONDOWN => {
            if (getApp(hwnd)) |app| {
                const y = windows.GET_Y_LPARAM(lparam);
                const x = windows.GET_X_LPARAM(lparam);
                // Check if click is in tab bar
                if (app.tabs.items.len > 1 and y < TAB_BAR_HEIGHT) {
                    app.handleTabBarClick(x);
                    return 0;
                }
                // Click below the tab bar — ensure the active surface
                // gets focus so keyboard input works after alt-tab.
                if (app.tabs.items.len > app.active_tab) {
                    const tab = &app.tabs.items[app.active_tab];
                    if (tab.focused.child_hwnd) |child| {
                        _ = windows.SetFocus(child);
                    }
                }
            }
            return 0;
        },
        windows.WM_KEYDOWN,
        windows.WM_SYSKEYDOWN,
        => {
            if (getApp(hwnd)) |app| {
                // Handle Escape to close search
                if (app.search_active and wparam == @as(usize, @intCast(windows.VK_ESCAPE))) {
                    if (app.getFocusedCoreSurface()) |core| {
                        _ = core.performBindingAction(.end_search) catch {};
                    }
                    app.hideSearch();
                    return 0;
                }
                // Handle Enter in search for navigate next
                if (app.search_active and wparam == @as(usize, @intCast(windows.VK_RETURN))) {
                    if (app.getFocusedCoreSurface()) |core| {
                        const mods = getModifiers();
                        if (mods.shift) {
                            _ = core.performBindingAction(.{ .navigate_search = .previous }) catch {};
                        } else {
                            _ = core.performBindingAction(.{ .navigate_search = .next }) catch {};
                        }
                    }
                    return 0;
                }
            }
            // Let DefWindowProc handle if not consumed
            return windows.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        WM_WAKEUP => {
            if (getApp(hwnd)) |app| {
                app.core_app.tick(app) catch |err| {
                    log.err("core app tick failed: {}", .{err});
                };
            }
            return 0;
        },
        else => return windows.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

/// Translate a Windows scancode from WM_KEYDOWN/WM_KEYUP lparam into
/// an input.Key using the keycodes table.
pub fn translateScancode(lparam: windows.LPARAM) input.Key {
    const scancode: u32 = @intCast((lparam >> 16) & 0xFF);
    const extended: bool = ((lparam >> 24) & 1) == 1;
    const native: u32 = scancode | (if (extended) @as(u32, 0xe000) else @as(u32, 0));

    for (input.keycodes.entries) |entry| {
        if (entry.native == native) return entry.key;
    }
    return .unidentified;
}

/// Get current modifier key state.
pub fn getModifiers() input.Mods {
    return .{
        .shift = windows.GetKeyState(windows.VK_SHIFT) < 0,
        .ctrl = windows.GetKeyState(windows.VK_CONTROL) < 0,
        .alt = windows.GetKeyState(windows.VK_MENU) < 0,
        .super = (windows.GetKeyState(windows.VK_LWIN) < 0) or
            (windows.GetKeyState(windows.VK_RWIN) < 0),
        .caps_lock = (windows.GetKeyState(windows.VK_CAPITAL) & 1) != 0,
        .num_lock = (windows.GetKeyState(windows.VK_NUMLOCK) & 1) != 0,
        .sides = .{
            .shift = if (windows.GetKeyState(windows.VK_RSHIFT) < 0) .right else .left,
            .ctrl = if (windows.GetKeyState(windows.VK_RCONTROL) < 0) .right else .left,
            .alt = if (windows.GetKeyState(windows.VK_RMENU) < 0) .right else .left,
            .super = if (windows.GetKeyState(windows.VK_RWIN) < 0) .right else .left,
        },
    };
}
