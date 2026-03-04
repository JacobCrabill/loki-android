const std = @import("std");
const builtin = @import("builtin");
const android = @import("android");
const rl = @import("raylib");
const loki = @import("loki");

const tcp_sync = loki.store.tcp_sync;

const is_android = builtin.abi.isAndroid();

const server_port: u16 = 7777;
const db_name = "loki_db";

// ---- State shared between sync thread and render thread ----
const SyncStatus = enum(u8) { connecting, syncing, done, failed };
var g_status = std.atomic.Value(SyncStatus).init(.connecting);
// g_msg_buf is written before the status store(.release), read after load(.acquire).
var g_msg_buf = std.mem.zeroes([256:0]u8);

// Params written before thread spawn; only read by the sync thread afterward.
var g_ip: [128]u8 = undefined;
var g_ip_len: usize = 0;
var g_pw: [128]u8 = undefined;
var g_pw_len: usize = 0;

fn writeMsg(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(g_msg_buf[0..255], fmt, args) catch g_msg_buf[0..0];
    g_msg_buf[s.len] = 0;
}

// ---- Filesystem helpers ----

fn openBaseDir() !std.fs.Dir {
    if (is_android)
        return std.fs.openDirAbsolute("/data/data/com.zig.loki/files", .{});
    return std.fs.cwd();
}

fn dbDirExists() bool {
    var base = openBaseDir() catch return false;
    defer if (is_android) base.close();
    var d = base.openDir(db_name, .{}) catch return false;
    d.close();
    return true;
}

// ---- Background sync ----

fn doSync(allocator: std.mem.Allocator, base_dir: std.fs.Dir) !tcp_sync.SyncResult {
    const ip = g_ip[0..g_ip_len];
    const pw = g_pw[0..g_pw_len];

    var db = loki.Database.open(allocator, base_dir, db_name, pw) catch |err| blk: {
        if (err != error.FileNotFound) return err;
        break :blk try loki.Database.create(allocator, base_dir, db_name, pw);
    };
    defer db.deinit();

    g_status.store(.connecting, .release);

    const addr = try std.net.Address.parseIp(ip, server_port);
    const stream = try std.net.tcpConnectToAddress(addr);
    defer stream.close();

    g_status.store(.syncing, .release);

    var r = stream.reader(&.{});
    var w = stream.writer(&.{});
    var conflicts: std.ArrayList(tcp_sync.ConflictEntry) = .{};
    defer conflicts.deinit(allocator);

    return tcp_sync.syncSession(allocator, &db, r.interface(), &w.interface, .client, &conflicts);
}

fn syncThread() void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var base_dir = openBaseDir() catch |err| {
        writeMsg("{s}", .{@errorName(err)});
        g_status.store(.failed, .release);
        return;
    };
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

// ---- Android text-input dialog (compiles away to no-ops on desktop) ----
//
// On Android, tapping a text field pops a native AlertDialog with an EditText.
// This is the only reliable way to receive IME input from a NativeActivity,
// because modern soft keyboards deliver text via InputConnection.commitText()
// rather than AKeyEvent, and NativeActivity does not implement InputConnection.

extern fn showTextInputDialog(title: [*c]const u8, current: [*c]const u8, is_password: c_int) void;
extern fn pollTextInputDialog(out_buf: [*]u8, buf_size: c_int) c_int;

// ---- Text input field ----

const max_field = 127;

const TextField = struct {
    buf: [max_field + 1]u8 = std.mem.zeroes([max_field + 1]u8),
    len: usize = 0,
    masked: bool = false,

    fn append(self: *TextField, ch: u8) void {
        if (self.len < max_field) {
            self.buf[self.len] = ch;
            self.len += 1;
        }
    }

    fn pop(self: *TextField) void {
        if (self.len > 0) self.len -= 1;
    }

    fn setDefault(self: *TextField, s: []const u8) void {
        const n = @min(s.len, max_field);
        @memcpy(self.buf[0..n], s[0..n]);
        self.len = n;
    }

    // Show a native dialog pre-filled with this field's content (Android only).
    fn showDialog(self: *const TextField, title: [*c]const u8, is_password: bool) void {
        if (comptime is_android) {
            // Build a null-terminated copy since buf[len] may not be zero.
            var tmp: [max_field + 1]u8 = std.mem.zeroes([max_field + 1]u8);
            @memcpy(tmp[0..self.len], self.buf[0..self.len]);
            showTextInputDialog(title, &tmp, @intFromBool(is_password));
        }
    }
};

