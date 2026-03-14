//! App — all application state and per-frame update logic.
//! This file IS the App type: `const App = @import("App.zig");`

const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const loki = @import("loki");
const ui = @import("ui.zig");
const fs = @import("fs.zig");
const sync = @import("sync.zig");

const is_android = ui.is_android;
const Self = @This();

// ---- Per-frame context (screen dims, layout, mouse, tap) ----

const Ctx = struct {
    sw: i32,
    sh: i32,
    L: ui.Layout,
    mx: f32,
    my: f32,
    is_tap: bool,
};

// ---- Error set for DB open ----

const OpenError = error{ StorageError, WrongPassword, OpenFailed, OutOfMemory };

// ---- State ----

allocator: std.mem.Allocator,
phase: ui.Phase,
drag_accum: f32,

// Unlock
unlock_pw: ui.TextField,
unlock_err: ?[:0]const u8,
unlock_dialog_shown: bool,

// DB + browser
db: ?loki.Database,
rows: std.ArrayListUnmanaged(ui.BrowserRow),
browser_scroll: f32,

// Detail
detail_entry: ?loki.Entry,
detail_entry_id: [20]u8,
detail_head_hash: [20]u8,
detail_show_pw: bool,
detail_scroll: f32,
detail_delete_confirm_pending: bool,
detail_delete_confirm_timer: f32,

// Edit
edit_fields: [7]ui.TextField,
edit_pending: ?usize,
edit_err: ?[:0]const u8,
edit_focus: usize,
edit_scroll: f32,
edit_is_new: bool,
edit_show_pw: bool,

// Sync setup
ip_field: ui.TextField,
sync_pw_field: ui.TextField,
sync_focus_ip: bool,
sync_err: ?[:0]const u8,
sync_pending_field: ?bool,
first_use: bool,
delete_db_err: ?[:0]const u8,
sync_from_browser: bool,
delete_confirm_pending: bool,
delete_confirm_timer: f32,
sync_ip_err: bool,
sync_pw_err: bool,

// Search
search_field: ui.TextField,
search_pending: bool,
search_focused: bool,

// Clipboard toast
copy_feedback_timer: f32,

// ---- Lifecycle ----

pub fn init(allocator: std.mem.Allocator) Self {
    const initial_phase: ui.Phase = if (fs.dbDirExists()) .unlock else .sync_setup;
    var self = Self{
        .allocator = allocator,
        .phase = initial_phase,
        .drag_accum = 0,
        .unlock_pw = .{ .masked = true },
        .unlock_err = null,
        .unlock_dialog_shown = false,
        .db = null,
        .rows = .{},
        .browser_scroll = 0,
        .detail_entry = null,
        .detail_entry_id = undefined,
        .detail_head_hash = undefined,
        .detail_show_pw = false,
        .detail_scroll = 0,
        .detail_delete_confirm_pending = false,
        .detail_delete_confirm_timer = 0,
        .edit_fields = undefined,
        .edit_pending = null,
        .edit_err = null,
        .edit_focus = 0,
        .edit_scroll = 0,
        .edit_is_new = false,
        .edit_show_pw = false,
        .ip_field = .{},
        .sync_pw_field = .{ .masked = true },
        .sync_focus_ip = true,
        .sync_err = null,
        .sync_pending_field = null,
        .first_use = (initial_phase == .sync_setup),
        .delete_db_err = null,
        .sync_from_browser = false,
        .delete_confirm_pending = false,
        .delete_confirm_timer = 0,
        .sync_ip_err = false,
        .sync_pw_err = false,
        .search_field = .{},
        .search_pending = false,
        .search_focused = false,
        .copy_feedback_timer = 0,
    };
    for (0..7) |fi| self.edit_fields[fi] = .{ .masked = fi == ui.EDIT_PW_IDX };
    self.ip_field.setDefault("192.168.1.100");
    load_prefs: {
        var base = fs.openBaseDir() catch break :load_prefs;
        defer if (comptime is_android) base.close();
        var prefs_buf: [ui.max_field]u8 = undefined;
        const n = fs.loadPrefs(base, &prefs_buf);
        if (n > 0) self.ip_field.setDefault(prefs_buf[0..n]);
    }
    return self;
}

pub fn deinit(self: *Self) void {
    if (self.detail_entry) |e| e.deinit(self.allocator);
    for (self.rows.items) |r| r.deinit(self.allocator);
    self.rows.deinit(self.allocator);
    if (self.db) |*d| d.deinit();
}

// ---- Main per-frame update ----

pub fn update(self: *Self) void {
    const sw = rl.getScreenWidth();
    const sh = rl.getScreenHeight();
    const L = ui.Layout.compute(sw);

    const mouse = rl.getMousePosition();
    const mx = mouse.x;
    const my = mouse.y;

    if (rl.isMouseButtonPressed(.left)) self.drag_accum = 0;
    if (rl.isMouseButtonDown(.left)) self.drag_accum += @abs(rl.getMouseDelta().y);
    const is_tap = rl.isMouseButtonReleased(.left) and self.drag_accum < 10;

    const c = Ctx{ .sw = sw, .sh = sh, .L = L, .mx = mx, .my = my, .is_tap = is_tap };

    // Tick timers
    if (self.delete_confirm_pending) {
        self.delete_confirm_timer -= rl.getFrameTime();
        if (self.delete_confirm_timer <= 0) {
            self.delete_confirm_pending = false;
            self.delete_confirm_timer = 0;
        }
    }
    if (self.detail_delete_confirm_pending) {
        self.detail_delete_confirm_timer -= rl.getFrameTime();
        if (self.detail_delete_confirm_timer <= 0) {
            self.detail_delete_confirm_pending = false;
            self.detail_delete_confirm_timer = 0;
        }
    }
    if (self.copy_feedback_timer > 0) self.copy_feedback_timer -= rl.getFrameTime();

    // Input
    switch (self.phase) {
        .unlock => self.inputUnlock(c),
        .browser => self.inputBrowser(c),
        .detail => self.inputDetail(c),
        .edit => self.inputEdit(c),
        .sync_setup => self.inputSyncSetup(c),
        .sync_running => self.inputSyncRunning(c),
        .sync_result => self.inputSyncResult(c),
    }

    // Draw
    rl.beginDrawing();
    defer rl.endDrawing();
    rl.clearBackground(.black);

    switch (self.phase) {
        .unlock => self.drawUnlock(c),
        .browser => self.drawBrowser(c),
        .detail => self.drawDetail(c),
        .edit => self.drawEdit(c),
        .sync_setup => self.drawSyncSetup(c),
        .sync_running => self.drawSyncRunning(c),
        .sync_result => self.drawSyncResult(c),
    }
}

// ---- DB helpers ----

