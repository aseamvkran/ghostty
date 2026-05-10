/// Tests for the Win32 apprt modules.
/// Tests the pure logic (split tree management, layout calculations)
/// that doesn't require a running Win32 environment.
const std = @import("std");
const testing = std.testing;
const Tab = @import("Tab.zig");
const Surface = @import("Surface.zig");

// We can't create real Surface objects (they need HWNDs), but we can
// test the Tab split tree logic using mock Surface pointers.
// The Tab logic only stores/compares pointers, never dereferences them
// during tree operations (except layout which we skip).

fn mockSurface(id: usize) *Surface {
    // Use properly aligned addresses to satisfy Zig's safety checks
    return @ptrFromInt(@alignOf(Surface) * (id + 1));
}

test "Tab.init creates a single leaf" {
    const alloc = testing.allocator;
    var tab = try Tab.init(alloc, mockSurface(1));
    defer tab.deinit();

    try testing.expectEqual(tab.focused, mockSurface(1));
    try testing.expect(tab.root.* == .leaf);
    try testing.expectEqual(tab.root.leaf, mockSurface(1));
}

test "Tab.splitFocused creates a horizontal split" {
    const alloc = testing.allocator;
    var tab = try Tab.init(alloc, mockSurface(1));
    defer tab.deinit();

    try tab.splitFocused(mockSurface(2), .horizontal);

    // Root should now be a split
    try testing.expect(tab.root.* == .split);
    const split = tab.root.split;
    try testing.expectEqual(split.direction, .horizontal);
    try testing.expectEqual(split.ratio, 0.5);

    // First child should be the original surface
    try testing.expect(split.first.* == .leaf);
    try testing.expectEqual(split.first.leaf, mockSurface(1));

    // Second child should be the new surface
    try testing.expect(split.second.* == .leaf);
    try testing.expectEqual(split.second.leaf, mockSurface(2));

    // Focus should move to the new surface
    try testing.expectEqual(tab.focused, mockSurface(2));
}

test "Tab.splitFocused creates a vertical split" {
    const alloc = testing.allocator;
    var tab = try Tab.init(alloc, mockSurface(1));
    defer tab.deinit();

    try tab.splitFocused(mockSurface(2), .vertical);

    try testing.expect(tab.root.* == .split);
    try testing.expectEqual(tab.root.split.direction, .vertical);
}

test "Tab.splitFocused nested split" {
    const alloc = testing.allocator;
    var tab = try Tab.init(alloc, mockSurface(1));
    defer tab.deinit();

    // Split horizontally: [1 | 2], focus on 2
    try tab.splitFocused(mockSurface(2), .horizontal);
    try testing.expectEqual(tab.focused, mockSurface(2));

    // Split the focused (2) vertically: [1 | [2 / 3]]
    try tab.splitFocused(mockSurface(3), .vertical);
    try testing.expectEqual(tab.focused, mockSurface(3));

    // Root is horizontal split
    try testing.expect(tab.root.* == .split);
    try testing.expectEqual(tab.root.split.direction, .horizontal);

    // First child is still surface 1
    try testing.expectEqual(tab.root.split.first.leaf, mockSurface(1));

    // Second child is a vertical split of [2, 3]
    const inner = tab.root.split.second;
    try testing.expect(inner.* == .split);
    try testing.expectEqual(inner.split.direction, .vertical);
    try testing.expectEqual(inner.split.first.leaf, mockSurface(2));
    try testing.expectEqual(inner.split.second.leaf, mockSurface(3));
}

test "Tab.removeSurface from split returns true" {
    const alloc = testing.allocator;
    var tab = try Tab.init(alloc, mockSurface(1));
    defer tab.deinit();

    try tab.splitFocused(mockSurface(2), .horizontal);

    // Remove surface 2
    const still_alive = tab.removeSurface(mockSurface(2));
    try testing.expect(still_alive);

    // Root should collapse back to a leaf with surface 1
    try testing.expect(tab.root.* == .leaf);
    try testing.expectEqual(tab.root.leaf, mockSurface(1));
    try testing.expectEqual(tab.focused, mockSurface(1));
}

test "Tab.removeSurface last surface returns false" {
    const alloc = testing.allocator;
    var tab = try Tab.init(alloc, mockSurface(1));
    defer tab.deinit();

    const still_alive = tab.removeSurface(mockSurface(1));
    try testing.expect(!still_alive);
}

