const test_module = @import("test.zig");

pub fn main() !void {
    try test_module.main();
}
