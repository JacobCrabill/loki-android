const std = @import("std");
const builtin = @import("builtin");

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