fn openDbAndPopulate(self: *Self, pw_slice: []const u8) OpenError!void {
    var base = fs.openBaseDir() catch return error.StorageError;
    defer if (comptime is_android) base.close();

    const password: ?[]const u8 = if (pw_slice.len > 0) pw_slice else null;
    const opened = loki.Database.open(self.allocator, base, fs.db_name, password) catch |err| {
        return if (err == error.WrongPassword) error.WrongPassword else error.OpenFailed;
    };

    if (self.db) |*d| d.deinit();
    self.db = opened;

    for (self.rows.items) |r| r.deinit(self.allocator);
    self.rows.clearRetainingCapacity();

    const entries = self.db.?.listEntries();
    for (entries) |ie| {
        const title = try self.allocator.dupe(u8, ie.title);
        errdefer self.allocator.free(title);
        const path = try self.allocator.dupe(u8, ie.path);
        errdefer self.allocator.free(path);
        try self.rows.append(self.allocator, .{
            .entry_id = ie.entry_id,
            .head_hash = ie.head_hash,
            .title = title,
            .path = path,
        });
    }
    std.mem.sort(ui.BrowserRow, self.rows.items, {}, ui.rowLessThan);
}

fn repopulateRows(self: *Self, d: *loki.Database) !void {
    for (self.rows.items) |r| r.deinit(self.allocator);
    self.rows.clearRetainingCapacity();
    for (d.listEntries()) |ie| {
        const title = try self.allocator.dupe(u8, ie.title);
        errdefer self.allocator.free(title);
        const path = try self.allocator.dupe(u8, ie.path);
        errdefer self.allocator.free(path);
        try self.rows.append(self.allocator, .{
            .entry_id = ie.entry_id,
            .head_hash = ie.head_hash,
            .title = title,
            .path = path,
        });
    }
    std.mem.sort(ui.BrowserRow, self.rows.items, {}, ui.rowLessThan);
}

// ============================================================
// INPUT
// ============================================================

fn inputUnlock(self: *Self, c: Ctx) void {
    if (comptime is_android) {
        if (!self.unlock_dialog_shown) {
            self.unlock_pw.showDialog("Enter password", true);
            self.unlock_dialog_shown = true;
        }
        var rbuf: [ui.max_field + 1]u8 = undefined;
        const poll = ui.pollTextInputDialog(&rbuf, @intCast(rbuf.len));
        if (poll > 0) {
            const n: usize = @intCast(poll);
            self.unlock_pw.len = n;
            @memcpy(self.unlock_pw.buf[0..n], rbuf[0..n]);
            self.unlock_dialog_shown = false;
            self.openDbAndPopulate(self.unlock_pw.slice()) catch |err| {
                self.unlock_err = switch (err) {
                    error.WrongPassword => "Wrong password.",
                    else => "Failed to open database.",
                };
            };
            if (self.db != null) {
                self.browser_scroll = 0;
                self.phase = .browser;
            }
        } else if (poll < 0) {
            self.unlock_dialog_shown = false;
            self.unlock_err = "Cancelled. Tap to retry.";
        } else if (c.is_tap and !self.unlock_dialog_shown) {
            self.unlock_pw.showDialog("Enter password", true);
            self.unlock_dialog_shown = true;
            self.unlock_err = null;
        }
    } else {
        if (rl.isKeyPressed(.backspace)) self.unlock_pw.pop();
        var ch = rl.getCharPressed();
        while (ch != 0) : (ch = rl.getCharPressed()) {
            if (ch >= 32 and ch < 127) self.unlock_pw.append(@intCast(ch));
        }
        const btn_w = c.sw - 2 * c.L.pad;
        const btn_y = @divTrunc(c.sh * 3, 5);
        const open_pressed = rl.isKeyPressed(.enter) or
            (c.is_tap and ui.inRect(c.mx, c.my, c.L.pad, btn_y, btn_w, c.L.btn_h));
        if (open_pressed) {
            self.openDbAndPopulate(self.unlock_pw.slice()) catch |err| {
                self.unlock_err = switch (err) {
                    error.WrongPassword => "Wrong password.",
                    else => "Failed to open database.",
                };
            };
            if (self.db != null) {
                self.browser_scroll = 0;
                self.phase = .browser;
            }
        }
    }
}

fn inputBrowser(self: *Self, c: Ctx) void {
    if (rl.isMouseButtonDown(.left)) {
        self.browser_scroll -= rl.getMouseDelta().y;
    }
    const search_bar_h = c.L.fh + c.L.pad;
    const list_top = c.L.hdr_h + search_bar_h;

    if (comptime is_android) {
        if (self.search_pending) {
            var rbuf: [ui.max_field + 1]u8 = undefined;
            const r = ui.pollTextInputDialog(&rbuf, @intCast(rbuf.len));
            if (r > 0) {
                const n: usize = @intCast(r);
                self.search_field.len = n;
                @memcpy(self.search_field.buf[0..n], rbuf[0..n]);
                self.browser_scroll = 0;
                self.search_pending = false;
            } else if (r < 0) {
                self.search_pending = false;
            }
        } else if (c.is_tap and !self.search_pending and
            ui.inRect(c.mx, c.my, c.L.pad, c.L.hdr_h + @divTrunc(c.L.pad, 2), c.sw - 2 * c.L.pad, c.L.fh))
        {
            self.search_field.showDialog("Search", false);
            self.search_pending = true;
        }
    } else {
        if (c.is_tap and ui.inRect(c.mx, c.my, c.L.pad, c.L.hdr_h + @divTrunc(c.L.pad, 2), c.sw - 2 * c.L.pad, c.L.fh)) {
            self.search_focused = true;
        } else if (c.is_tap) {
            self.search_focused = false;
        }
        if (self.search_focused) {
            if (rl.isKeyPressed(.backspace)) { self.search_field.pop(); self.browser_scroll = 0; }
            if (rl.isKeyPressed(.escape)) { self.search_field = .{}; self.search_focused = false; self.browser_scroll = 0; }
            var ch = rl.getCharPressed();
            while (ch != 0) : (ch = rl.getCharPressed()) {
                if (ch >= 32 and ch < 127) { self.search_field.append(@intCast(ch)); self.browser_scroll = 0; }
            }
        }
    }

    // Scroll clamping
    var match_count: i32 = 0;
    for (self.rows.items) |row| {
        if (ui.matchesSearch(row, self.search_field.slice())) match_count += 1;
    }
    const content_h: f32 = @floatFromInt(match_count * c.L.row_h);
    const visible_h: f32 = @floatFromInt(c.sh - list_top);
    self.browser_scroll = std.math.clamp(self.browser_scroll, 0, @max(0, content_h - visible_h));

    if (c.is_tap) {
        const hdr_btn_h = @divTrunc(c.L.btn_h, 2);
        const hdr_btn_y = @divTrunc(c.L.hdr_h - hdr_btn_h, 2);
        const sync_btn_w = @divTrunc(c.sw, 5);
        const sync_btn_x = c.sw - sync_btn_w - c.L.pad;
        const lock_btn_w = @divTrunc(c.sw, 6);
        const lock_btn_x = sync_btn_x - lock_btn_w - c.L.pad;
        const fab_size = @divTrunc(c.sw, 7);
        const fab_x = c.sw - fab_size - c.L.pad;
        const fab_y = c.sh - fab_size - c.L.pad;

        if (ui.inRect(c.mx, c.my, sync_btn_x, hdr_btn_y, sync_btn_w, hdr_btn_h)) {
            self.first_use = false;
            self.delete_db_err = null;
            self.sync_err = null;
            self.sync_from_browser = true;
            self.delete_confirm_pending = false;
            self.phase = .sync_setup;
        } else if (ui.inRect(c.mx, c.my, lock_btn_x, hdr_btn_y, lock_btn_w, hdr_btn_h)) {
            if (self.db) |*d| d.deinit();
            self.db = null;
            for (self.rows.items) |r| r.deinit(self.allocator);
            self.rows.clearRetainingCapacity();
            if (self.detail_entry) |e| e.deinit(self.allocator);
            self.detail_entry = null;
            self.unlock_pw = .{ .masked = true };
            self.unlock_err = null;
            self.unlock_dialog_shown = false;
            self.phase = .unlock;
        } else if (ui.inRect(c.mx, c.my, fab_x, fab_y, fab_size, fab_size)) {
            for (0..7) |fi| self.edit_fields[fi] = .{ .masked = fi == ui.EDIT_PW_IDX };
            self.edit_is_new = true;
            self.edit_show_pw = false;
            self.edit_pending = null;
            self.edit_err = null;
            self.edit_focus = 0;
            self.edit_scroll = 0;
            self.phase = .edit;
        } else if (c.my >= @as(f32, @floatFromInt(list_top))) {
            const rel_y = @as(i32, @intFromFloat(c.my)) - list_top +
                @as(i32, @intFromFloat(self.browser_scroll));
            const idx_i = @divTrunc(rel_y, c.L.row_h);
            if (idx_i >= 0) {
                var visible_i: i32 = 0;
                for (self.rows.items) |row| {
                    if (!ui.matchesSearch(row, self.search_field.slice())) continue;
                    if (visible_i == idx_i) {
                        if (self.db) |*d| {
                            if (self.detail_entry) |e| e.deinit(self.allocator);
                            self.detail_entry = d.getEntry(row.entry_id) catch null;
                            self.detail_entry_id = row.entry_id;
                            self.detail_head_hash = row.head_hash;
                            self.detail_show_pw = false;
                            self.detail_scroll = 0;
                            self.phase = .detail;
                        }
                        break;
                    }
                    visible_i += 1;
                }
            }
        }
    }
}

