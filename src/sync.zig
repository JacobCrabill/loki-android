const std = @import("std");
const builtin = @import("builtin");
const loki = @import("loki");
const fs = @import("fs.zig");

const tcp_sync = loki.sync.net;
const is_android = builtin.abi.isAndroid();

pub const server_port: u16 = 7777;
pub const connect_timeout_ms: i32 = 10_000;

pub const SyncStatus = enum(u8) { connecting, syncing, done, failed };

pub var g_status = std.atomic.Value(SyncStatus).init(.connecting);
pub var g_msg_buf = std.mem.zeroes([256:0]u8);
pub var g_conflict_count: usize = 0; // written by syncThread before setting .done
pub var g_ip: [128]u8 = undefined;
pub var g_ip_len: usize = 0;
pub var g_pw: [128]u8 = undefined;
pub var g_pw_len: usize = 0;

pub fn writeMsg(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(g_msg_buf[0..255], fmt, args) catch g_msg_buf[0..0];
    g_msg_buf[s.len] = 0;
}

/// Non-blocking connect with a `connect_timeout_ms` deadline.
fn tcpConnectTimeout(addr: std.net.Address) !std.net.Stream {
    const sockfd = try std.posix.socket(
        addr.any.family,
        std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK,
        std.posix.IPPROTO.TCP,
    );
    errdefer std.posix.close(sockfd);

    std.posix.connect(sockfd, &addr.any, addr.getOsSockLen()) catch |err| switch (err) {
        error.WouldBlock => {}, // EINPROGRESS — expected for non-blocking connect
        else => return err,
    };

    var pfd = [1]std.posix.pollfd{.{
        .fd = sockfd,
        .events = std.posix.POLL.OUT,
        .revents = 0,
    }};
    const n = try std.posix.poll(&pfd, connect_timeout_ms);
    if (n == 0) return error.ConnectionTimedOut;

    if (pfd[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP) != 0)
        return error.ConnectionRefused;

    // Restore blocking mode (clear O_NONBLOCK = 0x800).
    const flags: usize = @intCast(try std.posix.fcntl(sockfd, std.posix.F.GETFL, 0));
    _ = try std.posix.fcntl(sockfd, std.posix.F.SETFL, flags & ~@as(usize, 0x800));

    return .{ .handle = sockfd };
}

fn doSync(allocator: std.mem.Allocator, base_dir: std.fs.Dir) !void {
    const ip = g_ip[0..g_ip_len];
    const pw = g_pw[0..g_pw_len];

    const addr = try std.net.Address.parseIp(ip, server_port);
    const stream = try tcpConnectTimeout(addr);
    defer stream.close();

    g_status.store(.syncing, .release);

    var r = stream.reader(&.{});
    var w = stream.writer(&.{});
    const ri = r.interface();
    const wi = &w.interface;

    if (!fs.dbDirExists()) {
        try wi.writeAll(&[_]u8{tcp_sync.protocol_fetch});
        try tcp_sync.fetchClient(allocator, pw, base_dir, fs.db_name, ri, wi);
        writeMsg("Fetch complete.", .{});
    } else {
        try wi.writeAll(&[_]u8{tcp_sync.protocol_sync});
        var db = try loki.Database.open(allocator, base_dir, fs.db_name, pw);
        defer db.deinit();
        var conflicts: std.ArrayList(loki.model.merge.ConflictEntry) = .{};
        defer conflicts.deinit(allocator);
        const result = try tcp_sync.syncSession(allocator, &db, ri, wi, .client, &conflicts);
        g_conflict_count = result.conflicts;
        writeMsg("pushed:{d} pulled:{d} new:{d} conflicts:{d}", .{
            result.objects_pushed,
            result.objects_pulled,
            result.new_to_local,
            result.conflicts,
        });
    }
}

pub fn syncThread() void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var base_dir = fs.openBaseDir() catch |err| {
        writeMsg("{s}", .{@errorName(err)});
        g_status.store(.failed, .release);
        return;
    };
    defer if (comptime is_android) base_dir.close();

    doSync(allocator, base_dir) catch |err| {
        switch (err) {
            error.ConnectionTimedOut => writeMsg("Connection timed out (10s).", .{}),
            else => writeMsg("{s}", .{@errorName(err)}),
        }
        g_status.store(.failed, .release);
        return;
    };

    g_status.store(.done, .release);
}
