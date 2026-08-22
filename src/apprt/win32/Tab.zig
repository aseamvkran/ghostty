/// Tab.zig - Manages a tab containing a split tree of terminal surfaces.
/// Each tab has a root SplitNode which is either a single surface (leaf)
/// or a binary split containing two child nodes.
const Tab = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Surface = @import("Surface.zig");
const windows = @import("../../os/main.zig").win32;

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
        /// Area this split covers, recorded by layout(). Divider hit-testing
        /// needs it, and recomputing the geometry from the root for every
        /// mouse move would just be the same walk twice.
        rect: windows.RECT = .{},
    };

    pub const Direction = enum {
        horizontal,
        vertical,
    };
};

/// Divider thickness in pixels. Also the grab area for drag-resizing.
pub const divider: i32 = 4;

/// The root of the split tree for this tab.
root: *SplitNode,

/// The currently focused surface within this tab.
focused: *Surface,

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
                    // MoveWindow sends WM_SIZE, and surfaceWndProc's WM_SIZE
                    // handler is the single place that records the new size
                    // and notifies the core. Don't do it twice: during a live
                    // drag-resize that doubles the resize traffic per pane.
                    _ = windows.MoveWindow(child, rect.left, rect.top, w, h, 1);
                }
            }
        },
        .split => {
            const s = &node.split;
            s.rect = rect;

            const pos = dividerPos(s.*);
            const half = @divTrunc(divider, 2);

            var first_rect = rect;
            var second_rect = rect;
            switch (s.direction) {
                .horizontal => {
                    first_rect.right = pos - half;
                    second_rect.left = pos + half;
                },
                .vertical => {
                    first_rect.bottom = pos - half;
                    second_rect.top = pos + half;
                },
            }

            layoutNode(s.first, first_rect);
            layoutNode(s.second, second_rect);
        },
    }
}

/// Pixel position of a split's divider along its axis. Single source of truth
/// for both layout and hit-testing, so a drag can't drift from what's drawn.
fn dividerPos(s: SplitNode.Split) i32 {
    const span, const origin = switch (s.direction) {
        .horizontal => .{ s.rect.right - s.rect.left, s.rect.left },
        .vertical => .{ s.rect.bottom - s.rect.top, s.rect.top },
    };
    return origin + @as(i32, @intFromFloat(@as(f32, @floatFromInt(span)) * s.ratio));
}

/// The split whose divider sits under (x, y), or null. Coordinates are in the
/// parent window's client space, the same space layout() was given.
pub fn dividerAt(self: *Tab, x: i32, y: i32) ?*SplitNode {
    return dividerAtNode(self.root, x, y);
}

fn dividerAtNode(node: *SplitNode, x: i32, y: i32) ?*SplitNode {
    const s = switch (node.*) {
        .leaf => return null,
        .split => |s| s,
    };

    // Descend first so the innermost divider under the cursor wins.
    if (dividerAtNode(s.first, x, y)) |found| return found;
    if (dividerAtNode(s.second, x, y)) |found| return found;

    if (x < s.rect.left or x > s.rect.right or
        y < s.rect.top or y > s.rect.bottom) return null;

    const pos = dividerPos(s);
    const half = @divTrunc(divider, 2);
    return switch (s.direction) {
        .horizontal => if (x >= pos - half and x <= pos + half) node else null,
        .vertical => if (y >= pos - half and y <= pos + half) node else null,
    };
}

/// Drag a divider to (x, y). Clamped so neither pane can be collapsed to
/// nothing, which would leave a surface with no way to grab it back.
pub fn moveDivider(node: *SplitNode, x: i32, y: i32) void {
    const s = &node.split;
    const span, const offset = switch (s.direction) {
        .horizontal => .{ s.rect.right - s.rect.left, x - s.rect.left },
        .vertical => .{ s.rect.bottom - s.rect.top, y - s.rect.top },
    };
    if (span <= 0) return;

    const min_ratio = 0.05;
    s.ratio = std.math.clamp(
        @as(f32, @floatFromInt(offset)) / @as(f32, @floatFromInt(span)),
        min_ratio,
        1.0 - min_ratio,
    );
}

/// Reset all split ratios to 0.5 (equalize).
pub fn equalize(self: *Tab) void {
    equalizeNode(self.root);
}

fn equalizeNode(node: *SplitNode) void {
    switch (node.*) {
        .leaf => {},
        .split => |*s| {
            s.ratio = 0.5;
            equalizeNode(s.first);
            equalizeNode(s.second);
        },
    }
}