fn inputDetail(self: *Self, c: Ctx) void {
    if (rl.isMouseButtonDown(.left)) {
        self.detail_scroll -= rl.getMouseDelta().y;
    }
    self.detail_scroll = @max(0, self.detail_scroll);
    if (comptime !is_android) {
        if (rl.isKeyPressed(.h)) self.detail_show_pw = !self.detail_show_pw;
        if (rl.isKeyPressed(.escape) or rl.isKeyPressed(.backspace))
            self.phase = .browser;
    }
    const del_btn_h = c.L.btn_h;
    const del_btn_y = c.sh - del_btn_h - c.L.pad;
    if (c.is_tap) {
        if (ui.inRect(c.mx, c.my, 0, 0, @divTrunc(c.sw, 3), c.L.hdr_h)) {
            self.detail_delete_confirm_pending = false;
            self.phase = .browser;
        } else if (ui.inRect(c.mx, c.my, c.sw - @divTrunc(c.sw, 3), 0, @divTrunc(c.sw, 3), c.L.hdr_h)) {
            if (self.detail_entry) |e| {
                const vals = [7][]const u8{
                    e.title, e.path, e.description, e.url, e.username, e.password, e.notes,
                };
                for (0..7) |fi| {
                    self.edit_fields[fi] = .{ .masked = fi == ui.EDIT_PW_IDX };
                    self.edit_fields[fi].setDefault(vals[fi]);
                }
            }
            self.edit_is_new = false;
            self.edit_show_pw = false;
            self.edit_pending = null;
            self.edit_err = null;
            self.edit_focus = 0;
            self.edit_scroll = 0;
            self.phase = .edit;
        } else if (ui.inRect(c.mx, c.my, c.L.pad, del_btn_y, c.sw - 2 * c.L.pad, del_btn_h)) {
            if (self.detail_delete_confirm_pending) {
                if (self.db) |*d| {
                    d.deleteEntry(self.detail_entry_id) catch {};
                    d.save() catch {};
                    self.repopulateRows(d) catch {};
                }
                if (self.detail_entry) |e| e.deinit(self.allocator);
                self.detail_entry = null;
                self.detail_delete_confirm_pending = false;
                self.phase = .browser;
            } else {
                self.detail_delete_confirm_pending = true;
                self.detail_delete_confirm_timer = 3.0;
            }
        } else {
            const scroll_i: i32 = @intFromFloat(self.detail_scroll);
            const toggle_w = @divTrunc(c.sw, 5);
            const pw_row_y = c.L.hdr_h + c.L.pad + ui.DETAIL_PW_IDX * c.L.detail_row_h - scroll_i;
            if (ui.inRect(c.mx, c.my, c.sw - toggle_w - c.L.pad, pw_row_y, toggle_w, c.L.detail_row_h)) {
                self.detail_show_pw = !self.detail_show_pw;
            } else if (c.my >= @as(f32, @floatFromInt(c.L.hdr_h)) and
                c.my < @as(f32, @floatFromInt(del_btn_y)))
            {
                if (self.detail_entry) |e| {
                    const vals = [7][]const u8{
                        e.title, e.path, e.description, e.url, e.username, e.password, e.notes,
                    };
                    for (0..7) |fi| {
                        const fy = c.L.hdr_h + c.L.pad + @as(i32, @intCast(fi)) * c.L.detail_row_h - scroll_i;
                        if (ui.inRect(c.mx, c.my, 0, fy, c.sw, c.L.detail_row_h)) {
                            var cbuf: [ui.max_field + 1:0]u8 = std.mem.zeroes([ui.max_field + 1:0]u8);
                            const n = @min(vals[fi].len, ui.max_field);
                            @memcpy(cbuf[0..n], vals[fi][0..n]);
                            rl.setClipboardText(&cbuf);
                            self.copy_feedback_timer = 1.5;
                            break;
                        }
                    }
                }
            }
        }
    }
}

