const std = @import("std");
const builtin = @import("builtin");
const android = @import("android");
const rl = @import("raylib");
const loki = @import("loki");

const tcp_sync = loki.sync.net;

const is_android = builtin.abi.isAndroid();

const server_port: u16 = 7777;
const db_name = "loki_db";
const connect_timeout_ms: i32 = 10_000;

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

// ---- Prefs (persist server IP) ----

fn loadPrefs(base: std.fs.Dir, ip: *TextField) void {
    var f = base.openFile("loki_prefs", .{}) catch return;
    defer f.close();
    var buf: [max_field]u8 = undefined;
    const n = f.read(&buf) catch return;
    if (n > 0) ip.setDefault(buf[0..n]);
}

fn savePrefs(base: std.fs.Dir, ip: []const u8) void {
    var f = base.createFile("loki_prefs", .{}) catch return;
    defer f.close();
    _ = f.writeAll(ip) catch {};
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

// ---- Network helpers ----

/// Non-blocking connect with a `connect_timeout_ms` deadline.
/// Returns `error.ConnectionTimedOut` when the server doesn't respond in time.
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

    // Restore blocking mode (clear O_NONBLOCK = 0x800 from the flags word).
    const flags: usize = @intCast(try std.posix.fcntl(sockfd, std.posix.F.GETFL, 0));
    _ = try std.posix.fcntl(sockfd, std.posix.F.SETFL, flags & ~@as(usize, 0x800));

    return .{ .handle = sockfd };
}

// ---- Background sync ----

