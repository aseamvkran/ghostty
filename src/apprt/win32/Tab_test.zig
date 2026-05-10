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
