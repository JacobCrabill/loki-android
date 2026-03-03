const std = @import("std");
const builtin = @import("builtin");
const android = @import("android");
const rl = @import("raylib");
const loki = @import("loki");

const tcp_sync = loki.store.tcp_sync;

const is_android = builtin.abi.isAndroid();

// ---- Config (must match server) ----
const server_ip = "192.168.1.100";
const server_port: u16 = 7777;
const db_password = "changeme";
const db_name = "loki_db";

// ---- State shared between sync thread and render thread ----
const SyncStatus = enum(u8) { init, connecting, syncing, done, failed };
var g_status = std.atomic.Value(SyncStatus).init(.init);
// g_msg_buf is written before the status store(.release), read after load(.acquire).
var g_msg_buf = std.mem.zeroes([256:0]u8);

fn writeMsg(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(g_msg_buf[0..255], fmt, args) catch g_msg_buf[0..0];
    g_msg_buf[s.len] = 0;
}

// ---- Background sync ----

fn doSync(allocator: std.mem.Allocator, base_dir: std.fs.Dir) !tcp_sync.SyncResult {
    var db = loki.Database.open(allocator, base_dir, db_name, db_password) catch |err| blk: {
        if (err != error.FileNotFound) return err;
        break :blk try loki.Database.create(allocator, base_dir, db_name, db_password);
    };
    defer db.deinit();

    g_status.store(.connecting, .release);

    const addr = try std.net.Address.parseIp(server_ip, server_port);
    const stream = try std.net.tcpConnectToAddress(addr);
    defer stream.close();

    g_status.store(.syncing, .release);

    var r = stream.reader(&.{});
    var w = stream.writer(&.{});
    var conflicts: std.ArrayList(tcp_sync.ConflictEntry) = .{};
    defer conflicts.deinit(allocator);

    return tcp_sync.syncSession(
        allocator,
        &db,
        r.interface(),
        &w.interface,
        .client,
        &conflicts,
    );
}

fn syncThread() void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // On Android, write to the app's internal files directory.
    // On desktop, use the current working directory.
    var base_dir: std.fs.Dir = if (is_android) blk: {
        break :blk std.fs.openDirAbsolute("/data/data/com.zig.loki/files", .{}) catch |err| {
            writeMsg("{s}", .{@errorName(err)});
            g_status.store(.failed, .release);
            return;
        };
    } else std.fs.cwd();
    defer if (is_android) base_dir.close();

    const result = doSync(allocator, base_dir) catch |err| {
        writeMsg("{s}", .{@errorName(err)});
        g_status.store(.failed, .release);
        return;
    };

    writeMsg("pushed:{d} pulled:{d} new:{d} conflicts:{d}", .{
        result.objects_pushed,
        result.objects_pulled,
        result.new_to_local,
        result.conflicts,
    });
    g_status.store(.done, .release);
}

// ---- App entry point ----

pub fn main() !void {
    rl.initWindow(800, 450, "Loki Sync");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    const thread = try std.Thread.spawn(.{}, syncThread, .{});
    thread.detach();

    while (!rl.windowShouldClose()) {
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(.black);
        rl.drawText("Loki TCP Sync", 10, 10, 24, .white);
        rl.drawText("Server: " ++ server_ip, 10, 44, 18, .light_gray);

        switch (g_status.load(.acquire)) {
            .init => rl.drawText("Initializing...", 10, 200, 20, .yellow),
            .connecting => rl.drawText("Connecting...", 10, 200, 20, .yellow),
            .syncing => rl.drawText("Syncing...", 10, 200, 20, .yellow),
            .done => {
                rl.drawText("Sync complete!", 10, 200, 20, .green);
                rl.drawText(&g_msg_buf, 10, 228, 18, .green);
            },
            .failed => {
                rl.drawText("Sync failed:", 10, 200, 20, .red);
                rl.drawText(&g_msg_buf, 10, 228, 18, .red);
            },
        }
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