fn inputEdit(self: *Self, c: Ctx) void {
    if (rl.isMouseButtonDown(.left)) {
        self.edit_scroll -= rl.getMouseDelta().y;
    }
    const edit_content_h: f32 = @floatFromInt(7 * c.L.detail_row_h);
    const edit_visible_h: f32 = @floatFromInt(c.sh - c.L.hdr_h);
    self.edit_scroll = std.math.clamp(self.edit_scroll, 0, @max(0, edit_content_h - edit_visible_h));

    if (comptime is_android) {
        if (self.edit_pending) |fi| {
            var rbuf: [ui.max_field + 1]u8 = undefined;
            const r = ui.pollTextInputDialog(&rbuf, @intCast(rbuf.len));
            if (r > 0) {
                const n: usize = @intCast(r);
                self.edit_fields[fi].len = n;
                @memcpy(self.edit_fields[fi].buf[0..n], rbuf[0..n]);
                self.edit_pending = null;
            } else if (r < 0) {
                self.edit_pending = null;
            }
        }
        if (c.is_tap and self.edit_pending == null) {
            const scroll_i: i32 = @intFromFloat(self.edit_scroll);
            const toggle_w = @divTrunc(c.sw, 5);
            for (0..7) |fi| {
                const fy = c.L.hdr_h + @as(i32, @intCast(fi)) * c.L.detail_row_h - scroll_i;
                if (fy >= c.L.hdr_h and ui.inRect(c.mx, c.my, 0, fy, c.sw, c.L.detail_row_h)) {
                    if (fi == ui.EDIT_PW_IDX and
                        ui.inRect(c.mx, c.my, c.sw - toggle_w - c.L.pad, fy, toggle_w, c.L.detail_row_h))
                    {
                        self.edit_show_pw = !self.edit_show_pw;
                    } else {
                        self.edit_fields[fi].showDialog(ui.edit_field_labels[fi].ptr, fi == ui.EDIT_PW_IDX and !self.edit_show_pw);
                        self.edit_pending = fi;
                        self.edit_err = null;
                    }
                    break;
                }
            }
        }
    } else {
        if (rl.isKeyPressed(.tab)) self.edit_focus = (self.edit_focus + 1) % 7;
        if (rl.isKeyPressed(.backspace)) self.edit_fields[self.edit_focus].pop();
        var ch = rl.getCharPressed();
        while (ch != 0) : (ch = rl.getCharPressed()) {
            if (ch >= 32 and ch < 127) self.edit_fields[self.edit_focus].append(@intCast(ch));
        }
        if (c.is_tap) {
            const scroll_i: i32 = @intFromFloat(self.edit_scroll);
            for (0..7) |fi| {
                const fy = c.L.hdr_h + @as(i32, @intCast(fi)) * c.L.detail_row_h - scroll_i;
                if (ui.inRect(c.mx, c.my, 0, fy, c.sw, c.L.detail_row_h)) {
                    self.edit_focus = fi;
                    break;
                }
            }
        }
        if (rl.isKeyPressed(.escape)) self.phase = .detail;
    }

    // Cancel / Save (both platforms)
    const hdr_btn_w = @divTrunc(c.sw, 4);
    if (c.is_tap and ui.inRect(c.mx, c.my, 0, 0, hdr_btn_w, c.L.hdr_h)) {
        self.edit_err = null;
        self.phase = .detail;
    }
    const do_save = c.is_tap and ui.inRect(c.mx, c.my, c.sw - hdr_btn_w, 0, hdr_btn_w, c.L.hdr_h);
    const do_save_key = if (comptime !is_android) rl.isKeyPressed(.enter) else false;
    if (do_save or do_save_key) self.doSave();
}

fn doSave(self: *Self) void {
    save: {
        const d = if (self.db) |*d_| d_ else {
            self.edit_err = "No database.";
            break :save;
        };
        const new_entry = loki.Entry{
            .parent_hash = if (self.edit_is_new) null else self.detail_head_hash,
            .title = self.edit_fields[0].slice(),
            .path = self.edit_fields[1].slice(),
            .description = self.edit_fields[2].slice(),
            .url = self.edit_fields[3].slice(),
            .username = self.edit_fields[4].slice(),
            .password = self.edit_fields[5].slice(),
            .notes = self.edit_fields[6].slice(),
        };
        if (self.edit_is_new) {
            _ = d.createEntry(new_entry) catch {
                self.edit_err = "Save failed.";
                break :save;
            };
            d.save() catch {
                self.edit_err = "Save failed.";
                break :save;
            };
            self.repopulateRows(d) catch {
                self.edit_err = "Save failed.";
                break :save;
            };
            self.browser_scroll = 0;
            self.phase = .browser;
        } else {
            _ = d.updateEntry(self.detail_entry_id, new_entry) catch {
                self.edit_err = "Save failed.";
                break :save;
            };
            d.save() catch {
                self.edit_err = "Save failed.";
                break :save;
            };
            self.repopulateRows(d) catch {
                self.edit_err = "Save failed.";
                break :save;
            };
            // P2.5: return to detail with refreshed data.
            if (self.detail_entry) |e| e.deinit(self.allocator);
            self.detail_entry = d.getEntry(self.detail_entry_id) catch null;
            for (self.rows.items) |r| {
                if (std.mem.eql(u8, &r.entry_id, &self.detail_entry_id)) {
                    self.detail_head_hash = r.head_hash;
                    break;
                }
            }
            self.phase = .detail;
        }
    }
}