fn drawTextField(f: *const TextField, x: i32, y: i32, w: i32, h: i32, focused: bool) void {
    rl.drawRectangle(x, y, w, h, if (focused) .white else .light_gray);
    rl.drawRectangleLines(x, y, w, h, if (focused) .sky_blue else .gray);

    var disp: [max_field + 1:0]u8 = std.mem.zeroes([max_field + 1:0]u8);
    if (f.masked) {
        @memset(disp[0..f.len], '*');
    } else {
        @memcpy(disp[0..f.len], f.buf[0..f.len]);
    }

    const fs = 20;
    rl.drawText(&disp, x + 6, y + @divTrunc(h - fs, 2), fs, .dark_gray);

    if (focused) {
        const tw = rl.measureText(&disp, fs);
        rl.drawRectangle(x + 6 + tw, y + 5, 2, h - 10, .sky_blue);
    }
}

fn inRect(mx: f32, my: f32, x: i32, y: i32, w: i32, h: i32) bool {
    return mx >= @as(f32, @floatFromInt(x)) and
        mx < @as(f32, @floatFromInt(x + w)) and
        my >= @as(f32, @floatFromInt(y)) and
        my < @as(f32, @floatFromInt(y + h));
}

// ---- App state ----

const Phase = enum { setup, running, result };
const Focus = enum { ip, pw };

// ---- App entry point ----

