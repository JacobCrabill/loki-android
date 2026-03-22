const std = @import("std");
const builtin = @import("builtin");
const android = @import("android");
const rl = @import("raylib");
const App = @import("App.zig");
const font = @import("font.zig");

const is_android = builtin.abi.isAndroid();

pub fn main() !void {
    if (comptime is_android) {
        rl.initWindow(1024, 1980, "Loki");
    } else {
        rl.initWindow(480, 854, "Loki");
    }
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    if (comptime !is_android) {
        rl.setWindowState(.{ .window_resizable = true });
        rl.setWindowMinSize(400, 600);
    }

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

pub const panic = if (is_android)
    android.panic
else
    std.debug.FullPanic(std.debug.defaultPanic);

pub const std_options: std.Options = if (is_android)
    .{ .logFn = android.logFn }
else
    .{};

comptime {
    if (is_android) {
        @export(&androidMain, .{ .name = "main" });
    }
}

fn androidMain() callconv(.c) c_int {
    return std.start.callMain();
}