fn inputSyncSetup(self: *Self, c: Ctx) void {
    const form_top = if (self.sync_from_browser) c.L.hdr_h + c.L.pad else c.L.pad * 2;
    const fw = c.sw - 2 * c.L.pad;
    const title_y = form_top;
    const sub_y = title_y + c.L.fs_hdr + c.L.pad;
    const ip_label_y = sub_y + c.L.fs_label + c.L.pad * 2;
    const ip_field_y = ip_label_y + c.L.fs_label + 6;
    const pw_label_y = ip_field_y + c.L.fh + c.L.pad;
    const pw_field_y = pw_label_y + c.L.fs_label + 6;
    const submit_btn_y = pw_field_y + c.L.fh + c.L.pad * 2;
    const del_btn_y = submit_btn_y + c.L.btn_h + c.L.pad;

    if (self.sync_from_browser and c.is_tap and ui.inRect(c.mx, c.my, 0, 0, @divTrunc(c.sw, 3), c.L.hdr_h)) {
        self.sync_from_browser = false;
        self.phase = .browser;
    }

    if (rl.isMouseButtonPressed(.left) and self.sync_pending_field == null) {
        if (ui.inRect(c.mx, c.my, c.L.pad, ip_field_y, fw, c.L.fh)) {
            self.sync_focus_ip = true;
            if (comptime is_android) {
                self.ip_field.showDialog("Server IP", false);
                self.sync_pending_field = true;
            }
        } else if (ui.inRect(c.mx, c.my, c.L.pad, pw_field_y, fw, c.L.fh)) {
            self.sync_focus_ip = false;
            if (comptime is_android) {
                self.sync_pw_field.showDialog("Password", true);
                self.sync_pending_field = false;
            }
        }
    }

    if (comptime is_android) {
        if (self.sync_pending_field) |is_ip| {
            var rbuf: [ui.max_field + 1]u8 = undefined;
            const r = ui.pollTextInputDialog(&rbuf, @intCast(rbuf.len));
            if (r > 0) {
                const field = if (is_ip) &self.ip_field else &self.sync_pw_field;
                const n: usize = @intCast(r);
                field.len = n;
                @memcpy(field.buf[0..n], rbuf[0..n]);
                self.sync_pending_field = null;
            } else if (r < 0) {
                self.sync_pending_field = null;
            }
        }
    } else {
        if (rl.isKeyPressed(.tab)) self.sync_focus_ip = !self.sync_focus_ip;
        const active = if (self.sync_focus_ip) &self.ip_field else &self.sync_pw_field;
        if (rl.isKeyPressed(.backspace)) active.pop();
        var ch = rl.getCharPressed();
        while (ch != 0) : (ch = rl.getCharPressed()) {
            if (ch >= 32 and ch < 127) active.append(@intCast(ch));
        }
    }

    // Delete DB (two-tap confirmation, existing DB only)
    if (!self.first_use and c.is_tap and ui.inRect(c.mx, c.my, c.L.pad, del_btn_y, fw, c.L.btn_h)) {
        if (self.delete_confirm_pending) {
            if (self.db) |*d| d.deinit();
            self.db = null;
            for (self.rows.items) |r| r.deinit(self.allocator);
            self.rows.clearRetainingCapacity();
            if (fs.deleteDb()) {
                self.first_use = true;
                self.delete_db_err = null;
                self.sync_err = null;
                self.sync_from_browser = false;
            } else {
                self.delete_db_err = "Failed to delete database.";
            }
            self.delete_confirm_pending = false;
        } else {
            self.delete_confirm_pending = true;
            self.delete_confirm_timer = 3.0;
        }
    }

    // Create new local DB (first use only)
    if (self.first_use and c.is_tap and ui.inRect(c.mx, c.my, c.L.pad, del_btn_y, fw, c.L.btn_h)) {
        create_db: {
            if (self.sync_pw_field.len == 0) {
                self.sync_pw_err = true;
                self.sync_err = "Enter a password for the new database.";
                break :create_db;
            }
            var base = fs.openBaseDir() catch {
                self.sync_err = "Storage error.";
                break :create_db;
            };
            defer if (comptime is_android) base.close();
            const created = loki.Database.create(
                self.allocator, base, fs.db_name, self.sync_pw_field.slice(),
            ) catch {
                self.sync_err = "Failed to create database.";
                break :create_db;
            };
            if (self.db) |*d| d.deinit();
            self.db = created;
            for (self.rows.items) |r| r.deinit(self.allocator);
            self.rows.clearRetainingCapacity();
            self.first_use = false;
            self.sync_from_browser = false;
            self.sync_err = null;
            self.sync_ip_err = false;
            self.sync_pw_err = false;
            self.phase = .browser;
        }
    }

    // Sync / Fetch submit
    const clicked_submit = rl.isMouseButtonPressed(.left) and
        ui.inRect(c.mx, c.my, c.L.pad, submit_btn_y, fw, c.L.btn_h);
    if (clicked_submit or rl.isKeyPressed(.enter)) {
        if (self.ip_field.len == 0 or self.sync_pw_field.len == 0) {
            self.sync_ip_err = self.ip_field.len == 0;
            self.sync_pw_err = self.sync_pw_field.len == 0;
            self.sync_err = "Please enter IP and password.";
        } else {
            @memcpy(sync.g_ip[0..self.ip_field.len], self.ip_field.buf[0..self.ip_field.len]);
            sync.g_ip_len = self.ip_field.len;
            @memcpy(sync.g_pw[0..self.sync_pw_field.len], self.sync_pw_field.buf[0..self.sync_pw_field.len]);
            sync.g_pw_len = self.sync_pw_field.len;
            sync.g_status.store(.connecting, .release);
            save_prefs: {
                var base = fs.openBaseDir() catch break :save_prefs;
                defer if (comptime is_android) base.close();
                fs.savePrefs(base, self.ip_field.slice());
            }
            if (std.Thread.spawn(.{}, sync.syncThread, .{})) |thread| {
                thread.detach();
                self.phase = .sync_running;
                self.sync_err = null;
                self.sync_ip_err = false;
                self.sync_pw_err = false;
                self.delete_db_err = null;
            } else |_| {
                self.sync_err = "Failed to start sync thread.";
            }
        }
    }
}

fn inputSyncRunning(self: *Self, c: Ctx) void {
    _ = c;
    const s = sync.g_status.load(.acquire);
    if (s == .done) {
        self.openDbAndPopulate(self.sync_pw_field.slice()) catch {};
        if (self.db != null) {
            self.browser_scroll = 0;
            self.phase = .browser;
        } else {
            self.phase = .sync_result;
        }
    } else if (s == .failed) {
        self.phase = .sync_result;
    }
}

fn inputSyncResult(self: *Self, c: Ctx) void {
    const btn_y = c.sh - c.L.btn_h - c.L.pad;
    const status = sync.g_status.load(.acquire);
    if (status == .done) {
        if (c.is_tap and ui.inRect(c.mx, c.my, c.L.pad, btn_y, c.sw - 2 * c.L.pad, c.L.btn_h)) {
            self.unlock_pw = .{ .masked = true };
            self.unlock_err = null;
            self.unlock_dialog_shown = false;
            self.phase = .unlock;
        }
    } else if (status == .failed) {
        const half_w = @divTrunc(c.sw - 3 * c.L.pad, 2);
        if (c.is_tap and ui.inRect(c.mx, c.my, c.L.pad, btn_y, half_w, c.L.btn_h)) {
            self.sync_err = null;
            self.phase = .sync_setup;
        } else if (c.is_tap and ui.inRect(c.mx, c.my, 2 * c.L.pad + half_w, btn_y, half_w, c.L.btn_h)) {
            sync.g_status.store(.connecting, .release);
            if (std.Thread.spawn(.{}, sync.syncThread, .{})) |thread| {
                thread.detach();
                self.phase = .sync_running;
            } else |_| {
                self.sync_err = "Failed to start sync thread.";
                self.phase = .sync_setup;
            }
        }
    }
}

// ============================================================
// DRAW
// ============================================================

fn drawUnlock(self: *Self, c: Ctx) void {
    const title_y = @divTrunc(c.sh, 6);
    const title_tw = rl.measureText("Loki", c.L.fs_hdr * 2);
    rl.drawText("Loki", @divTrunc(c.sw - title_tw, 2), title_y, c.L.fs_hdr * 2, .white);

    const sub = "Enter password to open your database.";
    const sub_tw = rl.measureText(sub, c.L.fs_label);
    rl.drawText(sub, @divTrunc(c.sw - sub_tw, 2), title_y + c.L.fs_hdr * 2 + c.L.pad, c.L.fs_label, .gray);

    const field_y = @divTrunc(c.sh * 2, 5);
    const fw = c.sw - 2 * c.L.pad;
    ui.drawTextField(&self.unlock_pw, c.L.pad, field_y, fw, c.L.fh, true, false);

    if (self.unlock_err) |msg| {
        const etw = rl.measureText(msg, c.L.fs_label);
        rl.drawText(msg, @divTrunc(c.sw - etw, 2), field_y + c.L.fh + c.L.pad, c.L.fs_label, .orange);
    }

    if (comptime !is_android) {
        const btn_y = @divTrunc(c.sh * 3, 5);
        ui.drawButton("Open", c.L.pad, btn_y, fw, c.L.btn_h, .{ .r = 30, .g = 140, .b = 200, .a = 255 });
        rl.drawText("Enter: open", c.L.pad, c.sh - c.L.fs_small - c.L.pad, c.L.fs_small, .dark_gray);
    }
}

