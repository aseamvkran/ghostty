/// Tab.zig - Manages a tab containing a split tree of terminal surfaces.
/// Each tab has a root SplitNode which is either a single surface (leaf)
/// or a binary split containing two child nodes.
const Tab = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const Surface = @import("Surface.zig");
const windows = @import("../../os/main.zig").win32;

const log = std.log.scoped(.win32_tab);

/// A node in the binary split tree.
pub const SplitNode = union(enum) {
    /// A leaf node containing a terminal surface.
    leaf: *Surface,
    /// A split containing two children.
    split: Split,

    pub const Split = struct {
        /// Horizontal = left|right, Vertical = top|bottom
        direction: Direction,
        /// Ratio of first child (0.0 to 1.0)
        ratio: f32 = 0.5,
        /// First child (left or top)
        first: *SplitNode,
        /// Second child (right or bottom)
        second: *SplitNode,
    };

    pub const Direction = enum {
        horizontal,
        vertical,
    };
};

/// The root of the split tree for this tab.
root: *SplitNode,

/// The currently focused surface within this tab.
focused: *Surface,

/// Tab title (displayed in the tab bar).
title: []const u8 = "Terminal",

/// Allocator for managing split nodes.
alloc: Allocator,

/// Initialize a new tab with a single surface as its root.
pub fn init(alloc: Allocator, surface: *Surface) !Tab {
    const node = try alloc.create(SplitNode);
    node.* = .{ .leaf = surface };
    return .{
        .root = node,
        .focused = surface,
        .alloc = alloc,
    };
}

/// Deinitialize the tab, destroying all split nodes (but NOT surfaces -
/// those are managed by App).
pub fn deinit(self: *Tab) void {
    freeNode(self.alloc, self.root);
}

fn freeNode(alloc: Allocator, node: *SplitNode) void {
    switch (node.*) {
        .leaf => {},
        .split => |s| {
            freeNode(alloc, s.first);
            freeNode(alloc, s.second);
        },
    }
    alloc.destroy(node);
}

/// Split the focused surface in the given direction, returning the new surface's
/// node. The caller is responsible for creating and initializing the new Surface.
pub fn splitFocused(self: *Tab, new_surface: *Surface, direction: SplitNode.Direction) !void {
    // Find the node containing the focused surface
    const target_node = findNode(self.root, self.focused) orelse return error.NodeNotFound;

    // Create two new leaf nodes
    const first_node = try self.alloc.create(SplitNode);
    first_node.* = .{ .leaf = self.focused };

    const second_node = try self.alloc.create(SplitNode);
    second_node.* = .{ .leaf = new_surface };

    // Replace the target node with a split
    target_node.* = .{ .split = .{
        .direction = direction,
        .ratio = 0.5,
        .first = first_node,
        .second = second_node,
    } };

    // Focus the new surface
    self.focused = new_surface;
}

/// Remove a surface from the split tree. Returns true if the tab still has surfaces.
pub fn removeSurface(self: *Tab, surface: *Surface) bool {
    if (self.root.* == .leaf and self.root.leaf == surface) {
        // Last surface in tab
        return false;
    }
    removeFromTree(self.alloc, self.root, surface);

    // Update focus if we removed the focused surface
    if (self.focused == surface) {
        self.focused = firstLeaf(self.root);
    }
    return true;
}

fn removeFromTree(alloc: Allocator, node: *SplitNode, surface: *Surface) void {
    switch (node.*) {
        .leaf => return, // handled by parent
        .split => |s| {
            // Check if first child is the target leaf
            if (s.first.* == .leaf and s.first.leaf == surface) {
                // Replace this split node with the second child
                const second = s.second;
                alloc.destroy(s.first);
                node.* = second.*;
                alloc.destroy(second);
                return;
            }
            // Check if second child is the target leaf
            if (s.second.* == .leaf and s.second.leaf == surface) {
                // Replace this split node with the first child
                const first = s.first;
                alloc.destroy(s.second);
                node.* = first.*;
                alloc.destroy(first);
                return;
            }
            // Recurse
            removeFromTree(alloc, s.first, surface);
            removeFromTree(alloc, s.second, surface);
        },
    }
}

/// Find the SplitNode that contains the given surface as a leaf.
fn findNode(node: *SplitNode, surface: *Surface) ?*SplitNode {
    switch (node.*) {
        .leaf => |s| {
            if (s == surface) return node;
            return null;
        },
        .split => |s| {
            if (findNode(s.first, surface)) |found| return found;
            if (findNode(s.second, surface)) |found| return found;
            return null;
        },
    }
}

/// Get the first leaf surface in the tree (leftmost/topmost).
fn firstLeaf(node: *SplitNode) *Surface {
    switch (node.*) {
        .leaf => |s| return s,
        .split => |s| return firstLeaf(s.first),
    }
}

/// Layout all surfaces within the given rectangle.
/// This recursively assigns positions and sizes to each surface's child HWND.
pub fn layout(self: *Tab, rect: windows.RECT) void {
    layoutNode(self.root, rect);
}

fn layoutNode(node: *SplitNode, rect: windows.RECT) void {
    switch (node.*) {
        .leaf => |surface| {
            const w = rect.right - rect.left;
            const h = rect.bottom - rect.top;
            if (w > 0 and h > 0) {
                if (surface.child_hwnd) |child| {
                    _ = windows.MoveWindow(child, rect.left, rect.top, w, h, 1);
                    surface.width = @intCast(w);
                    surface.height = @intCast(h);
                    if (surface.core_surface) |cs| {
                        cs.sizeCallback(.{
                            .width = surface.width,
                            .height = surface.height,
                        }) catch {};
                    }
                }
            }
        },
        .split => |s| {
            const total_w = rect.right - rect.left;
            const total_h = rect.bottom - rect.top;
            const divider: i32 = 4; // divider thickness in pixels

            var first_rect = rect;
            var second_rect = rect;

            switch (s.direction) {
                .horizontal => {
                    const split_pos = rect.left + @as(i32, @intFromFloat(@as(f32, @floatFromInt(total_w)) * s.ratio));
                    first_rect.right = split_pos - @divTrunc(divider, 2);
                    second_rect.left = split_pos + @divTrunc(divider, 2);
                },
                .vertical => {
                    const split_pos = rect.top + @as(i32, @intFromFloat(@as(f32, @floatFromInt(total_h)) * s.ratio));
                    first_rect.bottom = split_pos - @divTrunc(divider, 2);
                    second_rect.top = split_pos + @divTrunc(divider, 2);
                },
            }

            layoutNode(s.first, first_rect);
            layoutNode(s.second, second_rect);
        },
    }
}