pub fn main() !void {
    rl.initWindow(800, 450, "Loki Sync");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    const first_use = !dbDirExists();

    var ip_field = TextField{};
    ip_field.setDefault("192.168.1.100");
    var pw_field = TextField{ .masked = true };
    var focus: Focus = .ip;
    var phase: Phase = .setup;
    var err_msg: ?[:0]const u8 = null;

    // Android: track which field is waiting for a dialog result.
    var pending_field: ?Focus = null;

    // Layout
    const lx: i32 = 30;
    const fx: i32 = 180;
    const fw: i32 = 400;
    const fh: i32 = 36;
    const ip_y: i32 = 110;
    const pw_y: i32 = 170;
    const btn_x: i32 = fx;
    const btn_y: i32 = 240;
    const btn_w: i32 = 130;
    const btn_h: i32 = 42;

    while (!rl.windowShouldClose()) {
        // --- Input (setup phase only) ---
        if (phase == .setup) {
            const mouse = rl.getMousePosition();
            const mx = mouse.x;
            const my = mouse.y;

            if (rl.isMouseButtonPressed(.left)) {
                if (inRect(mx, my, fx, ip_y, fw, fh)) {
                    focus = .ip;
                    if (comptime is_android) {
                        ip_field.showDialog("Server IP", false);
                        pending_field = .ip;
                    }
                } else if (inRect(mx, my, fx, pw_y, fw, fh)) {
                    focus = .pw;
                    if (comptime is_android) {
                        pw_field.showDialog("Password", true);
                        pending_field = .pw;
                    }
                }
            }

            // Android: collect dialog result into the appropriate field.
            if (comptime is_android) {
                if (pending_field) |pf| {
                    var rbuf: [max_field + 1]u8 = undefined;
                    const r = pollTextInputDialog(&rbuf, @intCast(rbuf.len));
                    if (r > 0) {
                        const field = if (pf == .ip) &ip_field else &pw_field;
                        const n: usize = @intCast(r);
                        field.len = n;
                        @memcpy(field.buf[0..n], rbuf[0..n]);
                        pending_field = null;
                    } else if (r < 0) {
                        pending_field = null; // cancelled
                    }
                }
            }

            // Desktop only: direct keyboard input into focused field.
            if (comptime !is_android) {
                if (rl.isKeyPressed(.tab)) {
                    focus = if (focus == .ip) .pw else .ip;
                }

                const active = if (focus == .ip) &ip_field else &pw_field;

                if (rl.isKeyPressed(.backspace)) active.pop();

                var ch = rl.getCharPressed();
                while (ch != 0) {
                    if (ch >= 32 and ch < 127) active.append(@intCast(ch));
                    ch = rl.getCharPressed();
                }
            }

            // Submit (both platforms; Enter key is useful with a hardware keyboard).
            const clicked_btn = rl.isMouseButtonPressed(.left) and
                inRect(mx, my, btn_x, btn_y, btn_w, btn_h);
            if (clicked_btn or rl.isKeyPressed(.enter)) {
                if (ip_field.len == 0 or pw_field.len == 0) {
                    err_msg = "Please enter IP and password.";
                } else {
                    @memcpy(g_ip[0..ip_field.len], ip_field.buf[0..ip_field.len]);
                    g_ip_len = ip_field.len;
                    @memcpy(g_pw[0..pw_field.len], pw_field.buf[0..pw_field.len]);
                    g_pw_len = pw_field.len;
                    g_status.store(.connecting, .release);
                    if (std.Thread.spawn(.{}, syncThread, .{})) |thread| {
                        thread.detach();
                        phase = .running;
                        err_msg = null;
                    } else |_| {
                        err_msg = "Failed to start sync thread.";
                    }
                }
            }
        }

        if (phase == .running) {
            const s = g_status.load(.acquire);
            if (s == .done or s == .failed) phase = .result;
        }

        // --- Draw ---
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(.black);
        rl.drawText("Loki Sync", 10, 10, 28, .white);

        switch (phase) {
            .setup => {
                const subtitle: [:0]const u8 = if (first_use)
                    "First use: fetch the database from server"
                else
                    "Sync database with server";
                rl.drawText(subtitle, 10, 46, 16, .gray);

                rl.drawText("Server IP", lx, ip_y + @divTrunc(fh - 20, 2), 20, .light_gray);
                drawTextField(&ip_field, fx, ip_y, fw, fh, focus == .ip);

                rl.drawText("Password", lx, pw_y + @divTrunc(fh - 20, 2), 20, .light_gray);
                drawTextField(&pw_field, fx, pw_y, fw, fh, focus == .pw);

                const btn_label: [:0]const u8 = if (first_use) "Fetch" else "Sync";
                rl.drawRectangle(btn_x, btn_y, btn_w, btn_h, .sky_blue);
                const btn_tw = rl.measureText(btn_label, 20);
                rl.drawText(
                    btn_label,
                    btn_x + @divTrunc(btn_w - btn_tw, 2),
                    btn_y + @divTrunc(btn_h - 20, 2),
                    20,
                    .white,
                );

                if (err_msg) |msg| {
                    rl.drawText(msg, lx, 310, 16, .orange);
                }

                if (comptime !is_android) {
                    rl.drawText("Tab: switch field   Enter: submit", lx, 400, 14, .dark_gray);
                } else {
                    rl.drawText("Tap a field to edit it", lx, 400, 14, .dark_gray);
                }
            },
            .running => {
                const status_text: [:0]const u8 = switch (g_status.load(.acquire)) {
                    .connecting => "Connecting...",
                    .syncing => "Syncing...",
                    else => "Please wait...",
                };
                rl.drawText(status_text, 10, 200, 24, .yellow);
            },
            .result => {
                switch (g_status.load(.acquire)) {
                    .done => {
                        rl.drawText("Sync complete!", 10, 200, 24, .green);
                        rl.drawText(&g_msg_buf, 10, 234, 18, .green);
                    },
                    .failed => {
                        rl.drawText("Sync failed:", 10, 200, 24, .red);
                        rl.drawText(&g_msg_buf, 10, 234, 18, .red);
                    },
                    else => {},
                }
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
