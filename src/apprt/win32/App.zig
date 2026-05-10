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

/// Context menu command IDs.
const CMD_COPY: u32 = 1001;
const CMD_PASTE: u32 = 1002;
const CMD_NEW_TAB: u32 = 1003;
const CMD_SPLIT_RIGHT: u32 = 1004;
const CMD_SPLIT_DOWN: u32 = 1005;
const CMD_CLOSE_TAB: u32 = 1006;
const CMD_SEARCH: u32 = 1007;

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

/// Font for the tab bar.
tab_font: ?windows.HFONT = null,

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
        .new_split => {
            self.createNewSplit(value) catch |err| {
                log.err("failed to create new split: {}", .{err});
                return false;
            };
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
    self.updateLayout();
}

fn hideSearch(self: *App) void {
    self.search_active = false;
    if (self.search_hwnd) |search| {
        _ = windows.ShowWindow(search, 0); // SW_HIDE = 0
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
        CMD_SEARCH => {
            if (self.getFocusedCoreSurface()) |core_sfc| {
                _ = core_sfc.performBindingAction(.start_search) catch {};
            }
        },
        CMD_NEW_TAB => {
            self.createNewTab() catch {};
        },
        CMD_SPLIT_RIGHT => {
            self.createNewSplit(.right) catch {};
        },
        CMD_SPLIT_DOWN => {
            self.createNewSplit(.down) catch {};
        },
        CMD_CLOSE_TAB => {
            self.closeTab(.this) catch {};
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
        if (self.search_hwnd) |search| {
            _ = windows.MoveWindow(search, 0, content_top, total_w, SEARCH_BAR_HEIGHT, 1);
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
                // EN_CHANGE notification from the search EDIT control
                const notify_code = windows.HIWORD(@as(isize, @intCast(wparam)));
                if (notify_code == @as(u16, @truncate(windows.EN_CHANGE))) {
                    app.handleSearchInput();
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
