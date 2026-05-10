// The required comptime API for any apprt.
pub const App = @import("win32/App.zig");
pub const Surface = @import("win32/Surface.zig");
pub const Tab = @import("win32/Tab.zig");
pub const resourcesDir = @import("../os/main.zig").resourcesDir;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("win32/Tab_test.zig");
}