test "Tab.removeSurface from nested split" {
    const alloc = testing.allocator;
    var tab = try Tab.init(alloc, mockSurface(1));
    defer tab.deinit();

    try tab.splitFocused(mockSurface(2), .horizontal);
    try tab.splitFocused(mockSurface(3), .vertical);

    // Tree is: [1 | [2 / 3]]
    // Remove surface 3, tree should become: [1 | 2]
    const still_alive = tab.removeSurface(mockSurface(3));
    try testing.expect(still_alive);

    try testing.expect(tab.root.* == .split);
    try testing.expectEqual(tab.root.split.first.leaf, mockSurface(1));
    try testing.expectEqual(tab.root.split.second.leaf, mockSurface(2));
}

test "Tab.removeSurface updates focus" {
    const alloc = testing.allocator;
    var tab = try Tab.init(alloc, mockSurface(1));
    defer tab.deinit();

    try tab.splitFocused(mockSurface(2), .horizontal);
    // Focus is on 2
    try testing.expectEqual(tab.focused, mockSurface(2));

    // Remove the focused surface
    _ = tab.removeSurface(mockSurface(2));
    // Focus should move to the remaining surface
    try testing.expectEqual(tab.focused, mockSurface(1));
}

test "SplitNode.Direction values" {
    try testing.expectEqual(@intFromEnum(Tab.SplitNode.Direction.horizontal), 0);
    try testing.expectEqual(@intFromEnum(Tab.SplitNode.Direction.vertical), 1);
}

test "Tab.equalize resets ratios to 0.5" {
    const alloc = testing.allocator;
    var tab = try Tab.init(alloc, mockSurface(1));
    defer tab.deinit();

    try tab.splitFocused(mockSurface(2), .horizontal);

    // Manually change the ratio
    tab.root.split.ratio = 0.7;
    try testing.expectEqual(tab.root.split.ratio, 0.7);

    // Equalize should reset to 0.5
    tab.equalize();
    try testing.expectEqual(tab.root.split.ratio, 0.5);
}

test "Tab.equalize resets nested ratios" {
    const alloc = testing.allocator;
    var tab = try Tab.init(alloc, mockSurface(1));
    defer tab.deinit();

    // Build: [1 | [2 / 3]]
    try tab.splitFocused(mockSurface(2), .horizontal);
    try tab.splitFocused(mockSurface(3), .vertical);

    // Set non-default ratios
    tab.root.split.ratio = 0.3;
    tab.root.split.second.split.ratio = 0.8;

    tab.equalize();

    try testing.expectEqual(tab.root.split.ratio, 0.5);
    try testing.expectEqual(tab.root.split.second.split.ratio, 0.5);
}

test "Tab.equalize on leaf is no-op" {
    const alloc = testing.allocator;
    var tab = try Tab.init(alloc, mockSurface(1));
    defer tab.deinit();

    // Should not crash
    tab.equalize();
    try testing.expect(tab.root.* == .leaf);
}

test "Tab.splitFocused alternating directions" {
    const alloc = testing.allocator;
    var tab = try Tab.init(alloc, mockSurface(1));
    defer tab.deinit();

    // Split H: [1 | 2]
    try tab.splitFocused(mockSurface(2), .horizontal);
    // Focus on 2, split V: [1 | [2 / 3]]
    try tab.splitFocused(mockSurface(3), .vertical);
    // Focus on 3, split H: [1 | [2 / [3 | 4]]]
    try tab.splitFocused(mockSurface(4), .horizontal);

    try testing.expectEqual(tab.focused, mockSurface(4));
    try testing.expect(tab.root.* == .split);
    try testing.expectEqual(tab.root.split.direction, .horizontal);

    const inner1 = tab.root.split.second;
    try testing.expect(inner1.* == .split);
    try testing.expectEqual(inner1.split.direction, .vertical);

    const inner2 = inner1.split.second;
    try testing.expect(inner2.* == .split);
    try testing.expectEqual(inner2.split.direction, .horizontal);
    try testing.expectEqual(inner2.split.first.leaf, mockSurface(3));
    try testing.expectEqual(inner2.split.second.leaf, mockSurface(4));
}

test "Tab.removeSurface from deeply nested tree" {
    const alloc = testing.allocator;
    var tab = try Tab.init(alloc, mockSurface(1));
    defer tab.deinit();

    // Build: [1 | [2 / [3 | 4]]]
    try tab.splitFocused(mockSurface(2), .horizontal);
    try tab.splitFocused(mockSurface(3), .vertical);
    try tab.splitFocused(mockSurface(4), .horizontal);

    // Remove 4: should collapse to [1 | [2 / 3]]
    _ = tab.removeSurface(mockSurface(4));
    try testing.expect(tab.root.split.second.split.second.* == .leaf);
    try testing.expectEqual(tab.root.split.second.split.second.leaf, mockSurface(3));

    // Remove 2: should collapse to [1 | 3]
    _ = tab.removeSurface(mockSurface(2));
    try testing.expect(tab.root.* == .split);
    try testing.expectEqual(tab.root.split.first.leaf, mockSurface(1));
    try testing.expectEqual(tab.root.split.second.leaf, mockSurface(3));

    // Remove 3: should collapse to just 1
    const alive = tab.removeSurface(mockSurface(3));
    try testing.expect(alive);
    try testing.expect(tab.root.* == .leaf);
    try testing.expectEqual(tab.root.leaf, mockSurface(1));
}