fn doSync(allocator: std.mem.Allocator, base_dir: std.fs.Dir) !void {
    const ip = g_ip[0..g_ip_len];
    const pw = g_pw[0..g_pw_len];

    // Connect first — DB is only created if the connection succeeds.
    const addr = try std.net.Address.parseIp(ip, server_port);
    const stream = try tcpConnectTimeout(addr);
    defer stream.close();

    g_status.store(.syncing, .release);

    var r = stream.reader(&.{});
    var w = stream.writer(&.{});
    const ri = r.interface();
    const wi = &w.interface;

    if (!dbDirExists()) {
        // First use: send the fetch discriminator and pull the whole database.
        try wi.writeAll(&[_]u8{tcp_sync.protocol_fetch});
        try tcp_sync.fetchClient(allocator, pw, base_dir, db_name, ri, wi);
        writeMsg("Fetch complete.", .{});
    } else {
        // Subsequent run: bidirectional sync with an existing database.
        try wi.writeAll(&[_]u8{tcp_sync.protocol_sync});
        var db = try loki.Database.open(allocator, base_dir, db_name, pw);
        defer db.deinit();
        var conflicts: std.ArrayList(loki.model.merge.ConflictEntry) = .{};
        defer conflicts.deinit(allocator);
        const result = try tcp_sync.syncSession(allocator, &db, ri, wi, .client, &conflicts);
        writeMsg("pushed:{d} pulled:{d} new:{d} conflicts:{d}", .{
            result.objects_pushed,
            result.objects_pulled,
            result.new_to_local,
            result.conflicts,
        });
    }
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

// Font size derived from element height: ~55% of height.
fn fsByHeight(h: i32) i32 {
    return @max(12, @divTrunc(h * 11, 20));
}

fn drawTextField(f: *const TextField, x: i32, y: i32, w: i32, h: i32, focused: bool) void {
    rl.drawRectangle(x, y, w, h, if (focused) .white else .light_gray);
    rl.drawRectangleLines(x, y, w, h, if (focused) .sky_blue else .gray);

    var disp: [max_field + 1:0]u8 = std.mem.zeroes([max_field + 1:0]u8);
    if (f.masked) {
        @memset(disp[0..f.len], '*');
    } else {
        @memcpy(disp[0..f.len], f.buf[0..f.len]);
    }

    const fs = fsByHeight(h);
    const pad = @max(6, @divTrunc(h, 8));
    rl.drawText(&disp, x + pad, y + @divTrunc(h - fs, 2), fs, .dark_gray);

    if (focused) {
        const tw = rl.measureText(&disp, fs);
        rl.drawRectangle(x + pad + tw, y + @divTrunc(h, 6), 2, @divTrunc(h * 2, 3), .sky_blue);
    }
}

fn inRect(mx: f32, my: f32, x: i32, y: i32, w: i32, h: i32) bool {
    return mx >= @as(f32, @floatFromInt(x)) and
        mx < @as(f32, @floatFromInt(x + w)) and
        my >= @as(f32, @floatFromInt(y)) and
        my < @as(f32, @floatFromInt(y + h));
}

// ---- Draw helpers ----

fn drawSlice(text: []const u8, x: i32, y: i32, fs: i32, color: rl.Color) void {
    var buf: [512:0]u8 = undefined;
    const n = @min(text.len, 511);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    rl.drawText(&buf, x, y, fs, color);
}

fn drawButton(label: [:0]const u8, x: i32, y: i32, w: i32, h: i32, color: rl.Color) void {
    rl.drawRectangle(x, y, w, h, color);
    const fs = fsByHeight(h);
    const tw = rl.measureText(label, fs);
    rl.drawText(label, x + @divTrunc(w - tw, 2), y + @divTrunc(h - fs, 2), fs, .white);
}

// ---- Responsive layout ----
//
// All values scale with screen width so the UI looks right on any phone.
// Design reference: 480 × 854 (portrait, 1x density).
//
const Layout = struct {
    hdr_h: i32, // top header / nav-bar height
    row_h: i32, // list row height (browser)
    pad: i32, // general padding
    fh: i32, // form field height
    btn_h: i32, // standard button height
    fs_hdr: i32, // header font size
    fs_body: i32, // body / value font size
    fs_label: i32, // field label font size
    fs_small: i32, // hint / secondary font size
    detail_row_h: i32, // detail view row height
    label_w: i32, // label column width in detail view

    fn compute(sw: i32) Layout {
        return .{
            .hdr_h = @divTrunc(sw, 8), //  60 @ 480
            .row_h = @divTrunc(sw, 6), //  80 @ 480
            .pad = @max(12, @divTrunc(sw, 30)), //  16 @ 480
            .fh = @divTrunc(sw, 9), //  53 @ 480
            .btn_h = @divTrunc(sw, 8), //  60 @ 480
            .fs_hdr = @divTrunc(sw, 17), //  28 @ 480
            .fs_body = @divTrunc(sw, 24), //  20 @ 480
            .fs_label = @divTrunc(sw, 30), //  16 @ 480
            .fs_small = @divTrunc(sw, 38), //  12 @ 480
            .detail_row_h = @divTrunc(sw * 3, 16), //  90 @ 480
            .label_w = @divTrunc(sw, 3), // 160 @ 480
        };
    }
};

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

// ---- Edit field metadata ----

const edit_field_labels = [7][:0]const u8{
    "Title", "Path", "Desc", "URL", "Username", "Password", "Notes",
};
const EDIT_PW_IDX: usize = 5;

// ---- App phases ----

const Phase = enum { unlock, browser, detail, edit, sync_setup, sync_running, sync_result };

// ---- DB open + row population ----

const OpenError = error{ StorageError, WrongPassword, OpenFailed, OutOfMemory };

fn openDbAndPopulate(
    allocator: std.mem.Allocator,
    db_out: *?loki.Database,
    rows: *std.ArrayListUnmanaged(BrowserRow),
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

fn repopulateRows(
    allocator: std.mem.Allocator,
    db: *loki.Database,
    rows: *std.ArrayListUnmanaged(BrowserRow),
) !void {
    for (rows.items) |r| r.deinit(allocator);
    rows.clearRetainingCapacity();
    for (db.listEntries()) |ie| {
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
    // Portrait window for desktop preview; on Android the OS sets the size.
    rl.initWindow(720, 1280, "Loki");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var phase: Phase = if (dbDirExists()) .unlock else .sync_setup;

    // ---- Unlock ----
    var unlock_pw = TextField{ .masked = true };
    var unlock_err: ?[:0]const u8 = null;
    var unlock_dialog_shown = false;

    // ---- DB + browser ----
    var db: ?loki.Database = null;
    var rows: std.ArrayListUnmanaged(BrowserRow) = .{};
    var browser_scroll: f32 = 0;

    // ---- Detail ----
    var detail_entry: ?loki.Entry = null;
    var detail_entry_id: [20]u8 = undefined;
    var detail_head_hash: [20]u8 = undefined;
    var detail_show_pw = false;
    var detail_scroll: f32 = 0;

    // ---- Edit ----
    var edit_fields: [7]TextField = undefined;
    var edit_pending: ?usize = null; // Android: index of field with an open dialog
    var edit_err: ?[:0]const u8 = null;
    var edit_focus: usize = 0; // desktop: focused field index
    var edit_scroll: f32 = 0;

    // ---- Sync ----
    var ip_field = TextField{};
    ip_field.setDefault("192.168.1.100");
    // P2.4: load persisted IP (overwrites default if file exists).
    load_prefs: {
        var base = openBaseDir() catch break :load_prefs;
        defer if (comptime is_android) base.close();
        loadPrefs(base, &ip_field);
    }
    var sync_pw_field = TextField{ .masked = true };
    var sync_focus_ip = true;
    var sync_err: ?[:0]const u8 = null;
    var sync_pending_field: ?bool = null; // true=ip dialog, false=pw dialog (Android)
    var first_use = (phase == .sync_setup);
    var delete_db_err: ?[:0]const u8 = null;
    var sync_from_browser = false; // P1.2: track if sync_setup was opened from browser
    var delete_confirm_pending = false; // P1.3: two-tap confirmation for Delete DB
    var delete_confirm_timer: f32 = 0; // P1.3: counts down from 3s

    // ---- Create / Delete / Clipboard ----
    var edit_is_new = false; // P2.2: true when creating a new entry
    var detail_delete_confirm_pending = false; // P2.3: two-tap delete confirm
    var detail_delete_confirm_timer: f32 = 0; // P2.3: counts down from 3s
    var copy_feedback_timer: f32 = 0; // P2.1: "Copied!" toast countdown

    // Tap detection: a release with < 10px of accumulated Y drag is a tap.
    var drag_accum: f32 = 0;

    // Index of the "Password" field in the detail view field array.
    const DETAIL_PW_IDX: i32 = 5;

    defer {
        if (detail_entry) |e| e.deinit(allocator);
        for (rows.items) |r| r.deinit(allocator);
        rows.deinit(allocator);
        if (db) |*d| d.deinit();
    }

    while (!rl.windowShouldClose()) {
        const sw = rl.getScreenWidth();
        const sh = rl.getScreenHeight();
        const L = Layout.compute(sw);

        const mouse = rl.getMousePosition();
        const mx = mouse.x;
        const my = mouse.y;

        if (rl.isMouseButtonPressed(.left)) drag_accum = 0;
        if (rl.isMouseButtonDown(.left)) drag_accum += @abs(rl.getMouseDelta().y);
        const is_tap = rl.isMouseButtonReleased(.left) and drag_accum < 10;

        // P1.3: tick delete-confirm countdown
        if (delete_confirm_pending) {
            delete_confirm_timer -= rl.getFrameTime();
            if (delete_confirm_timer <= 0) {
                delete_confirm_pending = false;
                delete_confirm_timer = 0;
            }
        }
        // P2.3: tick detail delete-confirm countdown
        if (detail_delete_confirm_pending) {
            detail_delete_confirm_timer -= rl.getFrameTime();
            if (detail_delete_confirm_timer <= 0) {
                detail_delete_confirm_pending = false;
                detail_delete_confirm_timer = 0;
            }
        }
        // P2.1: tick copy feedback
        if (copy_feedback_timer > 0) copy_feedback_timer -= rl.getFrameTime();

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
                        };
                        if (db != null) {
                            browser_scroll = 0;
                            phase = .browser;
                        }
                    } else if (poll < 0) {
                        unlock_dialog_shown = false;
                        unlock_err = "Cancelled. Tap to retry.";
                    } else if (is_tap and !unlock_dialog_shown) {
                        unlock_pw.showDialog("Enter password", true);
                        unlock_dialog_shown = true;
                        unlock_err = null;
                    }
                } else {
                    if (rl.isKeyPressed(.backspace)) unlock_pw.pop();
                    var ch = rl.getCharPressed();
                    while (ch != 0) : (ch = rl.getCharPressed()) {
                        if (ch >= 32 and ch < 127) unlock_pw.append(@intCast(ch));
                    }

                    const btn_w = sw - 2 * L.pad;
                    const btn_y = @divTrunc(sh * 3, 5);
                    const open_pressed = rl.isKeyPressed(.enter) or
                        (is_tap and inRect(mx, my, L.pad, btn_y, btn_w, L.btn_h));
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
                const content_h: f32 = @floatFromInt(@as(i32, @intCast(rows.items.len)) * L.row_h);
                const visible_h: f32 = @floatFromInt(sh - L.hdr_h);
                browser_scroll = std.math.clamp(browser_scroll, 0, @max(0, content_h - visible_h));

                if (is_tap) {
                    // Header buttons.
                    const hdr_btn_h = @divTrunc(L.btn_h, 2);
                    const hdr_btn_y = @divTrunc(L.hdr_h - hdr_btn_h, 2);
                    const sync_btn_w = @divTrunc(sw, 5);
                    const sync_btn_x = sw - sync_btn_w - L.pad;
                    const lock_btn_w = @divTrunc(sw, 6);
                    const lock_btn_x = sync_btn_x - lock_btn_w - L.pad;
                    // P2.2: "+" FAB at bottom-right.
                    const fab_size = @divTrunc(sw, 7);
                    const fab_x = sw - fab_size - L.pad;
                    const fab_y = sh - fab_size - L.pad;
                    if (inRect(mx, my, sync_btn_x, hdr_btn_y, sync_btn_w, hdr_btn_h)) {
                        first_use = false;
                        delete_db_err = null;
                        sync_err = null;
                        sync_from_browser = true;
                        delete_confirm_pending = false;
                        phase = .sync_setup;
                    } else if (inRect(mx, my, lock_btn_x, hdr_btn_y, lock_btn_w, hdr_btn_h)) {
                        // Lock: clear in-memory DB and return to unlock screen.
                        if (db) |*d| d.deinit();
                        db = null;
                        for (rows.items) |r| r.deinit(allocator);
                        rows.clearRetainingCapacity();
                        if (detail_entry) |e| e.deinit(allocator);
                        detail_entry = null;
                        unlock_pw = TextField{ .masked = true };
                        unlock_err = null;
                        unlock_dialog_shown = false;
                        phase = .unlock;
                    } else if (inRect(mx, my, fab_x, fab_y, fab_size, fab_size)) {
                        // New entry.
                        for (0..7) |fi| edit_fields[fi] = TextField{ .masked = fi == EDIT_PW_IDX };
                        edit_is_new = true;
                        edit_pending = null;
                        edit_err = null;
                        edit_focus = 0;
                        edit_scroll = 0;
                        phase = .edit;
                    }
                    // Row tap → detail.
                    else if (my >= @as(f32, @floatFromInt(L.hdr_h))) {
                        const rel_y = @as(i32, @intFromFloat(my)) - L.hdr_h +
                            @as(i32, @intFromFloat(browser_scroll));
                        const idx_i = @divTrunc(rel_y, L.row_h);
                        if (idx_i >= 0 and idx_i < @as(i32, @intCast(rows.items.len))) {
                            const idx: usize = @intCast(idx_i);
                            if (db) |*d| {
                                if (detail_entry) |e| e.deinit(allocator);
                                detail_entry = d.getEntry(rows.items[idx].entry_id) catch null;
                                detail_entry_id = rows.items[idx].entry_id;
                                detail_head_hash = rows.items[idx].head_hash;
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
                const del_btn_h = L.btn_h;
                const del_btn_y = sh - del_btn_h - L.pad;
                if (is_tap) {
                    // Back: left third of header.
                    if (inRect(mx, my, 0, 0, @divTrunc(sw, 3), L.hdr_h)) {
                        detail_delete_confirm_pending = false;
                        phase = .browser;
                    }
                    // Edit: right third of header.
                    else if (inRect(mx, my, sw - @divTrunc(sw, 3), 0, @divTrunc(sw, 3), L.hdr_h)) {
                        if (detail_entry) |e| {
                            const vals = [7][]const u8{
                                e.title, e.path,     e.description,
                                e.url,   e.username, e.password,
                                e.notes,
                            };
                            for (0..7) |fi| {
                                edit_fields[fi] = TextField{ .masked = fi == EDIT_PW_IDX };
                                edit_fields[fi].setDefault(vals[fi]);
                            }
                        }
                        edit_is_new = false;
                        edit_pending = null;
                        edit_err = null;
                        edit_focus = 0;
                        edit_scroll = 0;
                        phase = .edit;
                    }
                    // P2.3: Delete button (pinned bottom).
                    else if (inRect(mx, my, L.pad, del_btn_y, sw - 2 * L.pad, del_btn_h)) {
                        if (detail_delete_confirm_pending) {
                            if (db) |*d| {
                                d.deleteEntry(detail_entry_id) catch {};
                                d.save() catch {};
                                repopulateRows(allocator, d, &rows) catch {};
                            }
                            if (detail_entry) |e| e.deinit(allocator);
                            detail_entry = null;
                            detail_delete_confirm_pending = false;
                            phase = .browser;
                        } else {
                            detail_delete_confirm_pending = true;
                            detail_delete_confirm_timer = 3.0;
                        }
                    }
                    // Show/hide password toggle (right side of the password row).
                    else {
                        const scroll_i: i32 = @intFromFloat(detail_scroll);
                        const toggle_w = @divTrunc(sw, 5);
                        const pw_row_y = L.hdr_h + L.pad + DETAIL_PW_IDX * L.detail_row_h - scroll_i;
                        if (inRect(mx, my, sw - toggle_w - L.pad, pw_row_y, toggle_w, L.detail_row_h)) {
                            detail_show_pw = !detail_show_pw;
                        }
                        // P2.1: tap any field row → copy value to clipboard.
                        else if (my >= @as(f32, @floatFromInt(L.hdr_h)) and
                            my < @as(f32, @floatFromInt(del_btn_y)))
                        {
                            if (detail_entry) |e| {
                                const vals = [7][]const u8{
                                    e.title, e.path,     e.description,
                                    e.url,   e.username, e.password,
                                    e.notes,
                                };
                                for (0..7) |fi| {
                                    const fy = L.hdr_h + L.pad + @as(i32, @intCast(fi)) * L.detail_row_h - scroll_i;
                                    if (inRect(mx, my, 0, fy, sw, L.detail_row_h)) {
                                        var cbuf: [max_field + 1:0]u8 = std.mem.zeroes([max_field + 1:0]u8);
                                        const n = @min(vals[fi].len, max_field);
                                        @memcpy(cbuf[0..n], vals[fi][0..n]);
                                        rl.setClipboardText(&cbuf);
                                        copy_feedback_timer = 1.5;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }
            },

            // ---- Edit --------------------------------------------------
            .edit => {
                // Scroll handling.
                if (rl.isMouseButtonDown(.left)) {
                    edit_scroll -= rl.getMouseDelta().y;
                }
                const edit_content_h: f32 = @floatFromInt(7 * L.detail_row_h);
                const edit_visible_h: f32 = @floatFromInt(sh - L.hdr_h);
                edit_scroll = std.math.clamp(edit_scroll, 0, @max(0, edit_content_h - edit_visible_h));

                if (comptime is_android) {
                    // Poll for result from an open dialog.
                    if (edit_pending) |fi| {
                        var rbuf: [max_field + 1]u8 = undefined;
                        const r = pollTextInputDialog(&rbuf, @intCast(rbuf.len));
                        if (r > 0) {
                            const n: usize = @intCast(r);
                            edit_fields[fi].len = n;
                            @memcpy(edit_fields[fi].buf[0..n], rbuf[0..n]);
                            edit_pending = null;
                        } else if (r < 0) {
                            edit_pending = null;
                        }
                    }
                    // Tap a field row to open its dialog.
                    if (is_tap and edit_pending == null) {
                        const scroll_i: i32 = @intFromFloat(edit_scroll);
                        for (0..7) |fi| {
                            const fy = L.hdr_h + @as(i32, @intCast(fi)) * L.detail_row_h - scroll_i;
                            if (fy >= L.hdr_h and inRect(mx, my, 0, fy, sw, L.detail_row_h)) {
                                edit_fields[fi].showDialog(edit_field_labels[fi].ptr, fi == EDIT_PW_IDX);
                                edit_pending = fi;
                                edit_err = null;
                                break;
                            }
                        }
                    }
                } else {
                    // Desktop: Tab cycles focus, keyboard types into active field.
                    if (rl.isKeyPressed(.tab)) edit_focus = (edit_focus + 1) % 7;
                    if (rl.isKeyPressed(.backspace)) edit_fields[edit_focus].pop();
                    var ch = rl.getCharPressed();
                    while (ch != 0) : (ch = rl.getCharPressed()) {
                        if (ch >= 32 and ch < 127) edit_fields[edit_focus].append(@intCast(ch));
                    }
                    // Click a row to focus it.
                    if (is_tap) {
                        const scroll_i: i32 = @intFromFloat(edit_scroll);
                        for (0..7) |fi| {
                            const fy = L.hdr_h + @as(i32, @intCast(fi)) * L.detail_row_h - scroll_i;
                            if (inRect(mx, my, 0, fy, sw, L.detail_row_h)) {
                                edit_focus = fi;
                                break;
                            }
                        }
                    }
                    if (rl.isKeyPressed(.escape)) phase = .detail;
                }

                // Cancel / Save header buttons (both platforms).
                const hdr_btn_w = @divTrunc(sw, 4);
                if (is_tap) {
                    if (inRect(mx, my, 0, 0, hdr_btn_w, L.hdr_h)) {
                        edit_err = null;
                        phase = .detail;
                    }
                }
                const do_save = is_tap and inRect(mx, my, sw - hdr_btn_w, 0, hdr_btn_w, L.hdr_h);
                const do_save_key = if (comptime !is_android) rl.isKeyPressed(.enter) else false;
                if (do_save or do_save_key) save: {
                    const d = if (db) |*d_| d_ else {
                        edit_err = "No database.";
                        break :save;
                    };
                    const new_entry = loki.Entry{
                        .parent_hash = if (edit_is_new) null else detail_head_hash,
                        .title = edit_fields[0].slice(),
                        .path = edit_fields[1].slice(),
                        .description = edit_fields[2].slice(),
                        .url = edit_fields[3].slice(),
                        .username = edit_fields[4].slice(),
                        .password = edit_fields[5].slice(),
                        .notes = edit_fields[6].slice(),
                    };
                    if (edit_is_new) {
                        // P2.2: create new entry, land in browser.
                        _ = d.createEntry(new_entry) catch {
                            edit_err = "Save failed.";
                            break :save;
                        };
                        d.save() catch {
                            edit_err = "Save failed.";
                            break :save;
                        };
                        repopulateRows(allocator, d, &rows) catch {
                            edit_err = "Save failed.";
                            break :save;
                        };
                        browser_scroll = 0;
                        phase = .browser;
                    } else {
                        // Update existing entry.
                        _ = d.updateEntry(detail_entry_id, new_entry) catch {
                            edit_err = "Save failed.";
                            break :save;
                        };
                        d.save() catch {
                            edit_err = "Save failed.";
                            break :save;
                        };
                        repopulateRows(allocator, d, &rows) catch {
                            edit_err = "Save failed.";
                            break :save;
                        };
                        // P2.5: return to detail with refreshed data.
                        if (detail_entry) |e| e.deinit(allocator);
                        detail_entry = d.getEntry(detail_entry_id) catch null;
                        for (rows.items) |r| {
                            if (std.mem.eql(u8, &r.entry_id, &detail_entry_id)) {
                                detail_head_hash = r.head_hash;
                                break;
                            }
                        }
                        phase = .detail;
                    }
                }
            },

            // ---- Sync setup --------------------------------------------
            .sync_setup => {
                // Portrait form layout — must match the draw section exactly.
                // When entered from browser a header is shown; shift form down.
                const form_top = if (sync_from_browser) L.hdr_h + L.pad else L.pad * 2;
                const fw = sw - 2 * L.pad;
                const title_y = form_top;
                const sub_y = title_y + L.fs_hdr + L.pad;
                const ip_label_y = sub_y + L.fs_label + L.pad * 2;
                const ip_field_y = ip_label_y + L.fs_label + 6;
                const pw_label_y = ip_field_y + L.fh + L.pad;
                const pw_field_y = pw_label_y + L.fs_label + 6;
                const submit_btn_y = pw_field_y + L.fh + L.pad * 2;
                const del_btn_y = submit_btn_y + L.btn_h + L.pad;

                // P1.2: Back button in header when entered from browser.
                if (sync_from_browser and is_tap and inRect(mx, my, 0, 0, @divTrunc(sw, 3), L.hdr_h)) {
                    sync_from_browser = false;
                    phase = .browser;
                }

                // Guard: don't open a new dialog while one is already pending.
                if (rl.isMouseButtonPressed(.left) and sync_pending_field == null) {
                    if (inRect(mx, my, L.pad, ip_field_y, fw, L.fh)) {
                        sync_focus_ip = true;
                        if (comptime is_android) {
                            ip_field.showDialog("Server IP", false);
                            sync_pending_field = true;
                        }
                    } else if (inRect(mx, my, L.pad, pw_field_y, fw, L.fh)) {
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

                // P1.3: Delete DB button — two-tap confirmation.
                if (!first_use and is_tap and inRect(mx, my, L.pad, del_btn_y, fw, L.btn_h)) {
                    if (delete_confirm_pending) {
                        // Second tap: actually delete.
                        if (db) |*d| d.deinit();
                        db = null;
                        for (rows.items) |r| r.deinit(allocator);
                        rows.clearRetainingCapacity();
                        if (deleteDb()) {
                            first_use = true;
                            delete_db_err = null;
                            sync_err = null;
                            sync_from_browser = false;
                        } else {
                            delete_db_err = "Failed to delete database.";
                        }
                        delete_confirm_pending = false;
                    } else {
                        // First tap: arm confirmation.
                        delete_confirm_pending = true;
                        delete_confirm_timer = 3.0;
                    }
                }

                // Sync / Fetch button.
                const clicked_submit = rl.isMouseButtonPressed(.left) and
                    inRect(mx, my, L.pad, submit_btn_y, fw, L.btn_h);
                if (clicked_submit or rl.isKeyPressed(.enter)) {
                    if (ip_field.len == 0 or sync_pw_field.len == 0) {
                        sync_err = "Please enter IP and password.";
                    } else {
                        @memcpy(g_ip[0..ip_field.len], ip_field.buf[0..ip_field.len]);
                        g_ip_len = ip_field.len;
                        @memcpy(g_pw[0..sync_pw_field.len], sync_pw_field.buf[0..sync_pw_field.len]);
                        g_pw_len = sync_pw_field.len;
                        g_status.store(.connecting, .release);
                        // P2.4: persist the IP before launching.
                        save_prefs: {
                            var base = openBaseDir() catch break :save_prefs;
                            defer if (comptime is_android) base.close();
                            savePrefs(base, ip_field.slice());
                        }
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
                if (s == .done) {
                    // Auto-open with the sync password so the user lands
                    // directly in the browser without a second password entry.
                    openDbAndPopulate(allocator, &db, &rows, sync_pw_field.slice()) catch {};
                    if (db != null) {
                        browser_scroll = 0;
                        phase = .browser;
                    } else {
                        // Auto-open failed (shouldn't happen) — fall back to
                        // the result screen where the user can tap "Open DB".
                        phase = .sync_result;
                    }
                } else if (s == .failed) {
                    phase = .sync_result;
                }
            },

            .sync_result => {
                const btn_y = sh - L.btn_h - L.pad;
                const status = g_status.load(.acquire);
                if (status == .done) {
                    if (is_tap and inRect(mx, my, L.pad, btn_y, sw - 2 * L.pad, L.btn_h)) {
                        unlock_pw = TextField{ .masked = true };
                        unlock_err = null;
                        unlock_dialog_shown = false;
                        phase = .unlock;
                    }
                } else if (status == .failed) {
                    // P1.1: Back and Retry buttons on failure.
                    const half_w = @divTrunc(sw - 3 * L.pad, 2);
                    if (is_tap and inRect(mx, my, L.pad, btn_y, half_w, L.btn_h)) {
                        // Back → sync_setup
                        sync_err = null;
                        phase = .sync_setup;
                    } else if (is_tap and inRect(mx, my, 2 * L.pad + half_w, btn_y, half_w, L.btn_h)) {
                        // Retry → spawn new syncThread
                        g_status.store(.connecting, .release);
                        if (std.Thread.spawn(.{}, syncThread, .{})) |thread| {
                            thread.detach();
                            phase = .sync_running;
                        } else |_| {
                            sync_err = "Failed to start sync thread.";
                            phase = .sync_setup;
                        }
                    }
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
                // App name centered near top third.
                const title_y = @divTrunc(sh, 6);
                const title_tw = rl.measureText("Loki", L.fs_hdr * 2);
                rl.drawText("Loki", @divTrunc(sw - title_tw, 2), title_y, L.fs_hdr * 2, .white);

                const sub = "Enter password to open your database.";
                const sub_tw = rl.measureText(sub, L.fs_label);
                rl.drawText(sub, @divTrunc(sw - sub_tw, 2), title_y + L.fs_hdr * 2 + L.pad, L.fs_label, .gray);

                // Password field in the middle.
                const field_y = @divTrunc(sh * 2, 5);
                const fw = sw - 2 * L.pad;
                drawTextField(&unlock_pw, L.pad, field_y, fw, L.fh, true);

                if (unlock_err) |msg| {
                    const etw = rl.measureText(msg, L.fs_label);
                    rl.drawText(msg, @divTrunc(sw - etw, 2), field_y + L.fh + L.pad, L.fs_label, .orange);
                }

                if (comptime !is_android) {
                    const btn_y = @divTrunc(sh * 3, 5);
                    drawButton("Open", L.pad, btn_y, fw, L.btn_h, .{ .r = 30, .g = 140, .b = 200, .a = 255 });
                    rl.drawText("Enter: open", L.pad, sh - L.fs_small - L.pad, L.fs_small, .dark_gray);
                }
            },

            // ---- Browser -----------------------------------------------
            .browser => {
                // Draw rows first so the header can paint over any overflow.
                const list_top = L.hdr_h;
                for (rows.items, 0..) |row, i| {
                    const row_y = list_top + @as(i32, @intCast(i)) * L.row_h -
                        @as(i32, @intFromFloat(browser_scroll));
                    if (row_y + L.row_h <= list_top or row_y > sh) continue;

                    const bg: rl.Color = if (i % 2 == 0)
                        .{ .r = 18, .g = 18, .b = 28, .a = 255 }
                    else
                        .{ .r = 24, .g = 24, .b = 36, .a = 255 };
                    rl.drawRectangle(0, row_y, sw, L.row_h, bg);

                    // Only draw text if the row is at least partially below the header.
                    if (row_y >= list_top) {
                        const text_block_h = if (row.path.len > 0)
                            L.fs_body + @divTrunc(L.pad, 2) + L.fs_small
                        else
                            L.fs_body;
                        const text_y = row_y + @divTrunc(L.row_h - text_block_h, 2);

                        drawSlice(row.title, L.pad, text_y, L.fs_body, .white);
                        if (row.path.len > 0) {
                            drawSlice(row.path, L.pad, text_y + L.fs_body + @divTrunc(L.pad, 2), L.fs_small, .gray);
                        }

                        rl.drawText(">", sw - L.pad - L.fs_body, row_y + @divTrunc(L.row_h - L.fs_body, 2), L.fs_body, .dark_gray);
                    }

                    rl.drawRectangle(0, row_y + L.row_h - 1, sw, 1, .{ .r = 40, .g = 40, .b = 55, .a = 255 });
                }

                if (rows.items.len == 0) {
                    rl.drawText("No entries.", L.pad, L.hdr_h + L.pad, L.fs_body, .gray);
                }

                // Header drawn last so it always covers scrolled row content.
                rl.drawRectangle(0, 0, sw, L.hdr_h, .{ .r = 20, .g = 20, .b = 30, .a = 255 });
                rl.drawText("Loki", L.pad, @divTrunc(L.hdr_h - L.fs_hdr, 2), L.fs_hdr, .white);

                const hdr_btn_h = @divTrunc(L.btn_h, 2);
                const hdr_btn_y = @divTrunc(L.hdr_h - hdr_btn_h, 2);
                const sync_btn_w = @divTrunc(sw, 5);
                const sync_btn_x = sw - sync_btn_w - L.pad;
                const lock_btn_w = @divTrunc(sw, 6);
                const lock_btn_x = sync_btn_x - lock_btn_w - L.pad;
                drawButton("Sync", sync_btn_x, hdr_btn_y, sync_btn_w, hdr_btn_h, .{ .r = 30, .g = 130, .b = 180, .a = 255 });
                drawButton("Lock", lock_btn_x, hdr_btn_y, lock_btn_w, hdr_btn_h, .{ .r = 70, .g = 70, .b = 90, .a = 255 });

                // P2.2: "+" FAB button.
                const fab_size = @divTrunc(sw, 7);
                const fab_x = sw - fab_size - L.pad;
                const fab_y = sh - fab_size - L.pad;
                drawButton("+", fab_x, fab_y, fab_size, fab_size, .{ .r = 0, .g = 135, .b = 190, .a = 255 });
            },

            // ---- Detail ------------------------------------------------
            .detail => {
                const entry = detail_entry orelse {
                    rl.drawText("No entry loaded.", L.pad, L.hdr_h + L.pad, L.fs_body, .gray);
                    return;
                };

                // Draw fields first; header paints over any scroll overflow below.
                const scroll_i: i32 = @intFromFloat(detail_scroll);
                const val_x = L.label_w + L.pad;
                const toggle_w = @divTrunc(sw, 5);

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
                    const fy = L.hdr_h + L.pad + @as(i32, @intCast(fi)) * L.detail_row_h - scroll_i;
                    if (fy + L.detail_row_h < L.hdr_h or fy > sh) continue;

                    const bg: rl.Color = if (fi % 2 == 0)
                        .{ .r = 18, .g = 18, .b = 28, .a = 255 }
                    else
                        .{ .r = 26, .g = 26, .b = 38, .a = 255 };
                    rl.drawRectangle(0, fy, sw, L.detail_row_h, bg);

                    // Label (left column, dimmed).
                    drawSlice(f.label, L.pad, fy + @divTrunc(L.detail_row_h - L.fs_label, 2), L.fs_label, .gray);

                    // Value (right column).
                    const val_y = fy + @divTrunc(L.detail_row_h - L.fs_body, 2);
                    const is_pw = fi == DETAIL_PW_IDX;

                    if (is_pw and !detail_show_pw) {
                        var stars: [64:0]u8 = undefined;
                        const n = @min(f.value.len, 63);
                        @memset(stars[0..n], '*');
                        stars[n] = 0;
                        rl.drawText(&stars, val_x, val_y, L.fs_body, .white);
                    } else if (is_pw and detail_show_pw) {
                        drawSlice(f.value, val_x, val_y, L.fs_body, .{ .r = 255, .g = 200, .b = 100, .a = 255 });
                    } else {
                        drawSlice(f.value, val_x, val_y, L.fs_body, .white);
                    }

                    // Show/Hide toggle button (password row only).
                    if (is_pw) {
                        const toggle_h = @divTrunc(L.detail_row_h * 2, 3);
                        const toggle_label: [:0]const u8 = if (detail_show_pw) "Hide" else "Show";
                        drawButton(toggle_label, sw - toggle_w - L.pad, fy + @divTrunc(L.detail_row_h - toggle_h, 2), toggle_w, toggle_h, .{ .r = 60, .g = 60, .b = 90, .a = 255 });
                    }

                    rl.drawRectangle(0, fy + L.detail_row_h - 1, sw, 1, .{ .r = 40, .g = 40, .b = 55, .a = 255 });
                }

                // P2.3: Delete button pinned at bottom.
                const del_btn_h = L.btn_h;
                const del_btn_y = sh - del_btn_h - L.pad;
                if (detail_delete_confirm_pending) {
                    drawButton("Tap again to confirm delete", L.pad, del_btn_y, sw - 2 * L.pad, del_btn_h, .{ .r = 220, .g = 30, .b = 30, .a = 255 });
                } else {
                    drawButton("Delete", L.pad, del_btn_y, sw - 2 * L.pad, del_btn_h, .{ .r = 160, .g = 40, .b = 40, .a = 255 });
                }

                // P2.1: "Copied!" toast.
                if (copy_feedback_timer > 0) {
                    const toast = "Copied!";
                    const ttw = rl.measureText(toast, L.fs_body);
                    const toast_pad = L.pad * 2;
                    const toast_w = ttw + toast_pad * 2;
                    const toast_h = L.fs_body + toast_pad;
                    const toast_x = @divTrunc(sw - toast_w, 2);
                    const toast_y = del_btn_y - toast_h - L.pad;
                    rl.drawRectangle(toast_x, toast_y, toast_w, toast_h, .{ .r = 30, .g = 30, .b = 30, .a = 220 });
                    rl.drawText(toast, toast_x + toast_pad, toast_y + @divTrunc(toast_pad, 2), L.fs_body, .white);
                }

                if (comptime !is_android) {
                    rl.drawText("h: pw  Esc: back", L.pad, sh - L.fs_small - L.pad - del_btn_h - L.pad, L.fs_small, .dark_gray);
                }

                // Header drawn last so it covers any field rows that scroll up into it.
                rl.drawRectangle(0, 0, sw, L.hdr_h, .{ .r = 20, .g = 20, .b = 30, .a = 255 });
                rl.drawText("< Back", L.pad, @divTrunc(L.hdr_h - L.fs_body, 2), L.fs_body, .sky_blue);
                const edit_lbl_tw = rl.measureText("Edit", L.fs_body);
                rl.drawText("Edit", sw - edit_lbl_tw - L.pad, @divTrunc(L.hdr_h - L.fs_body, 2), L.fs_body, .sky_blue);
            },

            // ---- Edit --------------------------------------------------
            .edit => {
                const scroll_i: i32 = @intFromFloat(edit_scroll);
                const val_x = L.label_w + L.pad;

                // Draw field rows first; header paints over any scroll overflow.
                for (0..7) |fi| {
                    const fy = L.hdr_h + @as(i32, @intCast(fi)) * L.detail_row_h - scroll_i;
                    if (fy + L.detail_row_h <= L.hdr_h or fy > sh) continue;

                    const is_focused = (comptime !is_android) and fi == edit_focus;
                    const bg: rl.Color = if (is_focused)
                        .{ .r = 22, .g = 30, .b = 48, .a = 255 }
                    else if (fi % 2 == 0)
                        .{ .r = 18, .g = 18, .b = 28, .a = 255 }
                    else
                        .{ .r = 26, .g = 26, .b = 38, .a = 255 };
                    rl.drawRectangle(0, fy, sw, L.detail_row_h, bg);

                    if (fy >= L.hdr_h) {
                        // Label.
                        drawSlice(edit_field_labels[fi], L.pad, fy + @divTrunc(L.detail_row_h - L.fs_label, 2), L.fs_label, .gray);

                        // Value (masked for password when not focused or Android).
                        const show_plain = fi != EDIT_PW_IDX or
                            (!is_android and fi == edit_focus);
                        if (show_plain) {
                            const val_y = fy + @divTrunc(L.detail_row_h - L.fs_body, 2);
                            var dbuf: [max_field + 1:0]u8 = std.mem.zeroes([max_field + 1:0]u8);
                            const n = edit_fields[fi].len;
                            @memcpy(dbuf[0..n], edit_fields[fi].buf[0..n]);
                            rl.drawText(&dbuf, val_x, val_y, L.fs_body, .white);
                            // Cursor for focused field on desktop.
                            if (is_focused) {
                                const tw = rl.measureText(&dbuf, L.fs_body);
                                rl.drawRectangle(val_x + tw, val_y, 2, L.fs_body, .sky_blue);
                            }
                        } else {
                            var stars: [64:0]u8 = undefined;
                            const n = @min(edit_fields[fi].len, 63);
                            @memset(stars[0..n], '*');
                            stars[n] = 0;
                            rl.drawText(&stars, val_x, fy + @divTrunc(L.detail_row_h - L.fs_body, 2), L.fs_body, .white);
                        }

                        // Edit indicator (tap hint on Android).
                        if (comptime is_android) {
                            rl.drawText(">", sw - L.pad - L.fs_body, fy + @divTrunc(L.detail_row_h - L.fs_body, 2), L.fs_body, .dark_gray);
                        }
                    }

                    rl.drawRectangle(0, fy + L.detail_row_h - 1, sw, 1, .{ .r = 40, .g = 40, .b = 55, .a = 255 });
                }

                if (edit_err) |msg| {
                    const ey = sh - L.fs_label - L.pad;
                    rl.drawText(msg, L.pad, ey, L.fs_label, .orange);
                }

                // Header drawn last.
                const hdr_btn_w = @divTrunc(sw, 4);
                rl.drawRectangle(0, 0, sw, L.hdr_h, .{ .r = 20, .g = 20, .b = 30, .a = 255 });
                rl.drawText("Cancel", L.pad, @divTrunc(L.hdr_h - L.fs_body, 2), L.fs_body, .sky_blue);
                const save_tw = rl.measureText("Save", L.fs_body);
                rl.drawText("Save", sw - hdr_btn_w + @divTrunc(hdr_btn_w - save_tw, 2), @divTrunc(L.hdr_h - L.fs_body, 2), L.fs_body, .{ .r = 80, .g = 200, .b = 100, .a = 255 });

                if (comptime !is_android) {
                    rl.drawText("Tab: next field   Enter: save   Esc: cancel", L.pad, sh - L.fs_small - L.pad, L.fs_small, .dark_gray);
                }
            },

            // ---- Sync setup --------------------------------------------
            .sync_setup => {
                // Portrait vertical form layout — matches input section exactly.
                const form_top = if (sync_from_browser) L.hdr_h + L.pad else L.pad * 2;
                const fw = sw - 2 * L.pad;
                const title_y = form_top;
                const sub_y = title_y + L.fs_hdr + L.pad;
                const ip_label_y = sub_y + L.fs_label + L.pad * 2;
                const ip_field_y = ip_label_y + L.fs_label + 6;
                const pw_label_y = ip_field_y + L.fh + L.pad;
                const pw_field_y = pw_label_y + L.fs_label + 6;
                const submit_btn_y = pw_field_y + L.fh + L.pad * 2;
                const del_btn_y = submit_btn_y + L.btn_h + L.pad;

                rl.drawText("Loki Sync", L.pad, title_y, L.fs_hdr, .white);

                const subtitle: [:0]const u8 = if (first_use)
                    "First use: fetch the database from server"
                else
                    "Sync database with server";
                rl.drawText(subtitle, L.pad, sub_y, L.fs_label, .gray);

                rl.drawText("Server IP", L.pad, ip_label_y, L.fs_label, .light_gray);
                drawTextField(&ip_field, L.pad, ip_field_y, fw, L.fh, sync_focus_ip);

                rl.drawText("Password", L.pad, pw_label_y, L.fs_label, .light_gray);
                drawTextField(&sync_pw_field, L.pad, pw_field_y, fw, L.fh, !sync_focus_ip);

                const submit_label: [:0]const u8 = if (first_use) "Fetch" else "Sync";
                drawButton(submit_label, L.pad, submit_btn_y, fw, L.btn_h, .sky_blue);

                if (!first_use) {
                    if (delete_confirm_pending) {
                        // P1.3: show "Tap again to confirm" in bright red
                        drawButton("Tap again to confirm delete", L.pad, del_btn_y, fw, L.btn_h, .{ .r = 220, .g = 30, .b = 30, .a = 255 });
                    } else {
                        drawButton("Delete DB", L.pad, del_btn_y, fw, L.btn_h, .{ .r = 180, .g = 40, .b = 40, .a = 255 });
                    }
                }

                const err_y = del_btn_y + L.btn_h + L.pad;
                if (sync_err) |msg| rl.drawText(msg, L.pad, err_y, L.fs_label, .orange);
                if (delete_db_err) |msg| rl.drawText(msg, L.pad, err_y + L.fs_label + 4, L.fs_label, .red);

                if (comptime !is_android) {
                    rl.drawText("Tab: switch field   Enter: submit", L.pad, sh - L.fs_small - L.pad, L.fs_small, .dark_gray);
                }

                // P1.2: Back button in header when reached from browser.
                if (sync_from_browser) {
                    rl.drawRectangle(0, 0, sw, L.hdr_h, .{ .r = 20, .g = 20, .b = 30, .a = 255 });
                    rl.drawText("< Back", L.pad, @divTrunc(L.hdr_h - L.fs_body, 2), L.fs_body, .sky_blue);
                }
            },

            // ---- Sync running ------------------------------------------
            .sync_running => {
                rl.drawText("Loki Sync", L.pad, L.pad * 2, L.fs_hdr, .white);
                const status_text: [:0]const u8 = switch (g_status.load(.acquire)) {
                    .connecting => "Connecting... (10s timeout)",
                    .syncing => "Syncing...",
                    else => "Please wait...",
                };
                const stw = rl.measureText(status_text, L.fs_body);
                rl.drawText(status_text, @divTrunc(sw - stw, 2), @divTrunc(sh, 2), L.fs_body, .yellow);
            },

            // ---- Sync result -------------------------------------------
            .sync_result => {
                rl.drawText("Loki Sync", L.pad, L.pad * 2, L.fs_hdr, .white);
                const result_y = @divTrunc(sh, 4);
                const btn_y = sh - L.btn_h - L.pad;
                switch (g_status.load(.acquire)) {
                    .done => {
                        rl.drawText("Sync complete!", L.pad, result_y, L.fs_body, .green);
                        rl.drawText(&g_msg_buf, L.pad, result_y + L.fs_body + L.pad, L.fs_label, .green);
                        drawButton("Open DB", L.pad, btn_y, sw - 2 * L.pad, L.btn_h, .{ .r = 30, .g = 140, .b = 80, .a = 255 });
                    },
                    .failed => {
                        rl.drawText("Sync failed:", L.pad, result_y, L.fs_body, .red);
                        rl.drawText(&g_msg_buf, L.pad, result_y + L.fs_body + L.pad, L.fs_label, .red);
                        // P1.1: Back and Retry buttons.
                        const half_w = @divTrunc(sw - 3 * L.pad, 2);
                        drawButton("Back", L.pad, btn_y, half_w, L.btn_h, .{ .r = 70, .g = 70, .b = 90, .a = 255 });
                        drawButton("Retry", 2 * L.pad + half_w, btn_y, half_w, L.btn_h, .{ .r = 30, .g = 130, .b = 180, .a = 255 });
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