fn drawBrowser(self: *Self, c: Ctx) void {
    const search_bar_h = c.L.fh + c.L.pad;
    const list_top = c.L.hdr_h + search_bar_h;
    var draw_row_idx: i32 = 0;
    var any_visible = false;
    for (self.rows.items) |row| {
        if (!ui.matchesSearch(row, self.search_field.slice())) continue;
        any_visible = true;
        const row_y = list_top + draw_row_idx * c.L.row_h -
            @as(i32, @intFromFloat(self.browser_scroll));
        draw_row_idx += 1;
        if (row_y + c.L.row_h <= list_top or row_y > c.sh) continue;

        const bg: rl.Color = if (@mod(draw_row_idx, 2) == 0)
            .{ .r = 18, .g = 18, .b = 28, .a = 255 }
        else
            .{ .r = 24, .g = 24, .b = 36, .a = 255 };
        rl.drawRectangle(0, row_y, c.sw, c.L.row_h, bg);

        if (row_y >= list_top) {
            const text_block_h = if (row.path.len > 0)
                c.L.fs_body + @divTrunc(c.L.pad, 2) + c.L.fs_small
            else
                c.L.fs_body;
            const text_y = row_y + @divTrunc(c.L.row_h - text_block_h, 2);
            ui.drawSlice(row.title, c.L.pad, text_y, c.L.fs_body, .white);
            if (row.path.len > 0) {
                ui.drawSlice(row.path, c.L.pad, text_y + c.L.fs_body + @divTrunc(c.L.pad, 2), c.L.fs_small, .gray);
            }
            rl.drawText(">", c.sw - c.L.pad - c.L.fs_body, row_y + @divTrunc(c.L.row_h - c.L.fs_body, 2), c.L.fs_body, .dark_gray);
        }
        rl.drawRectangle(0, row_y + c.L.row_h - 1, c.sw, 1, .{ .r = 40, .g = 40, .b = 55, .a = 255 });
    }

    if (!any_visible) {
        const msg: [:0]const u8 = if (self.search_field.len > 0) "No results." else "No entries.";
        rl.drawText(msg, c.L.pad, list_top + c.L.pad, c.L.fs_body, .gray);
    }

    // Header (drawn last so it covers scrolled content)
    rl.drawRectangle(0, 0, c.sw, c.L.hdr_h, .{ .r = 20, .g = 20, .b = 30, .a = 255 });
    rl.drawText("Loki", c.L.pad, @divTrunc(c.L.hdr_h - c.L.fs_hdr, 2), c.L.fs_hdr, .white);

    const hdr_btn_h = @divTrunc(c.L.btn_h, 2);
    const hdr_btn_y = @divTrunc(c.L.hdr_h - hdr_btn_h, 2);
    const sync_btn_w = @divTrunc(c.sw, 5);
    const sync_btn_x = c.sw - sync_btn_w - c.L.pad;
    const lock_btn_w = @divTrunc(c.sw, 6);
    const lock_btn_x = sync_btn_x - lock_btn_w - c.L.pad;
    ui.drawButton("Sync", sync_btn_x, hdr_btn_y, sync_btn_w, hdr_btn_h, .{ .r = 30, .g = 130, .b = 180, .a = 255 });
    ui.drawButton("Lock", lock_btn_x, hdr_btn_y, lock_btn_w, hdr_btn_h, .{ .r = 70, .g = 70, .b = 90, .a = 255 });

    // Search bar
    rl.drawRectangle(0, c.L.hdr_h, c.sw, search_bar_h, .{ .r = 15, .g = 15, .b = 22, .a = 255 });
    const sf_y = c.L.hdr_h + @divTrunc(c.L.pad, 2);
    ui.drawTextField(&self.search_field, c.L.pad, sf_y, c.sw - 2 * c.L.pad, c.L.fh,
        self.search_focused or self.search_field.len > 0, false);
    if (self.search_field.len == 0) {
        rl.drawText("Search...", c.L.pad + 8, sf_y + @divTrunc(c.L.fh - c.L.fs_label, 2), c.L.fs_label, .gray);
    }

    // "+" FAB
    const fab_size = @divTrunc(c.sw, 7);
    const fab_x = c.sw - fab_size - c.L.pad;
    const fab_y = c.sh - fab_size - c.L.pad;
    ui.drawButton("+", fab_x, fab_y, fab_size, fab_size, .{ .r = 0, .g = 135, .b = 190, .a = 255 });
}

