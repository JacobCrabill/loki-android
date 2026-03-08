const std = @import("std");
const builtin = @import("builtin");
const android = @import("android");
const rl = @import("raylib");
const loki = @import("loki");

const tcp_sync = loki.sync.net;

const is_android = builtin.abi.isAndroid();

const server_port: u16 = 7777;
const db_name = "loki_db";

// ---- Sync thread state ----

const SyncStatus = enum(u8) { connecting, syncing, done, failed };
var g_status = std.atomic.Value(SyncStatus).init(.connecting);
var g_msg_buf = std.mem.zeroes([256:0]u8);
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

fn deleteDb() bool {
    var base = openBaseDir() catch return false;
    defer if (is_android) base.close();
    base.deleteTree(db_name) catch return false;
    return true;
}

// ---- Background sync ----

fn doSync(allocator: std.mem.Allocator, base_dir: std.fs.Dir) !loki.sync.core.SyncResult {
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
    var conflicts: std.ArrayList(loki.model.merge.ConflictEntry) = .{};
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

// ---- Android text-input dialog ----

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

    fn slice(self: *const TextField) []const u8 {
        return self.buf[0..self.len];
    }

    fn showDialog(self: *const TextField, title: [*c]const u8, is_password: bool) void {
        if (comptime is_android) {
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

// ---- Draw helpers ----

// Draw text from a runtime slice (not null-terminated).
fn drawSlice(text: []const u8, x: i32, y: i32, fs: i32, color: rl.Color) void {
    var buf: [512:0]u8 = undefined;
    const n = @min(text.len, 511);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    rl.drawText(&buf, x, y, fs, color);
}

fn drawButton(label: [:0]const u8, x: i32, y: i32, w: i32, h: i32, color: rl.Color) void {
    rl.drawRectangle(x, y, w, h, color);
    const fs = 18;
    const tw = rl.measureText(label, fs);
    rl.drawText(label, x + @divTrunc(w - tw, 2), y + @divTrunc(h - fs, 2), fs, .white);
}

// ---- Browser row ----

const BrowserRow = struct {
    entry_id: [20]u8,
    head_hash: [20]u8,
    title: []u8,
    path: []u8,

    fn deinit(self: BrowserRow, a: std.mem.Allocator) void {
        a.free(self.title);
        a.free(self.path);
    }
};

fn rowLessThan(_: void, a: BrowserRow, b: BrowserRow) bool {
    const pc = std.mem.order(u8, a.path, b.path);
    if (pc != .eq) return pc == .lt;
    return std.mem.order(u8, a.title, b.title) == .lt;
}

// ---- App phases ----

const Phase = enum {
    unlock,
    browser,
    detail,
    sync_setup,
    sync_running,
    sync_result,
};

// ---- DB open + row population ----

const OpenError = error{ StorageError, WrongPassword, OpenFailed, OutOfMemory };

fn openDbAndPopulate(
    allocator: std.mem.Allocator,
    db_out: *?loki.Database,
    rows: *std.ArrayList(BrowserRow),
    pw_slice: []const u8,
) OpenError!void {
    var base = openBaseDir() catch return error.StorageError;
    defer if (is_android) base.close();

    const password: ?[]const u8 = if (pw_slice.len > 0) pw_slice else null;
    const opened = loki.Database.open(allocator, base, db_name, password) catch |err| {
        return if (err == error.WrongPassword) error.WrongPassword else error.OpenFailed;
    };

    if (db_out.*) |*d| d.deinit();
    db_out.* = opened;

    for (rows.items) |r| r.deinit(allocator);
    rows.clearRetainingCapacity();

    const entries = db_out.*.?.listEntries();
    for (entries) |ie| {
        const title = try allocator.dupe(u8, ie.title);
        errdefer allocator.free(title);
        const path = try allocator.dupe(u8, ie.path);
        errdefer allocator.free(path);
        try rows.append(allocator, .{
            .entry_id = ie.entry_id,
            .head_hash = ie.head_hash,
            .title = title,
            .path = path,
        });
    }
    std.mem.sort(BrowserRow, rows.items, {}, rowLessThan);
}

// ---- App entry point ----

pub fn main() !void {
    rl.initWindow(800, 450, "Loki");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var phase: Phase = if (dbDirExists()) .unlock else .sync_setup;

    // ---- Unlock state ----
    var unlock_pw = TextField{ .masked = true };
    var unlock_err: ?[:0]const u8 = null;
    var unlock_dialog_shown = false;

    // ---- DB + browser state ----
    var db: ?loki.Database = null;
    var rows: std.ArrayListUnmanaged(BrowserRow) = .{};
    var browser_scroll: f32 = 0;

    // ---- Detail state ----
    var detail_entry: ?loki.Entry = null;
    var detail_show_pw = false;
    var detail_scroll: f32 = 0;

    // ---- Sync state ----
    var ip_field = TextField{};
    ip_field.setDefault("192.168.1.100");
    var sync_pw_field = TextField{ .masked = true };
    var sync_focus_ip = true;
    var sync_err: ?[:0]const u8 = null;
    var sync_pending_field: ?bool = null; // true=ip dialog, false=pw dialog (Android)
    var first_use = (phase == .sync_setup);
    var delete_db_err: ?[:0]const u8 = null;

    // Tap detection: accumulate drag distance per press, tap if < threshold.
    var drag_accum: f32 = 0;

    defer {
        if (detail_entry) |e| e.deinit(allocator);
        for (rows.items) |r| r.deinit(allocator);
        rows.deinit(allocator);
        if (db) |*d| d.deinit();
    }

    // Layout constants (tuned for 800×450 desktop; scale on phone is a future task).
    const HDR_H: i32 = 56; // top header bar height
    const ROW_H: i32 = 72; // browser list row height
    const PAD: i32 = 16;
    const FH: i32 = 36; // form field height
    const FS_HDR: i32 = 24;
    const FS_BODY: i32 = 20;
    const FS_LABEL: i32 = 16;
    const FS_SMALL: i32 = 14;

    // Detail view: fields below the header, each DETAIL_ROW_H px tall.
    const DETAIL_ROW_H: i32 = 80;
    // Field indices in detail view (password is index 4).
    const DETAIL_PW_IDX: i32 = 4;

    while (!rl.windowShouldClose()) {
        const sw = rl.getScreenWidth();
        const sh = rl.getScreenHeight();
        const mouse = rl.getMousePosition();
        const mx = mouse.x;
        const my = mouse.y;

        if (rl.isMouseButtonPressed(.left)) drag_accum = 0;
        if (rl.isMouseButtonDown(.left)) drag_accum += @abs(rl.getMouseDelta().y);
        const is_tap = rl.isMouseButtonReleased(.left) and drag_accum < 8;

        // ==================================================================
        // INPUT
        // ==================================================================
        switch (phase) {

            // ---- Unlock ------------------------------------------------
            .unlock => {
                if (comptime is_android) {
                    if (!unlock_dialog_shown) {
                        unlock_pw.showDialog("Enter password", true);
                        unlock_dialog_shown = true;
                    }
                    var rbuf: [max_field + 1]u8 = undefined;
                    const poll = pollTextInputDialog(&rbuf, @intCast(rbuf.len));
                    if (poll > 0) {
                        const n: usize = @intCast(poll);
                        unlock_pw.len = n;
                        @memcpy(unlock_pw.buf[0..n], rbuf[0..n]);
                        unlock_dialog_shown = false;
                        openDbAndPopulate(allocator, &db, &rows, unlock_pw.slice()) catch |err| {
                            unlock_err = switch (err) {
                                error.WrongPassword => "Wrong password.",
                                else => "Failed to open database.",
                            };
                            // Will re-show dialog next iteration.
                        };
                        if (db != null) {
                            browser_scroll = 0;
                            phase = .browser;
                        }
                    } else if (poll < 0) {
                        unlock_dialog_shown = false;
                        unlock_err = "Cancelled. Tap to retry.";
                    } else if (is_tap and unlock_err != null and !unlock_dialog_shown) {
                        // Tap after cancel or error: re-show dialog.
                        unlock_pw.showDialog("Enter password", true);
                        unlock_dialog_shown = true;
                        unlock_err = null;
                    }
                } else {
                    // Desktop: keyboard input.
                    if (rl.isKeyPressed(.backspace)) unlock_pw.pop();
                    var ch = rl.getCharPressed();
                    while (ch != 0) : (ch = rl.getCharPressed()) {
                        if (ch >= 32 and ch < 127) unlock_pw.append(@intCast(ch));
                    }

                    const btn_w: i32 = 130;
                    const btn_h: i32 = 44;
                    const btn_x: i32 = @divTrunc(sw - btn_w, 2);
                    const btn_y: i32 = @divTrunc(sh, 2) + 20;
                    const open_pressed = rl.isKeyPressed(.enter) or
                        (is_tap and inRect(mx, my, btn_x, btn_y, btn_w, btn_h));
                    if (open_pressed) {
                        openDbAndPopulate(allocator, &db, &rows, unlock_pw.slice()) catch |err| {
                            unlock_err = switch (err) {
                                error.WrongPassword => "Wrong password.",
                                else => "Failed to open database.",
                            };
                        };
                        if (db != null) {
                            browser_scroll = 0;
                            phase = .browser;
                        }
                    }
                }
            },

            // ---- Browser -----------------------------------------------
            .browser => {
                if (rl.isMouseButtonDown(.left)) {
                    browser_scroll -= rl.getMouseDelta().y;
                }
                const content_h: f32 = @floatFromInt(@as(i32, @intCast(rows.items.len)) * ROW_H);
                const visible_h: f32 = @floatFromInt(sh - HDR_H);
                browser_scroll = std.math.clamp(browser_scroll, 0, @max(0, content_h - visible_h));

                if (is_tap) {
                    // Sync button (top-right of header).
                    const sbx: i32 = sw - 80 - PAD;
                    const sby: i32 = @divTrunc(HDR_H - 36, 2);
                    if (inRect(mx, my, sbx, sby, 80, 36)) {
                        if (db) |*d| d.deinit();
                        db = null;
                        for (rows.items) |r| r.deinit(allocator);
                        rows.clearRetainingCapacity();
                        first_use = false;
                        delete_db_err = null;
                        phase = .sync_setup;
                    }
                    // Row tap → detail.
                    else if (my >= @as(f32, @floatFromInt(HDR_H))) {
                        const rel_y = @as(i32, @intFromFloat(my)) - HDR_H +
                            @as(i32, @intFromFloat(browser_scroll));
                        const idx_i = @divTrunc(rel_y, ROW_H);
                        if (idx_i >= 0 and idx_i < @as(i32, @intCast(rows.items.len))) {
                            const idx: usize = @intCast(idx_i);
                            if (db) |*d| {
                                if (detail_entry) |e| e.deinit(allocator);
                                detail_entry = d.getEntry(rows.items[idx].entry_id) catch null;
                                detail_show_pw = false;
                                detail_scroll = 0;
                                phase = .detail;
                            }
                        }
                    }
                }
            },

            // ---- Detail ------------------------------------------------
            .detail => {
                if (rl.isMouseButtonDown(.left)) {
                    detail_scroll -= rl.getMouseDelta().y;
                }
                detail_scroll = @max(0, detail_scroll);
                if (comptime !is_android) {
                    if (rl.isKeyPressed(.h)) detail_show_pw = !detail_show_pw;
                    if (rl.isKeyPressed(.escape) or rl.isKeyPressed(.backspace))
                        phase = .browser;
                }
                if (is_tap) {
                    // Back button: left quarter of header.
                    if (inRect(mx, my, 0, 0, @divTrunc(sw, 4), HDR_H))
                        phase = .browser;
                    // Show/hide password toggle button.
                    const pw_row_y = HDR_H + PAD + DETAIL_PW_IDX * DETAIL_ROW_H -
                        @as(i32, @intFromFloat(detail_scroll));
                    if (inRect(mx, my, sw - 100 - PAD, pw_row_y, 100, 32))
                        detail_show_pw = !detail_show_pw;
                }
            },

            // ---- Sync setup --------------------------------------------
            .sync_setup => {
                const fx: i32 = 180;
                const fw: i32 = 400;
                const ip_y: i32 = 110;
                const pw_y: i32 = 170;
                const btn_x: i32 = fx;
                const btn_y: i32 = 240;
                const btn_w: i32 = 130;
                const btn_h: i32 = 42;
                const del_btn_x: i32 = btn_x + btn_w + 20;
                const del_btn_y: i32 = btn_y;
                const del_btn_w: i32 = 130;
                const del_btn_h: i32 = btn_h;

                if (rl.isMouseButtonPressed(.left)) {
                    if (inRect(mx, my, fx, ip_y, fw, FH)) {
                        sync_focus_ip = true;
                        if (comptime is_android) {
                            ip_field.showDialog("Server IP", false);
                            sync_pending_field = true;
                        }
                    } else if (inRect(mx, my, fx, pw_y, fw, FH)) {
                        sync_focus_ip = false;
                        if (comptime is_android) {
                            sync_pw_field.showDialog("Password", true);
                            sync_pending_field = false;
                        }
                    }
                }

                if (comptime is_android) {
                    if (sync_pending_field) |is_ip| {
                        var rbuf: [max_field + 1]u8 = undefined;
                        const r = pollTextInputDialog(&rbuf, @intCast(rbuf.len));
                        if (r > 0) {
                            const field = if (is_ip) &ip_field else &sync_pw_field;
                            const n: usize = @intCast(r);
                            field.len = n;
                            @memcpy(field.buf[0..n], rbuf[0..n]);
                            sync_pending_field = null;
                        } else if (r < 0) {
                            sync_pending_field = null;
                        }
                    }
                } else {
                    if (rl.isKeyPressed(.tab)) sync_focus_ip = !sync_focus_ip;
                    const active = if (sync_focus_ip) &ip_field else &sync_pw_field;
                    if (rl.isKeyPressed(.backspace)) active.pop();
                    var ch = rl.getCharPressed();
                    while (ch != 0) : (ch = rl.getCharPressed()) {
                        if (ch >= 32 and ch < 127) active.append(@intCast(ch));
                    }
                }

                // Delete DB button.
                if (!first_use and rl.isMouseButtonPressed(.left) and
                    inRect(mx, my, del_btn_x, del_btn_y, del_btn_w, del_btn_h))
                {
                    if (deleteDb()) {
                        first_use = true;
                        delete_db_err = null;
                        sync_err = null;
                    } else {
                        delete_db_err = "Failed to delete database.";
                    }
                }

                // Sync / Fetch button.
                const clicked_btn = rl.isMouseButtonPressed(.left) and
                    inRect(mx, my, btn_x, btn_y, btn_w, btn_h);
                if (clicked_btn or rl.isKeyPressed(.enter)) {
                    if (ip_field.len == 0 or sync_pw_field.len == 0) {
                        sync_err = "Please enter IP and password.";
                    } else {
                        @memcpy(g_ip[0..ip_field.len], ip_field.buf[0..ip_field.len]);
                        g_ip_len = ip_field.len;
                        @memcpy(g_pw[0..sync_pw_field.len], sync_pw_field.buf[0..sync_pw_field.len]);
                        g_pw_len = sync_pw_field.len;
                        g_status.store(.connecting, .release);
                        if (std.Thread.spawn(.{}, syncThread, .{})) |thread| {
                            thread.detach();
                            phase = .sync_running;
                            sync_err = null;
                            delete_db_err = null;
                        } else |_| {
                            sync_err = "Failed to start sync thread.";
                        }
                    }
                }
            },

            .sync_running => {
                const s = g_status.load(.acquire);
                if (s == .done or s == .failed) phase = .sync_result;
            },

            .sync_result => {
                // "Open" button: go to unlock (or browser if no password needed).
                const btn_w: i32 = 120;
                const btn_h: i32 = 44;
                const btn_x: i32 = 10;
                const btn_y: i32 = sh - btn_h - PAD;
                if (is_tap and inRect(mx, my, btn_x, btn_y, btn_w, btn_h) and
                    g_status.load(.acquire) == .done)
                {
                    unlock_pw = TextField{ .masked = true };
                    unlock_err = null;
                    unlock_dialog_shown = false;
                    phase = .unlock;
                }
            },
        }

        // ==================================================================
        // DRAW
        // ==================================================================
        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(.black);

        switch (phase) {

            // ---- Unlock ------------------------------------------------
            .unlock => {
                rl.drawText("Loki", 10, 10, 28, .white);
                rl.drawText("Enter password to open your database.", 10, 50, FS_BODY, .gray);

                const fw: i32 = 400;
                const fx: i32 = @divTrunc(sw - fw, 2);
                const fy: i32 = @divTrunc(sh, 2) - FH;
                drawTextField(&unlock_pw, fx, fy, fw, FH, true);

                if (unlock_err) |msg| {
                    rl.drawText(msg, fx, fy + FH + 8, FS_LABEL, .orange);
                }

                if (comptime !is_android) {
                    const btn_w: i32 = 130;
                    const btn_h: i32 = 44;
                    const btn_x: i32 = @divTrunc(sw - btn_w, 2);
                    const btn_y: i32 = @divTrunc(sh, 2) + 20;
                    drawButton("Open", btn_x, btn_y, btn_w, btn_h, .{ .r = 30, .g = 140, .b = 200, .a = 255 });
                    rl.drawText("Enter: open", fx, sh - 30, FS_SMALL, .dark_gray);
                }
            },

            // ---- Browser -----------------------------------------------
            .browser => {
                // Header bar.
                rl.drawRectangle(0, 0, sw, HDR_H, .{ .r = 20, .g = 20, .b = 30, .a = 255 });
                rl.drawText("Loki", PAD, @divTrunc(HDR_H - FS_HDR, 2), FS_HDR, .white);

                // Sync button (top-right).
                const sbx: i32 = sw - 80 - PAD;
                const sby: i32 = @divTrunc(HDR_H - 36, 2);
                drawButton("Sync", sbx, sby, 80, 36, .{ .r = 30, .g = 130, .b = 180, .a = 255 });

                if (rows.items.len == 0) {
                    rl.drawText("No entries.", PAD, HDR_H + PAD, FS_BODY, .gray);
                }

                // Clipped entry list.
                const list_top: i32 = HDR_H;
                rl.beginScissorMode(0, list_top, sw, sh - list_top);
                for (rows.items, 0..) |row, i| {
                    const row_y: i32 = list_top + @as(i32, @intCast(i)) * ROW_H -
                        @as(i32, @intFromFloat(browser_scroll));
                    if (row_y + ROW_H < list_top or row_y > sh) continue;

                    // Alternating background.
                    const bg: rl.Color = if (i % 2 == 0)
                        .{ .r = 18, .g = 18, .b = 28, .a = 255 }
                    else
                        .{ .r = 24, .g = 24, .b = 36, .a = 255 };
                    rl.drawRectangle(0, row_y, sw, ROW_H, bg);

                    // Title.
                    drawSlice(row.title, PAD, row_y + 10, FS_BODY, .white);
                    // Path (dimmer, smaller).
                    if (row.path.len > 0) {
                        drawSlice(row.path, PAD, row_y + 10 + FS_BODY + 6, FS_SMALL, .gray);
                    }

                    // Chevron ›.
                    rl.drawText(">", sw - PAD - 16, row_y + @divTrunc(ROW_H - FS_BODY, 2), FS_BODY, .dark_gray);

                    // Divider.
                    rl.drawRectangle(0, row_y + ROW_H - 1, sw, 1, .{ .r = 40, .g = 40, .b = 55, .a = 255 });
                }
                rl.endScissorMode();
            },

            // ---- Detail ------------------------------------------------
            .detail => {
                const entry = detail_entry orelse {
                    rl.drawText("No entry loaded.", PAD, HDR_H + PAD, FS_BODY, .gray);
                    return;
                };

                // Header.
                rl.drawRectangle(0, 0, sw, HDR_H, .{ .r = 20, .g = 20, .b = 30, .a = 255 });
                rl.drawText("< Back", PAD, @divTrunc(HDR_H - FS_BODY, 2), FS_BODY, .sky_blue);
                drawSlice(entry.title, @divTrunc(sw, 4), @divTrunc(HDR_H - FS_HDR, 2), FS_HDR, .white);

                // Scrollable field list.
                rl.beginScissorMode(0, HDR_H, sw, sh - HDR_H);

                const scroll_i: i32 = @intFromFloat(detail_scroll);
                const field_x0: i32 = PAD;
                const val_x: i32 = 160;
                _ = sw - val_x - PAD - 110; // val_w: leave room for toggle button

                const Field = struct { label: []const u8, value: []const u8 };
                const fields = [_]Field{
                    .{ .label = "Title", .value = entry.title },
                    .{ .label = "Path", .value = entry.path },
                    .{ .label = "Desc", .value = entry.description },
                    .{ .label = "URL", .value = entry.url },
                    .{ .label = "Username", .value = entry.username },
                    .{ .label = "Password", .value = entry.password },
                    .{ .label = "Notes", .value = entry.notes },
                };

                for (fields, 0..) |f, fi| {
                    const fy: i32 = HDR_H + PAD + @as(i32, @intCast(fi)) * DETAIL_ROW_H - scroll_i;
                    if (fy + DETAIL_ROW_H < HDR_H or fy > sh) continue;

                    // Row background.
                    const bg: rl.Color = if (fi % 2 == 0)
                        .{ .r = 18, .g = 18, .b = 28, .a = 255 }
                    else
                        .{ .r = 26, .g = 26, .b = 38, .a = 255 };
                    rl.drawRectangle(0, fy, sw, DETAIL_ROW_H, bg);

                    // Label.
                    drawSlice(f.label, field_x0, fy + @divTrunc(DETAIL_ROW_H - FS_LABEL, 2), FS_LABEL, .gray);

                    // Value (password masked unless show_pw is set).
                    if (fi == DETAIL_PW_IDX and !detail_show_pw) {
                        var stars: [64:0]u8 = undefined;
                        const n = @min(f.value.len, 63);
                        @memset(stars[0..n], '*');
                        stars[n] = 0;
                        rl.drawText(&stars, val_x, fy + @divTrunc(DETAIL_ROW_H - FS_BODY, 2), FS_BODY, .white);

                        // Show/Hide button.
                        const toggle_label: [:0]const u8 = "Show";
                        drawButton(toggle_label, sw - 100 - PAD, fy + @divTrunc(DETAIL_ROW_H - 32, 2), 100, 32,
                            .{ .r = 60, .g = 60, .b = 80, .a = 255 });
                    } else if (fi == DETAIL_PW_IDX and detail_show_pw) {
                        drawSlice(f.value, val_x, fy + @divTrunc(DETAIL_ROW_H - FS_BODY, 2), FS_BODY,
                            .{ .r = 255, .g = 200, .b = 100, .a = 255 });

                        const toggle_label: [:0]const u8 = "Hide";
                        drawButton(toggle_label, sw - 100 - PAD, fy + @divTrunc(DETAIL_ROW_H - 32, 2), 100, 32,
                            .{ .r = 60, .g = 60, .b = 80, .a = 255 });
                    } else {
                        // Clip long values to val_w to avoid overflow.
                        drawSlice(f.value, val_x, fy + @divTrunc(DETAIL_ROW_H - FS_BODY, 2), FS_BODY, .white);
                    }

                    // Divider.
                    rl.drawRectangle(0, fy + DETAIL_ROW_H - 1, sw, 1, .{ .r = 40, .g = 40, .b = 55, .a = 255 });
                }

                if (comptime !is_android) {
                    const hint_y: i32 = sh - 22;
                    rl.drawText("h: show/hide password   Esc/Backspace: back", PAD, hint_y, FS_SMALL, .dark_gray);
                }

                rl.endScissorMode();
            },

            // ---- Sync setup --------------------------------------------
            .sync_setup => {
                const lx: i32 = 30;
                const fx: i32 = 180;
                const fw: i32 = 400;
                const ip_y: i32 = 110;
                const pw_y: i32 = 170;
                const btn_x: i32 = fx;
                const btn_y: i32 = 240;
                const btn_w: i32 = 130;
                const btn_h: i32 = 42;
                const del_btn_x: i32 = btn_x + btn_w + 20;
                const del_btn_y: i32 = btn_y;
                const del_btn_w: i32 = 130;
                const del_btn_h: i32 = btn_h;

                rl.drawText("Loki Sync", 10, 10, 28, .white);

                const subtitle: [:0]const u8 = if (first_use)
                    "First use: fetch the database from server"
                else
                    "Sync database with server";
                rl.drawText(subtitle, 10, 46, FS_LABEL, .gray);

                rl.drawText("Server IP", lx, ip_y + @divTrunc(FH - FS_BODY, 2), FS_BODY, .light_gray);
                drawTextField(&ip_field, fx, ip_y, fw, FH, sync_focus_ip);

                rl.drawText("Password", lx, pw_y + @divTrunc(FH - FS_BODY, 2), FS_BODY, .light_gray);
                drawTextField(&sync_pw_field, fx, pw_y, fw, FH, !sync_focus_ip);

                const btn_label: [:0]const u8 = if (first_use) "Fetch" else "Sync";
                rl.drawRectangle(btn_x, btn_y, btn_w, btn_h, .sky_blue);
                const btn_tw = rl.measureText(btn_label, FS_BODY);
                rl.drawText(btn_label, btn_x + @divTrunc(btn_w - btn_tw, 2),
                    btn_y + @divTrunc(btn_h - FS_BODY, 2), FS_BODY, .white);

                if (!first_use) {
                    rl.drawRectangle(del_btn_x, del_btn_y, del_btn_w, del_btn_h,
                        .{ .r = 180, .g = 40, .b = 40, .a = 255 });
                    const del_tw = rl.measureText("Delete DB", FS_BODY);
                    rl.drawText("Delete DB", del_btn_x + @divTrunc(del_btn_w - del_tw, 2),
                        del_btn_y + @divTrunc(del_btn_h - FS_BODY, 2), FS_BODY, .white);
                }

                if (sync_err) |msg| rl.drawText(msg, lx, 300, FS_LABEL, .orange);
                if (delete_db_err) |msg| rl.drawText(msg, lx, 320, FS_LABEL, .red);

                if (comptime !is_android) {
                    rl.drawText("Tab: switch field   Enter: submit", lx, 400, FS_SMALL, .dark_gray);
                } else {
                    rl.drawText("Tap a field to edit it", lx, 400, FS_SMALL, .dark_gray);
                }
            },

            // ---- Sync running ------------------------------------------
            .sync_running => {
                rl.drawText("Loki Sync", 10, 10, 28, .white);
                const status_text: [:0]const u8 = switch (g_status.load(.acquire)) {
                    .connecting => "Connecting...",
                    .syncing => "Syncing...",
                    else => "Please wait...",
                };
                rl.drawText(status_text, 10, 200, 24, .yellow);
            },

            // ---- Sync result -------------------------------------------
            .sync_result => {
                rl.drawText("Loki Sync", 10, 10, 28, .white);
                switch (g_status.load(.acquire)) {
                    .done => {
                        rl.drawText("Sync complete!", 10, 200, 24, .green);
                        rl.drawText(&g_msg_buf, 10, 234, 18, .green);
                        // "Open" button.
                        const btn_w: i32 = 120;
                        const btn_h: i32 = 44;
                        const btn_x: i32 = 10;
                        const btn_y: i32 = sh - btn_h - PAD;
                        drawButton("Open DB", btn_x, btn_y, btn_w, btn_h,
                            .{ .r = 30, .g = 140, .b = 80, .a = 255 });
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