test "Tab.removeSurface first child of split" {
    const alloc = testing.allocator;
    var tab = try Tab.init(alloc, mockSurface(1));
    defer tab.deinit();

    try tab.splitFocused(mockSurface(2), .horizontal);

    // Focus is on 2, remove the first surface (1)
    tab.focused = mockSurface(1);
    _ = tab.removeSurface(mockSurface(1));

    // Root should be leaf with surface 2
    try testing.expect(tab.root.* == .leaf);
    try testing.expectEqual(tab.root.leaf, mockSurface(2));
    try testing.expectEqual(tab.focused, mockSurface(2));
}

test "Tab.equalize deeply nested" {
    const alloc = testing.allocator;
    var tab = try Tab.init(alloc, mockSurface(1));
    defer tab.deinit();

    // Build 4-deep tree
    try tab.splitFocused(mockSurface(2), .horizontal);
    try tab.splitFocused(mockSurface(3), .vertical);
    try tab.splitFocused(mockSurface(4), .horizontal);

    // Set all ratios to non-default
    tab.root.split.ratio = 0.2;
    tab.root.split.second.split.ratio = 0.9;
    tab.root.split.second.split.second.split.ratio = 0.1;

    tab.equalize();

    try testing.expectEqual(tab.root.split.ratio, 0.5);
    try testing.expectEqual(tab.root.split.second.split.ratio, 0.5);
    try testing.expectEqual(tab.root.split.second.split.second.split.ratio, 0.5);
}

test "Tab.splitFocused error on missing node" {
    const alloc = testing.allocator;
    var tab = try Tab.init(alloc, mockSurface(1));
    defer tab.deinit();

    // Set focused to a surface not in the tree
    tab.focused = mockSurface(99);

    // Should fail with NodeNotFound
    try testing.expectError(error.NodeNotFound, tab.splitFocused(mockSurface(2), .horizontal));

    // Tab should remain unchanged
    try testing.expect(tab.root.* == .leaf);
    try testing.expectEqual(tab.root.leaf, mockSurface(1));
}

// -----------------------------------------------------------------------
// Search count formatting tests (pure logic, no HWND needed)
// -----------------------------------------------------------------------

/// Format search count text the same way App.updateSearchCount does.
fn formatSearchCount(
    buf: []u8,
    total: ?usize,
    selected: ?usize,
) []const u8 {
    if (total) |t| {
        if (selected) |s| {
            return std.fmt.bufPrint(buf, "{d}/{d}", .{ s + 1, t }) catch "";
        } else {
            return std.fmt.bufPrint(buf, "0/{d}", .{t}) catch "";
        }
    }
    return "";
}

test "search count format with total and selected" {
    var buf: [32]u8 = undefined;
    const result = formatSearchCount(&buf, 42, 2);
    try testing.expectEqualStrings("3/42", result);
}

test "search count format with total but no selected" {
    var buf: [32]u8 = undefined;
    const result = formatSearchCount(&buf, 77, null);
    try testing.expectEqualStrings("0/77", result);
}

test "search count format with no total" {
    var buf: [32]u8 = undefined;
    const result = formatSearchCount(&buf, null, null);
    try testing.expectEqualStrings("", result);
}

test "search count format first match" {
    var buf: [32]u8 = undefined;
    const result = formatSearchCount(&buf, 10, 0);
    try testing.expectEqualStrings("1/10", result);
}

test "search count format last match" {
    var buf: [32]u8 = undefined;
    const result = formatSearchCount(&buf, 5, 4);
    try testing.expectEqualStrings("5/5", result);
}

test "search count format single match" {
    var buf: [32]u8 = undefined;
    const result = formatSearchCount(&buf, 1, 0);
    try testing.expectEqualStrings("1/1", result);
}

test "search count format zero total" {
    var buf: [32]u8 = undefined;
    const result = formatSearchCount(&buf, 0, null);
    try testing.expectEqualStrings("0/0", result);
}

test "search count format large numbers" {
    var buf: [32]u8 = undefined;
    const result = formatSearchCount(&buf, 99999, 12345);
    try testing.expectEqualStrings("12346/99999", result);
}