fn drawDetail(self: *Self, c: Ctx) void {
    const entry = self.detail_entry orelse {
        rl.drawText("No entry loaded.", c.L.pad, c.L.hdr_h + c.L.pad, c.L.fs_body, .gray);
        return;
    };

    const scroll_i: i32 = @intFromFloat(self.detail_scroll);
    const val_x = c.L.label_w + c.L.pad;
    const toggle_w = @divTrunc(c.sw, 5);

    const Field = struct { label: []const u8, value: []const u8 };
    const fields = [_]Field{
        .{ .label = "Title",    .value = entry.title },
        .{ .label = "Path",     .value = entry.path },
        .{ .label = "Desc",     .value = entry.description },
        .{ .label = "URL",      .value = entry.url },
        .{ .label = "Username", .value = entry.username },
        .{ .label = "Password", .value = entry.password },
        .{ .label = "Notes",    .value = entry.notes },
    };

    for (fields, 0..) |f, fi| {
        const fy = c.L.hdr_h + c.L.pad + @as(i32, @intCast(fi)) * c.L.detail_row_h - scroll_i;
        if (fy + c.L.detail_row_h < c.L.hdr_h or fy > c.sh) continue;

        const bg: rl.Color = if (fi % 2 == 0)
            .{ .r = 18, .g = 18, .b = 28, .a = 255 }
        else
            .{ .r = 26, .g = 26, .b = 38, .a = 255 };
        rl.drawRectangle(0, fy, c.sw, c.L.detail_row_h, bg);

        ui.drawSlice(f.label, c.L.pad, fy + @divTrunc(c.L.detail_row_h - c.L.fs_label, 2), c.L.fs_label, .gray);

        const val_y = fy + @divTrunc(c.L.detail_row_h - c.L.fs_body, 2);
        const is_pw = fi == ui.DETAIL_PW_IDX;

        if (is_pw and !self.detail_show_pw) {
            var stars: [64:0]u8 = undefined;
            const n = @min(f.value.len, 63);
            @memset(stars[0..n], '*');
            stars[n] = 0;
            rl.drawText(&stars, val_x, val_y, c.L.fs_body, .white);
        } else if (is_pw) {
            ui.drawSlice(f.value, val_x, val_y, c.L.fs_body, .{ .r = 255, .g = 200, .b = 100, .a = 255 });
        } else {
            ui.drawSlice(f.value, val_x, val_y, c.L.fs_body, .white);
        }

        if (is_pw) {
            const toggle_h = @divTrunc(c.L.detail_row_h * 2, 3);
            const toggle_label: [:0]const u8 = if (self.detail_show_pw) "Hide" else "Show";
            ui.drawButton(toggle_label,
                c.sw - toggle_w - c.L.pad,
                fy + @divTrunc(c.L.detail_row_h - toggle_h, 2),
                toggle_w, toggle_h, .{ .r = 60, .g = 60, .b = 90, .a = 255 });
        }

        rl.drawRectangle(0, fy + c.L.detail_row_h - 1, c.sw, 1, .{ .r = 40, .g = 40, .b = 55, .a = 255 });
    }

    // Delete button (pinned bottom)
    const del_btn_h = c.L.btn_h;
    const del_btn_y = c.sh - del_btn_h - c.L.pad;
    if (self.detail_delete_confirm_pending) {
        ui.drawButton("Tap again to confirm delete", c.L.pad, del_btn_y, c.sw - 2 * c.L.pad, del_btn_h,
            .{ .r = 220, .g = 30, .b = 30, .a = 255 });
    } else {
        ui.drawButton("Delete", c.L.pad, del_btn_y, c.sw - 2 * c.L.pad, del_btn_h,
            .{ .r = 160, .g = 40, .b = 40, .a = 255 });
    }

    // "Copied!" toast
    if (self.copy_feedback_timer > 0) {
        const toast = "Copied!";
        const ttw = rl.measureText(toast, c.L.fs_body);
        const toast_pad = c.L.pad * 2;
        const toast_w = ttw + toast_pad * 2;
        const toast_h = c.L.fs_body + toast_pad;
        const toast_x = @divTrunc(c.sw - toast_w, 2);
        const toast_y = del_btn_y - toast_h - c.L.pad;
        rl.drawRectangle(toast_x, toast_y, toast_w, toast_h, .{ .r = 30, .g = 30, .b = 30, .a = 220 });
        rl.drawText(toast, toast_x + toast_pad, toast_y + @divTrunc(toast_pad, 2), c.L.fs_body, .white);
    }

    if (comptime !is_android) {
        rl.drawText("h: pw  Esc: back", c.L.pad,
            c.sh - c.L.fs_small - c.L.pad - del_btn_h - c.L.pad, c.L.fs_small, .dark_gray);
    }

    // Header (drawn last)
    rl.drawRectangle(0, 0, c.sw, c.L.hdr_h, .{ .r = 20, .g = 20, .b = 30, .a = 255 });
    rl.drawText("< Back", c.L.pad, @divTrunc(c.L.hdr_h - c.L.fs_body, 2), c.L.fs_body, .sky_blue);
    const edit_lbl_tw = rl.measureText("Edit", c.L.fs_body);
    rl.drawText("Edit", c.sw - edit_lbl_tw - c.L.pad, @divTrunc(c.L.hdr_h - c.L.fs_body, 2), c.L.fs_body, .sky_blue);
}

fn drawEdit(self: *Self, c: Ctx) void {
    const scroll_i: i32 = @intFromFloat(self.edit_scroll);
    const val_x = c.L.label_w + c.L.pad;

    for (0..7) |fi| {
        const fy = c.L.hdr_h + @as(i32, @intCast(fi)) * c.L.detail_row_h - scroll_i;
        if (fy + c.L.detail_row_h <= c.L.hdr_h or fy > c.sh) continue;

        const is_focused = (comptime !is_android) and fi == self.edit_focus;
        const bg: rl.Color = if (is_focused)
            .{ .r = 22, .g = 30, .b = 48, .a = 255 }
        else if (fi % 2 == 0)
            .{ .r = 18, .g = 18, .b = 28, .a = 255 }
        else
            .{ .r = 26, .g = 26, .b = 38, .a = 255 };
        rl.drawRectangle(0, fy, c.sw, c.L.detail_row_h, bg);

        if (fy >= c.L.hdr_h) {
            ui.drawSlice(ui.edit_field_labels[fi], c.L.pad,
                fy + @divTrunc(c.L.detail_row_h - c.L.fs_label, 2), c.L.fs_label, .gray);

            const is_pw_field = fi == ui.EDIT_PW_IDX;
            const show_plain = !is_pw_field or
                (if (comptime is_android) self.edit_show_pw else fi == self.edit_focus);
            const val_y = fy + @divTrunc(c.L.detail_row_h - c.L.fs_body, 2);

            if (show_plain) {
                var dbuf: [ui.max_field + 1:0]u8 = std.mem.zeroes([ui.max_field + 1:0]u8);
                const n = self.edit_fields[fi].len;
                @memcpy(dbuf[0..n], self.edit_fields[fi].buf[0..n]);
                rl.drawText(&dbuf, val_x, val_y, c.L.fs_body, .white);
                if (is_focused) {
                    const tw = rl.measureText(&dbuf, c.L.fs_body);
                    rl.drawRectangle(val_x + tw, val_y, 2, c.L.fs_body, .sky_blue);
                }
            } else {
                var stars: [64:0]u8 = undefined;
                const n = @min(self.edit_fields[fi].len, 63);
                @memset(stars[0..n], '*');
                stars[n] = 0;
                rl.drawText(&stars, val_x, val_y, c.L.fs_body, .white);
            }

            if (comptime is_android) {
                if (is_pw_field) {
                    const toggle_w = @divTrunc(c.sw, 5);
                    const toggle_h = @divTrunc(c.L.detail_row_h * 2, 3);
                    const toggle_label: [:0]const u8 = if (self.edit_show_pw) "Hide" else "Show";
                    ui.drawButton(toggle_label,
                        c.sw - toggle_w - c.L.pad,
                        fy + @divTrunc(c.L.detail_row_h - toggle_h, 2),
                        toggle_w, toggle_h, .{ .r = 60, .g = 60, .b = 90, .a = 255 });
                } else {
                    rl.drawText(">", c.sw - c.L.pad - c.L.fs_body, val_y, c.L.fs_body, .dark_gray);
                }
            }
        }

        rl.drawRectangle(0, fy + c.L.detail_row_h - 1, c.sw, 1, .{ .r = 40, .g = 40, .b = 55, .a = 255 });
    }

    if (self.edit_err) |msg| {
        rl.drawText(msg, c.L.pad, c.sh - c.L.fs_label - c.L.pad, c.L.fs_label, .orange);
    }

    // Header (drawn last)
    const hdr_btn_w = @divTrunc(c.sw, 4);
    rl.drawRectangle(0, 0, c.sw, c.L.hdr_h, .{ .r = 20, .g = 20, .b = 30, .a = 255 });
    rl.drawText("Cancel", c.L.pad, @divTrunc(c.L.hdr_h - c.L.fs_body, 2), c.L.fs_body, .sky_blue);
    const save_tw = rl.measureText("Save", c.L.fs_body);
    rl.drawText("Save",
        c.sw - hdr_btn_w + @divTrunc(hdr_btn_w - save_tw, 2),
        @divTrunc(c.L.hdr_h - c.L.fs_body, 2),
        c.L.fs_body, .{ .r = 80, .g = 200, .b = 100, .a = 255 });

    if (comptime !is_android) {
        rl.drawText("Tab: next field   Enter: save   Esc: cancel",
            c.L.pad, c.sh - c.L.fs_small - c.L.pad, c.L.fs_small, .dark_gray);
    }
}

