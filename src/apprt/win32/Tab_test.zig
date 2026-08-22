/// Tests for the Win32 apprt modules.
/// Tests the pure logic (split tree management, layout calculations)
/// that doesn't require a running Win32 environment.
const std = @import("std");
const testing = std.testing;
const Tab = @import("Tab.zig");
const Surface = @import("Surface.zig");

// Real (but never initialized) Surface values rather than fabricated pointers.
// Every field defaults, and a null child_hwnd makes layout() skip the Win32
// calls, so the split tree can be exercised end to end — including layout,
// which fake pointers could not survive being dereferenced by.
var mock_surfaces = [_]Surface{.{}} ** 100;

fn mockSurface(id: usize) *Surface {
    return &mock_surfaces[id];
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

test "Tab.equalize resets nested ratios" {
    const alloc = testing.allocator;
    var tab = try Tab.init(alloc, mockSurface(1));
    defer tab.deinit();

    // Build: [1 | [2 / 3]]
    try tab.splitFocused(mockSurface(2), .horizontal);
    try tab.splitFocused(mockSurface(3), .vertical);

    tab.root.split.ratio = 0.3;
    tab.root.split.second.split.ratio = 0.8;

    tab.equalize();

    try testing.expectEqual(tab.root.split.ratio, 0.5);
    try testing.expectEqual(tab.root.split.second.split.ratio, 0.5);
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

test "Tab.dividerAt and moveDivider" {
    const alloc = testing.allocator;
    var tab = try Tab.init(alloc, mockSurface(1));
    defer tab.deinit();

    try tab.splitFocused(mockSurface(2), .horizontal);

    // layout() records the rect that hit-testing needs. Only the split node's
    // rect is touched here; leaves just get MoveWindow'd, and mock surfaces
    // have a null child_hwnd so that's skipped.
    tab.layout(.{ .left = 0, .top = 0, .right = 1000, .bottom = 500 });

    // Divider of a 0.5 horizontal split across 1000px sits at x=500.
    try testing.expect(tab.dividerAt(500, 250) != null);
    // Well clear of it, and outside the split's rect entirely.
    try testing.expect(tab.dividerAt(200, 250) == null);
    try testing.expect(tab.dividerAt(500, 900) == null);

    const node = tab.dividerAt(500, 250).?;
    Tab.moveDivider(node, 250, 250);
    try testing.expectApproxEqAbs(@as(f32, 0.25), node.split.ratio, 0.001);

    // Dragging past either edge clamps instead of collapsing a pane to zero,
    // which would leave no divider left to grab.
    Tab.moveDivider(node, -5000, 250);
    try testing.expect(node.split.ratio > 0.0);
    Tab.moveDivider(node, 5000, 250);
    try testing.expect(node.split.ratio < 1.0);
}

test "Tab.dividerAt picks the innermost divider" {
    const alloc = testing.allocator;
    var tab = try Tab.init(alloc, mockSurface(1));
    defer tab.deinit();

    // [1 | [2 / 3]] — outer divider at x=500, inner one at y=250 in the
    // right half, so (752, 250) is on the inner divider only.
    try tab.splitFocused(mockSurface(2), .horizontal);
    try tab.splitFocused(mockSurface(3), .vertical);
    tab.layout(.{ .left = 0, .top = 0, .right = 1000, .bottom = 500 });

    const inner = tab.dividerAt(752, 250).?;
    try testing.expectEqual(Tab.SplitNode.Direction.vertical, inner.split.direction);
    try testing.expectEqual(tab.root.split.second, inner);

    const outer = tab.dividerAt(500, 100).?;
    try testing.expectEqual(tab.root, outer);
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

test "App.formatSearchCount" {
    // The real function from App.zig, not a copy of it: the previous version
    // of this test reimplemented the formatting and then tested the
    // reimplementation, so it could not catch a change in App.
    const formatSearchCount = @import("App.zig").formatSearchCount;
    var buf: [32]u8 = undefined;

    // selected is 0-based, displayed 1-based.
    try testing.expectEqualStrings("3/42", formatSearchCount(&buf, 42, 2));
    try testing.expectEqualStrings("1/10", formatSearchCount(&buf, 10, 0));

    // A total with nothing selected yet.
    try testing.expectEqualStrings("0/77", formatSearchCount(&buf, 77, null));

    // No search running at all.
    try testing.expectEqualStrings("", formatSearchCount(&buf, null, null));
}
