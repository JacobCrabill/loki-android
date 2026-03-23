const std = @import("std");
const builtin = @import("builtin");
const ui = @import("ui.zig");

const is_android = builtin.abi.isAndroid();

pub const db_name = "loki_db";

pub fn openBaseDir() !std.fs.Dir {
    if (comptime is_android)
        return std.fs.openDirAbsolute("/data/data/com.zig.loki/files", .{});
    return std.fs.cwd();
}

pub fn dbDirExists() bool {
    var base = openBaseDir() catch return false;
    defer if (comptime is_android) base.close();
    var d = base.openDir(db_name, .{}) catch return false;
    d.close();
    return true;
}

pub fn deleteDb() bool {
    var base = openBaseDir() catch return false;
    defer if (comptime is_android) base.close();
    base.deleteTree(db_name) catch return false;
    return true;
}

/// Read the persisted server IP into `buf`. Returns the number of bytes read.
pub fn loadPrefs(base: std.fs.Dir, buf: []u8) usize {
    var f = base.openFile("loki_prefs", .{}) catch return 0;
    defer f.close();
    return f.read(buf) catch 0;
}

pub fn savePrefs(base: std.fs.Dir, ip: []const u8) void {
    var f = base.createFile("loki_prefs", .{}) catch return;
    defer f.close();
    _ = f.writeAll(ip) catch {};
}

// ---- Address book persistence ----
//
// File format ("loki_addrs"):
//   First line: selected index as decimal ASCII, e.g. "0\n"
//   Subsequent lines: "name\tip\n" for each stored address.

const addrs_file = "loki_addrs";

/// Load the address book from disk.  Returns true if the file was found and
/// parsed; false otherwise (caller should attempt migration from loki_prefs).
pub fn loadAddrs(
    base: std.fs.Dir,
    addrs: []ui.ServerAddr,
    count: *usize,
    selected: *usize,
) bool {
    var f = base.openFile(addrs_file, .{}) catch return false;
    defer f.close();

    var buf: [8192]u8 = undefined;
    const n = f.read(&buf) catch return false;
    if (n == 0) return false;

    const data = buf[0..n];
    var lines = std.mem.splitScalar(u8, data, '\n');

    // First line: selected index
    const sel_line = lines.next() orelse return false;
    selected.* = std.fmt.parseInt(usize, sel_line, 10) catch 0;

    // Remaining lines: name\tip
    var i: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (i >= addrs.len) break;

        // Split on tab
        var parts = std.mem.splitScalar(u8, line, '\t');
        const name_part = parts.next() orelse continue;
        const ip_part = parts.next() orelse continue;

        const name_n = @min(name_part.len, ui.max_addr_name);
        const ip_n = @min(ip_part.len, ui.max_field);

        addrs[i] = .{};
        @memcpy(addrs[i].name[0..name_n], name_part[0..name_n]);
        addrs[i].name_len = name_n;
        @memcpy(addrs[i].ip[0..ip_n], ip_part[0..ip_n]);
        addrs[i].ip_len = ip_n;
        i += 1;
    }
    count.* = i;

    // Clamp selected index
    if (selected.* >= i and i > 0) selected.* = 0;
    return i > 0;
}

/// Persist the address book to disk.
pub fn saveAddrs(
    base: std.fs.Dir,
    addrs: []const ui.ServerAddr,
    count: usize,
    selected: usize,
) void {
    var f = base.createFile(addrs_file, .{}) catch return;
    defer f.close();

    // Build output in a stack buffer, then write all at once.
    var buf: [8192]u8 = undefined;
    var pos: usize = 0;

    // First line: selected index
    const idx_slice = std.fmt.bufPrint(buf[pos..], "{d}\n", .{selected}) catch return;
    pos += idx_slice.len;

    // Each address: name\tip\n
    for (addrs[0..count]) |*a| {
        if (pos + a.name_len + 1 + a.ip_len + 1 > buf.len) break;
        @memcpy(buf[pos..][0..a.name_len], a.name[0..a.name_len]);
        pos += a.name_len;
        buf[pos] = '\t';
        pos += 1;
        @memcpy(buf[pos..][0..a.ip_len], a.ip[0..a.ip_len]);
        pos += a.ip_len;
        buf[pos] = '\n';
        pos += 1;
    }

    _ = f.writeAll(buf[0..pos]) catch {};
}