fn drawSyncSetup(self: *Self, c: Ctx) void {
    const form_top = if (self.sync_from_browser) c.L.hdr_h + c.L.pad else c.L.pad * 2;
    const fw = c.sw - 2 * c.L.pad;
    const title_y = form_top;
    const sub_y = title_y + c.L.fs_hdr + c.L.pad;
    const ip_label_y = sub_y + c.L.fs_label + c.L.pad * 2;
    const ip_field_y = ip_label_y + c.L.fs_label + 6;
    const pw_label_y = ip_field_y + c.L.fh + c.L.pad;
    const pw_field_y = pw_label_y + c.L.fs_label + 6;
    const submit_btn_y = pw_field_y + c.L.fh + c.L.pad * 2;
    const del_btn_y = submit_btn_y + c.L.btn_h + c.L.pad;

    rl.drawText("Loki Sync", c.L.pad, title_y, c.L.fs_hdr, .white);

    const subtitle: [:0]const u8 = if (self.first_use)
        "First use: fetch the database from server"
    else
        "Sync database with server";
    rl.drawText(subtitle, c.L.pad, sub_y, c.L.fs_label, .gray);

    rl.drawText("Server IP", c.L.pad, ip_label_y, c.L.fs_label, .light_gray);
    ui.drawTextField(&self.ip_field, c.L.pad, ip_field_y, fw, c.L.fh, self.sync_focus_ip, self.sync_ip_err);

    rl.drawText("Password", c.L.pad, pw_label_y, c.L.fs_label, .light_gray);
    ui.drawTextField(&self.sync_pw_field, c.L.pad, pw_field_y, fw, c.L.fh, !self.sync_focus_ip, self.sync_pw_err);

    const submit_label: [:0]const u8 = if (self.first_use) "Fetch" else "Sync";
    ui.drawButton(submit_label, c.L.pad, submit_btn_y, fw, c.L.btn_h, .sky_blue);

    if (self.first_use) {
        ui.drawButton("Create new (no server)", c.L.pad, del_btn_y, fw, c.L.btn_h,
            .{ .r = 50, .g = 100, .b = 60, .a = 255 });
    } else {
        if (self.delete_confirm_pending) {
            ui.drawButton("Tap again to confirm delete", c.L.pad, del_btn_y, fw, c.L.btn_h,
                .{ .r = 220, .g = 30, .b = 30, .a = 255 });
        } else {
            ui.drawButton("Delete DB", c.L.pad, del_btn_y, fw, c.L.btn_h,
                .{ .r = 180, .g = 40, .b = 40, .a = 255 });
        }
    }

    const err_y = del_btn_y + c.L.btn_h + c.L.pad;
    if (self.sync_err) |msg| rl.drawText(msg, c.L.pad, err_y, c.L.fs_label, .orange);
    if (self.delete_db_err) |msg| rl.drawText(msg, c.L.pad, err_y + c.L.fs_label + 4, c.L.fs_label, .red);

    if (comptime !is_android) {
        rl.drawText("Tab: switch field   Enter: submit",
            c.L.pad, c.sh - c.L.fs_small - c.L.pad, c.L.fs_small, .dark_gray);
    }

    // Back button in header when reached from browser
    if (self.sync_from_browser) {
        rl.drawRectangle(0, 0, c.sw, c.L.hdr_h, .{ .r = 20, .g = 20, .b = 30, .a = 255 });
        rl.drawText("< Back", c.L.pad, @divTrunc(c.L.hdr_h - c.L.fs_body, 2), c.L.fs_body, .sky_blue);
    }
}

fn drawSyncRunning(_: *Self, c: Ctx) void {
    rl.drawText("Loki Sync", c.L.pad, c.L.pad * 2, c.L.fs_hdr, .white);
    const dot_count = @as(usize, @intCast(@mod(@as(i64, @intFromFloat(rl.getTime() * 3)), 4)));
    const dots = [4][:0]const u8{ "", ".", "..", "..." };
    var sbuf: [64:0]u8 = std.mem.zeroes([64:0]u8);
    const base_label: [:0]const u8 = switch (sync.g_status.load(.acquire)) {
        .connecting => "Connecting",
        .syncing => "Syncing",
        else => "Please wait",
    };
    _ = std.fmt.bufPrintZ(&sbuf, "{s}{s}", .{ base_label, dots[dot_count] }) catch {};
    const stw = rl.measureText(&sbuf, c.L.fs_body);
    rl.drawText(&sbuf, @divTrunc(c.sw - stw, 2), @divTrunc(c.sh, 2), c.L.fs_body, .yellow);
}

fn drawSyncResult(_: *Self, c: Ctx) void {
    rl.drawText("Loki Sync", c.L.pad, c.L.pad * 2, c.L.fs_hdr, .white);
    const result_y = @divTrunc(c.sh, 4);
    const btn_y = c.sh - c.L.btn_h - c.L.pad;
    switch (sync.g_status.load(.acquire)) {
        .done => {
            rl.drawText("Sync complete!", c.L.pad, result_y, c.L.fs_body, .green);
            rl.drawText(&sync.g_msg_buf, c.L.pad, result_y + c.L.fs_body + c.L.pad, c.L.fs_label, .green);
            if (sync.g_conflict_count > 0) {
                var cbuf: [128:0]u8 = std.mem.zeroes([128:0]u8);
                _ = std.fmt.bufPrintZ(&cbuf, "{d} conflict(s) — server version kept", .{sync.g_conflict_count}) catch {};
                rl.drawText(&cbuf, c.L.pad,
                    result_y + c.L.fs_body + c.L.pad + c.L.fs_label + c.L.pad, c.L.fs_label, .orange);
            }
            ui.drawButton("Open DB", c.L.pad, btn_y, c.sw - 2 * c.L.pad, c.L.btn_h,
                .{ .r = 30, .g = 140, .b = 80, .a = 255 });
        },
        .failed => {
            rl.drawText("Sync failed:", c.L.pad, result_y, c.L.fs_body, .red);
            rl.drawText(&sync.g_msg_buf, c.L.pad, result_y + c.L.fs_body + c.L.pad, c.L.fs_label, .red);
            const half_w = @divTrunc(c.sw - 3 * c.L.pad, 2);
            ui.drawButton("Back", c.L.pad, btn_y, half_w, c.L.btn_h,
                .{ .r = 70, .g = 70, .b = 90, .a = 255 });
            ui.drawButton("Retry", 2 * c.L.pad + half_w, btn_y, half_w, c.L.btn_h,
                .{ .r = 30, .g = 130, .b = 180, .a = 255 });
        },
        else => {},
    }
}
