const std = @import("std");
const builtin = @import("builtin");
const android = @import("android");
const rl = @import("raylib");
const App = @import("App.zig");
const font = @import("font.zig");

pub fn main() !void {
    rl.initWindow(1024, 1980, "Loki");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    font.load();
    defer font.unload();

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();

    var app = App.init(gpa.allocator());
    defer app.deinit();

    while (!rl.windowShouldClose()) {
        app.update();
    }
}

// ---- Android plumbing ----

pub const panic = if (builtin.abi.isAndroid())
    android.panic
else
    std.debug.FullPanic(std.debug.defaultPanic);

pub const std_options: std.Options = if (builtin.abi.isAndroid())
    .{ .logFn = android.logFn }
else
    .{};

comptime {
    if (builtin.abi.isAndroid()) {
        @export(&androidMain, .{ .name = "main" });
    }
}

fn androidMain() callconv(.c) c_int {
    return std.start.callMain();
}
