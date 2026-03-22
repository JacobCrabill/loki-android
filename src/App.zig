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

// ---- Two-tap confirmation button ----

const ConfirmButton = struct {
    pending: bool = false,
    timer: f32 = 0,

    const timeout: f32 = 3.0;

    fn tick(self: *ConfirmButton, dt: f32) void {
        if (self.pending) {
            self.timer -= dt;
            if (self.timer <= 0) self.reset();
        }
    }

    fn arm(self: *ConfirmButton) void {
        self.pending = true;
        self.timer = timeout;
    }

    fn reset(self: *ConfirmButton) void {
        self.pending = false;
        self.timer = 0;
    }
};

// ---- Per-frame context (screen dims, layout, mouse, tap) ----

const Ctx = struct {
    sw: i32,
    sh: i32,
    L: ui.Layout,
    mx: f32, // raw mouse x (window coords)
    my: f32, // raw mouse y (window coords)
    /// Mouse x relative to the content column origin.
    cmx: f32,
    is_tap: bool,

    /// Mouse wheel movement this frame (positive = scroll up / toward user).
    wheel: f32,

    /// Content column left edge (== L.content_x).
    inline fn cx(self: Ctx) i32 {
        return self.L.content_x;
    }
    /// Content column width (== L.content_w).
    inline fn cw(self: Ctx) i32 {
        return self.L.content_w;
    }
    /// Convert a column-relative x to a window-absolute x.
    inline fn ox(self: Ctx, x: i32) i32 {
        return self.L.content_x + x;
    }
};

// ---- Error set for DB open ----

const OpenError = error{ StorageError, WrongPassword, OpenFailed, OutOfMemory };

// ---- State ----

allocator: std.mem.Allocator,
phase: ui.Phase = .unlock,
drag_accum: f32 = 0,

// Unlock
unlock_pw: ui.TextField = .{ .masked = true },
unlock_err: ?[:0]const u8 = null,
unlock_dialog_shown: bool = false,

// Biometric unlock (Android only)
/// True if the device supports strong biometrics (cached at init).
bio_available: bool = false,
/// True if an encrypted credential blob exists on disk.
bio_enrolled: bool = false,
/// True while we're waiting for a biometricAuthenticate() result.
bio_auth_pending: bool = false,
/// True while we're waiting for a biometricEnroll() result.
bio_enroll_pending: bool = false,
/// Non-null error/status message to show on the unlock screen.
bio_err: ?[:0]const u8 = null,
/// When true, bio_err is informational (shown in green); when false, it is an error (orange).
bio_err_is_info: bool = false,

// DB + browser
db: ?loki.Database = null,
rows: std.ArrayListUnmanaged(ui.BrowserRow) = .{},
browser_scroll: f32 = 0,

// Detail
detail_entry: ?loki.Entry = null,
detail_entry_id: [20]u8 = undefined,
detail_head_hash: [20]u8 = undefined,
detail_show_pw: bool = false,
detail_scroll: f32 = 0,
detail_delete_confirm: ConfirmButton = .{},

// History
/// Ordered chain of version hashes: index 0 = current HEAD, last = genesis.
hist_hashes: std.ArrayListUnmanaged([20]u8) = .{},
/// Index into hist_hashes currently being viewed (0 = latest).
hist_idx: usize = 0,
/// The entry version currently shown in the history view.
hist_entry: ?loki.Entry = null,
/// Scroll offset for the history detail view.
hist_scroll: f32 = 0,
/// Whether the history password field is revealed.
hist_show_pw: bool = false,

// Edit
edit_fields: [ui.field_count]ui.TextField = defaultEditFields(),
edit_pending: ?usize = null,
edit_err: ?[:0]const u8 = null,
edit_focus: usize = 0,
edit_scroll: f32 = 0,
edit_notes_scroll: f32 = 0,
edit_is_new: bool = false,
edit_show_pw: bool = false,
drag_in_notes: bool = false,

// Password generator overlay (shown on top of the edit view)
pwgen_open: bool = false,
pwgen_opts: loki.generator.Options = .{},
/// The most recently generated password preview (null-terminated, length <= 128).
pwgen_preview: [loki.generator.MAX_LENGTH + 1]u8 = std.mem.zeroes([loki.generator.MAX_LENGTH + 1]u8),
pwgen_preview_len: usize = 0,

// Sync setup
ip_field: ui.TextField = .{},
sync_pw_field: ui.TextField = .{ .masked = true },
sync_focus_ip: bool = true,
sync_err: ?[:0]const u8 = null,
sync_pending_field: ?bool = null,
first_use: bool = false,
delete_db_err: ?[:0]const u8 = null,
sync_from_browser: bool = false,
delete_confirm: ConfirmButton = .{},
sync_ip_err: bool = false,
sync_pw_err: bool = false,
/// Android only: true while we wait for biometric auth to pre-fill the sync password.
sync_bio_pending: bool = false,

// Search
search_field: ui.TextField = .{},
search_pending: bool = false,
search_focused: bool = false,

// Clipboard toast
copy_feedback_timer: f32 = 0,

// Browser toast (informational messages that show briefly in the browser view)
browser_toast: ?[:0]const u8 = null,
browser_toast_timer: f32 = 0,

// Auto-lock
last_interaction_time: f64 = 0,

// Current directory path in the hierarchical browser
browser_path_buf: [ui.max_field]u8 = std.mem.zeroes([ui.max_field]u8),
browser_path_len: usize = 0,

// ---- Helpers for field defaults ----

fn defaultEditFields() [ui.field_count]ui.TextField {
    var arr: [ui.field_count]ui.TextField = undefined;
    for (0..ui.field_count) |i| arr[i] = .{ .masked = i == ui.PW_IDX };
    return arr;
}

// ---- Lifecycle ----

pub fn init(allocator: std.mem.Allocator) Self {
    var self = Self{ .allocator = allocator };
    self.phase = if (fs.dbDirExists()) .unlock else .sync_setup;
    self.first_use = (self.phase == .sync_setup);
    self.ip_field.setDefault("192.168.1.100");
    load_prefs: {
        var base = fs.openBaseDir() catch break :load_prefs;
        defer if (comptime is_android) base.close();
        var prefs_buf: [ui.max_field]u8 = undefined;
        const n = fs.loadPrefs(base, &prefs_buf);
        if (n > 0) self.ip_field.setDefault(prefs_buf[0..n]);
    }
    if (comptime is_android) {
        self.bio_available = ui.biometricIsAvailable() != 0;
        self.bio_enrolled = self.bio_available and ui.biometricHasEnrolled() != 0;
        // Auto-trigger biometric prompt on launch if a DB exists and we're enrolled.
        if (self.phase == .unlock and self.bio_enrolled) {
            ui.biometricAuthenticate();
            self.bio_auth_pending = true;
        }
    }
    return self;
}

pub fn deinit(self: *Self) void {
    if (self.detail_entry) |e| e.deinit(self.allocator);
    if (self.hist_entry) |e| e.deinit(self.allocator);
    self.hist_hashes.deinit(self.allocator);
    for (self.rows.items) |r| r.deinit(self.allocator);
    self.rows.deinit(self.allocator);
    if (self.db) |*d| d.deinit();
}

fn lock(self: *Self) void {
    if (self.detail_entry) |e| e.deinit(self.allocator);
    self.detail_entry = null;
    if (self.hist_entry) |e| e.deinit(self.allocator);
    self.hist_entry = null;
    self.hist_hashes.clearRetainingCapacity();
    for (self.rows.items) |r| r.deinit(self.allocator);
    self.rows.clearRetainingCapacity();
    if (self.db) |*d| d.deinit();
    self.db = null;
    self.unlock_pw.zeroAndClear();
    self.unlock_pw.masked = true;
    self.unlock_err = null;
    self.unlock_dialog_shown = false;
    self.bio_err = null;
    self.bio_err_is_info = false;
    self.bio_auth_pending = false;
    self.bio_enroll_pending = false;
    self.browser_path_len = 0;
    self.browser_scroll = 0;
    self.phase = .unlock;
    // Re-trigger biometric prompt after lock if enrolled.
    if (comptime is_android) {
        self.bio_enrolled = self.bio_available and ui.biometricHasEnrolled() != 0;
        if (self.bio_enrolled) {
            ui.biometricAuthenticate();
            self.bio_auth_pending = true;
        }
    }
}

// ---- Main per-frame update ----

pub fn update(self: *Self) void {
    const sw = rl.getScreenWidth();
    const sh = rl.getScreenHeight();
    const L = ui.Layout.compute(sw, sh);

    const mouse = rl.getMousePosition();
    const mx = mouse.x;
    const my = mouse.y;

    if (rl.isMouseButtonPressed(.left)) self.drag_accum = 0;
    if (rl.isMouseButtonDown(.left)) self.drag_accum += @abs(rl.getMouseDelta().y);
    const is_tap = rl.isMouseButtonReleased(.left) and self.drag_accum < 10;

    const c = Ctx{
        .sw = sw,
        .sh = sh,
        .L = L,
        .mx = mx,
        .my = my,
        .cmx = mx - @as(f32, @floatFromInt(L.content_x)),
        .wheel = rl.getMouseWheelMove(),
        .is_tap = is_tap,
    };

    // Track last user interaction for auto-lock
    const now = rl.getTime();
    if (rl.isMouseButtonPressed(.left) or rl.isMouseButtonDown(.left) or
        rl.isMouseButtonReleased(.left) or rl.getKeyPressed() != .null)
    {
        self.last_interaction_time = now;
    }
    if (self.last_interaction_time == 0) self.last_interaction_time = now;

    // Auto-lock after 5 minutes of inactivity when DB is open
    const unlocked = switch (self.phase) {
        .browser, .detail, .edit, .history => true,
        else => false,
    };
    if (unlocked and self.db != null and now - self.last_interaction_time > 300.0) {
        self.lock();
    }

    // Tick timers
    const dt = rl.getFrameTime();
    self.delete_confirm.tick(dt);
    self.detail_delete_confirm.tick(dt);
    if (self.copy_feedback_timer > 0) {
        self.copy_feedback_timer -= rl.getFrameTime();
        // Clear the clipboard as soon as the toast timer expires.
        if (self.copy_feedback_timer <= 0) {
            self.copy_feedback_timer = 0;
            rl.setClipboardText("");
        }
    }
    if (self.browser_toast_timer > 0) {
        self.browser_toast_timer -= rl.getFrameTime();
        if (self.browser_toast_timer <= 0) {
            self.browser_toast_timer = 0;
            self.browser_toast = null;
        }
    }

    // Input
    switch (self.phase) {
        .unlock => self.inputUnlock(c),
        .browser => self.inputBrowser(c),
        .detail => self.inputDetail(c),
        .edit => self.inputEdit(c),
        .history => self.inputHistory(c),
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
        .history => self.drawHistory(c),
        .sync_setup => self.drawSyncSetup(c),
        .sync_running => self.drawSyncRunning(c),
        .sync_result => self.drawSyncResult(c),
    }
}

// ---- DB helpers ----

/// Rebuild self.rows from d.listEntries(), freeing any previous rows first.
fn populateRows(self: *Self, d: *loki.Database) !void {
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

fn openDbAndPopulate(self: *Self, pw_slice: []const u8) OpenError!void {
    var base = fs.openBaseDir() catch return error.StorageError;
    defer if (comptime is_android) base.close();

    const password: ?[]const u8 = if (pw_slice.len > 0) pw_slice else null;
    const opened = loki.Database.open(self.allocator, base, fs.db_name, password) catch |err| {
        return if (err == error.WrongPassword) error.WrongPassword else error.OpenFailed;
    };

    if (self.db) |*d| d.deinit();
    self.db = opened;
    try self.populateRows(&self.db.?);
}

fn repopulateRows(self: *Self, d: *loki.Database) !void {
    try self.populateRows(d);
}

// ============================================================
// BROWSER NAVIGATION HELPERS
// ============================================================

/// Maximum number of unique immediate subdirectory names at a single level.
const max_dirs_per_level: usize = 256;

/// Tracks which immediate subdirectory names have already been seen while
/// iterating over sorted rows, to deduplicate directory entries.
const SeenDirs = struct {
    names: [max_dirs_per_level][]const u8 = undefined,
    len: usize = 0,

    fn contains(self: *const SeenDirs, name: []const u8) bool {
        for (self.names[0..self.len]) |s| {
            if (std.mem.eql(u8, s, name)) return true;
        }
        return false;
    }

    /// Returns true if the name was new (not already seen) and was recorded.
    fn add(self: *SeenDirs, name: []const u8) bool {
        if (self.contains(name)) return false;
        if (self.len < max_dirs_per_level) {
            self.names[self.len] = name;
            self.len += 1;
        }
        return true;
    }
};

fn browserPath(self: *const Self) []const u8 {
    return self.browser_path_buf[0..self.browser_path_len];
}

/// Append `dir_name` to the current path (e.g. "Home" + "Banking" → "Home/Banking").
fn navigateInto(self: *Self, dir_name: []const u8) void {
    const cur = self.browserPath();
    var new_len: usize = 0;
    if (cur.len > 0) {
        const n = @min(cur.len, ui.max_field - 1);
        @memcpy(self.browser_path_buf[0..n], cur[0..n]);
        self.browser_path_buf[n] = '/';
        new_len = n + 1;
    }
    const remaining = ui.max_field - new_len;
    const dn = @min(dir_name.len, remaining);
    @memcpy(self.browser_path_buf[new_len .. new_len + dn], dir_name[0..dn]);
    self.browser_path_len = new_len + dn;
    self.browser_scroll = 0;
}

/// Truncate path to parent (e.g. "Social/Twitter" → "Social", "Social" → "").
fn navigateUp(self: *Self) void {
    const cur = self.browserPath();
    if (cur.len == 0) return;
    const last_slash = std.mem.lastIndexOfScalar(u8, cur, '/');
    self.browser_path_len = if (last_slash) |i| i else 0;
    self.browser_scroll = 0;
}

/// If `row_path` is a direct child directory of `parent_path`, return the
/// immediate subdirectory name; otherwise return null.
///
/// Examples (parent=""):
///   row_path="Social"         → "Social"
///   row_path="Social/Twitter" → "Social"
///   row_path=""               → null  (entry at root, not a subdir)
///
/// Examples (parent="Social"):
///   row_path="Social/Twitter" → "Twitter"
///   row_path="Social"         → null  (entry lives IN Social, not a subdir)
///   row_path=""               → null
fn subdirName(row_path: []const u8, parent_path: []const u8) ?[]const u8 {
    const rest = if (parent_path.len == 0) blk: {
        if (row_path.len == 0) return null; // entry is at root, not in a subdir
        break :blk row_path;
    } else blk: {
        // row_path must start with "parent_path/"
        if (row_path.len <= parent_path.len) return null;
        if (!std.mem.eql(u8, row_path[0..parent_path.len], parent_path)) return null;
        if (row_path[parent_path.len] != '/') return null;
        const r = row_path[parent_path.len + 1 ..];
        if (r.len == 0) return null;
        break :blk r;
    };
    // Return the immediate child directory name (up to the first '/', or all of rest).
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash_pos| return rest[0..slash_pos];
    return rest;
}

// ============================================================
// INPUT
// ============================================================

/// Helper: open the DB with the given password slice and transition to browser.
/// On success, zeros `unlock_pw` so the plaintext doesn't linger in App state.
/// Returns true on success.
fn unlockWithPassword(self: *Self, pw: []const u8) bool {
    self.openDbAndPopulate(pw) catch |err| {
        self.unlock_err = switch (err) {
            error.WrongPassword => "Wrong password.",
            else => "Failed to open database.",
        };
        return false;
    };
    if (self.db != null) {
        // Zero the password field immediately — the DB is open, it's no longer needed.
        self.unlock_pw.zeroAndClear();
        self.browser_scroll = 0;
        self.browser_path_len = 0;
        self.phase = .browser;
        return true;
    }
    return false;
}

fn inputUnlock(self: *Self, c: Ctx) void {
    const fw = c.cw() - 2 * c.L.pad;
    const del_btn_h = c.L.detail_btn_h;
    const del_btn_y = c.sh - del_btn_h - c.L.pad;

    // Delete DB (two-tap confirmation) — only when a DB exists
    if (c.is_tap and ui.inRect(c.cmx, c.my, c.L.pad, del_btn_y, fw, del_btn_h)) {
        if (self.delete_confirm.pending) {
            if (self.db) |*d| d.deinit();
            self.db = null;
            for (self.rows.items) |r| r.deinit(self.allocator);
            self.rows.clearRetainingCapacity();
            if (fs.deleteDb()) {
                // Also wipe any biometric enrollment for this DB.
                if (comptime is_android) {
                    if (self.bio_available) ui.biometricClearEnrollment();
                    self.bio_enrolled = false;
                }
                self.delete_db_err = null;
                self.sync_err = null;
                self.sync_from_browser = false;
                self.phase = .sync_setup;
                self.first_use = true;
            } else {
                self.delete_db_err = "Failed to delete database.";
            }
            self.delete_confirm.reset();
        } else {
            self.delete_confirm.arm();
        }
        return;
    }

    if (comptime is_android) {
        // ---- Poll biometric authenticate result ----
        if (self.bio_auth_pending) {
            var rbuf: [ui.max_field + 1]u8 = std.mem.zeroes([ui.max_field + 1]u8);
            const poll = ui.pollBiometricResult(&rbuf, @intCast(rbuf.len));
            if (poll > 0) {
                self.bio_auth_pending = false;
                // poll > 0 means success; length = poll - 1.
                const n: usize = @intCast(poll - 1);
                _ = self.unlockWithPassword(rbuf[0..n]);
                // Zero the stack buffer regardless of whether unlock succeeded.
                @memset(&rbuf, 0);
                if (self.db == null) {
                    // Decryption succeeded but DB open failed — key was probably
                    // invalidated (new biometrics enrolled). Clear enrollment.
                    ui.biometricClearEnrollment();
                    self.bio_enrolled = false;
                    self.bio_err = "Biometric key invalidated. Please re-enroll.";
                    self.bio_err_is_info = false; // error
                }
            } else if (poll < 0) {
                // User cancelled or auth error — fall back to password field.
                self.bio_auth_pending = false;
            }
            // While pending, don't process other input.
            return;
        }

        // ---- Text-input dialog poll (password entry) ----
        var rbuf: [ui.max_field + 1]u8 = std.mem.zeroes([ui.max_field + 1]u8);
        const poll = ui.pollTextInputDialog(&rbuf, @intCast(rbuf.len));
        if (poll > 0) {
            const n: usize = @intCast(poll - 1);
            // Copy into unlock_pw temporarily so unlockWithPassword can use it.
            // unlockWithPassword zeros unlock_pw on success.
            self.unlock_pw.len = n;
            @memcpy(self.unlock_pw.buf[0..n], rbuf[0..n]);
            self.unlock_dialog_shown = false;
            const opened = self.unlockWithPassword(self.unlock_pw.slice());
            // After a successful password unlock, offer to enroll biometrics
            // if available and not yet enrolled.
            if (opened and self.bio_available and !self.bio_enrolled) {
                // Kick off enroll — pass password from rbuf before zeroing it.
                var pw_cstr: [ui.max_field + 1:0]u8 = std.mem.zeroes([ui.max_field + 1:0]u8);
                @memcpy(pw_cstr[0..n], rbuf[0..n]);
                ui.biometricEnroll(&pw_cstr);
                // Zero pw_cstr immediately after the call.
                @memset(&pw_cstr, 0);
                self.bio_enroll_pending = true;
                // We've already transitioned to .browser; enroll runs in background.
            }
            // Zero rbuf regardless of outcome.
            @memset(&rbuf, 0);
        } else if (poll < 0) {
            self.unlock_dialog_shown = false;
        } else if (c.is_tap and !self.unlock_dialog_shown) {
            const field_y = @divTrunc(c.sh * 2, 5);
            const fw2 = c.cw() - 2 * c.L.pad;
            if (ui.inRect(c.cmx, c.my, c.L.pad, field_y, fw2, c.L.fh)) {
                self.unlock_pw.showDialog("Enter password", true);
                self.unlock_dialog_shown = true;
                self.unlock_err = null;
                self.bio_err = null;
            }
        }

        // ---- "Use biometrics" button (visible when enrolled) ----
        if (self.bio_enrolled and !self.unlock_dialog_shown) {
            const bio_btn_y = del_btn_y - del_btn_h - @divTrunc(c.L.pad, 2);
            if (c.is_tap and ui.inRect(c.cmx, c.my, c.L.pad, bio_btn_y, fw, del_btn_h)) {
                ui.biometricAuthenticate();
                self.bio_auth_pending = true;
                self.bio_err = null;
                self.unlock_err = null;
            }
        }
    } else {
        if (rl.isKeyPressed(.backspace)) self.unlock_pw.pop();
        var ch = rl.getCharPressed();
        while (ch != 0) : (ch = rl.getCharPressed()) {
            if (ch >= 32 and ch < 127) self.unlock_pw.append(@intCast(ch));
        }
        const btn_w = c.cw() - 2 * c.L.pad;
        const btn_y = @divTrunc(c.sh * 3, 5);
        const open_pressed = rl.isKeyPressed(.enter) or
            (c.is_tap and ui.inRect(c.cmx, c.my, c.L.pad, btn_y, btn_w, c.L.btn_h));
        if (open_pressed) {
            _ = self.unlockWithPassword(self.unlock_pw.slice());
        }
    }
}

fn inputBrowser(self: *Self, c: Ctx) void {
    if (rl.isMouseButtonDown(.left)) {
        self.browser_scroll -= rl.getMouseDelta().y;
    }
    self.browser_scroll -= c.wheel * @as(f32, @floatFromInt(c.L.row_h));

    // Poll biometric enroll result (enroll fires after a successful password unlock
    // while the user is already in the browser view).
    if (comptime is_android) {
        if (self.bio_enroll_pending) {
            var rbuf: [ui.max_field + 1]u8 = std.mem.zeroes([ui.max_field + 1]u8);
            const poll = ui.pollBiometricResult(&rbuf, @intCast(rbuf.len));
            if (poll > 0) {
                self.bio_enroll_pending = false;
                self.bio_enrolled = true;
                self.browser_toast = "Biometric unlock enabled.";
                self.browser_toast_timer = 3.0;
            } else if (poll < 0) {
                self.bio_enroll_pending = false;
                self.browser_toast = "Biometric enroll cancelled.";
                self.browser_toast_timer = 3.0;
            }
        }
    }

    const search_bar_h = c.L.fh + c.L.pad;
    const list_top = c.L.hdr_h + search_bar_h;
    const is_searching = self.search_field.len > 0;

    if (comptime is_android) {
        if (self.search_pending) {
            var rbuf: [ui.max_field + 1]u8 = undefined;
            const r = ui.pollTextInputDialog(&rbuf, @intCast(rbuf.len));
            if (r > 0) {
                const n: usize = @intCast(r - 1);
                self.search_field.len = n;
                @memcpy(self.search_field.buf[0..n], rbuf[0..n]);
                self.browser_scroll = 0;
                self.search_pending = false;
            } else if (r < 0) {
                self.search_pending = false;
            }
        } else if (c.is_tap and !self.search_pending and
            ui.inRect(c.cmx, c.my, c.L.pad, c.L.hdr_h + @divTrunc(c.L.pad, 2), c.cw() - 2 * c.L.pad, c.L.fh))
        {
            self.search_field.showDialog("Search", false);
            self.search_pending = true;
        }
    } else {
        if (c.is_tap and ui.inRect(c.cmx, c.my, c.L.pad, c.L.hdr_h + @divTrunc(c.L.pad, 2), c.cw() - 2 * c.L.pad, c.L.fh)) {
            self.search_focused = true;
        } else if (c.is_tap) {
            self.search_focused = false;
        }
        if (self.search_focused) {
            if (rl.isKeyPressed(.backspace)) {
                self.search_field.pop();
                self.browser_scroll = 0;
            }
            if (rl.isKeyPressed(.escape)) {
                self.search_field = .{};
                self.search_focused = false;
                self.browser_scroll = 0;
            }
            var ch = rl.getCharPressed();
            while (ch != 0) : (ch = rl.getCharPressed()) {
                if (ch >= 32 and ch < 127) {
                    self.search_field.append(@intCast(ch));
                    self.browser_scroll = 0;
                }
            }
        }
        // Backspace (when not searching) navigates up a directory level
        if (!self.search_focused and rl.isKeyPressed(.backspace)) {
            self.navigateUp();
        }
    }

    // Scroll clamping: count visible rows (dirs + entries) in current view
    var row_count: i32 = 0;
    if (is_searching) {
        for (self.rows.items) |row| {
            if (ui.matchesSearch(row, self.search_field.slice())) row_count += 1;
        }
    } else {
        const cur_path = self.browserPath();
        var seen: SeenDirs = .{};
        for (self.rows.items) |row| {
            if (std.mem.eql(u8, row.path, cur_path)) {
                row_count += 1; // direct entry
            } else if (subdirName(row.path, cur_path)) |dn| {
                if (seen.add(dn)) row_count += 1;
            }
        }
    }
    const content_h: f32 = @floatFromInt(row_count * c.L.row_h);
    const visible_h: f32 = @floatFromInt(c.sh - list_top);
    self.browser_scroll = std.math.clamp(self.browser_scroll, 0, @max(0, content_h - visible_h));

    if (c.is_tap) {
        const fab_size = c.L.fab_size;
        const fab_x = c.cw() - fab_size - c.L.pad;
        const fab_y = c.sh - fab_size - c.L.pad;
        const bot_btn_h = c.L.detail_btn_h;
        const bot_btn_y = fab_y + @divTrunc(fab_size - bot_btn_h, 2);
        const lock_btn_w = c.L.hdr_btn_w;
        const lock_btn_x = c.L.pad;
        const sync_btn_w = c.L.hdr_btn_w;
        const sync_btn_x = lock_btn_x + lock_btn_w + c.L.pad;

        if (ui.inRect(c.cmx, c.my, sync_btn_x, bot_btn_y, sync_btn_w, bot_btn_h)) {
            self.first_use = false;
            self.delete_db_err = null;
            self.sync_err = null;
            self.sync_from_browser = true;
            self.delete_confirm.reset();
            self.sync_pw_field.zeroAndClear();
            self.sync_bio_pending = false;
            self.phase = .sync_setup;
        } else if (ui.inRect(c.cmx, c.my, lock_btn_x, bot_btn_y, lock_btn_w, bot_btn_h)) {
            self.lock();
        } else if (!is_searching and self.browser_path_len > 0 and
            ui.inRect(c.cmx, c.my, 0, 0, c.L.back_btn_w, c.L.hdr_h))
        {
            // "< Back" tap — navigate up
            self.navigateUp();
        } else if (ui.inRect(c.cmx, c.my, fab_x, fab_y, fab_size, fab_size)) {
            for (0..ui.field_count) |fi| self.edit_fields[fi] = .{ .masked = fi == ui.PW_IDX };
            self.edit_fields[ui.PATH_IDX].setDefault(self.browserPath());
            self.edit_is_new = true;
            self.edit_show_pw = false;
            self.edit_pending = null;
            self.edit_err = null;
            self.edit_focus = 0;
            self.edit_scroll = 0;
            self.edit_notes_scroll = 0;
            self.phase = .edit;
        } else if (c.my >= @as(f32, @floatFromInt(list_top))) {
            const rel_y = @as(i32, @intFromFloat(c.my)) - list_top +
                @as(i32, @intFromFloat(self.browser_scroll));
            const idx_i = @divTrunc(rel_y, c.L.row_h);
            if (idx_i >= 0) {
                if (is_searching) {
                    // Flat search result — tap opens detail
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
                } else {
                    // Hierarchical view — build the ordered list the same way drawBrowser does
                    const cur_path = self.browserPath();
                    var visible_i: i32 = 0;
                    var handled = false;
                    var seen2: SeenDirs = .{};
                    // First pass: subdirectories (in order of first appearance)
                    for (self.rows.items) |row| {
                        if (subdirName(row.path, cur_path)) |dn| {
                            if (seen2.add(dn)) {
                                if (visible_i == idx_i) {
                                    self.navigateInto(dn);
                                    handled = true;
                                    break;
                                }
                                visible_i += 1;
                            }
                        }
                    }
                    // Second pass: direct entries
                    if (!handled) {
                        for (self.rows.items) |row| {
                            if (!std.mem.eql(u8, row.path, cur_path)) continue;
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
    }
}

fn inputDetail(self: *Self, c: Ctx) void {
    if (rl.isMouseButtonDown(.left)) {
        self.detail_scroll -= rl.getMouseDelta().y;
    }
    self.detail_scroll -= c.wheel * @as(f32, @floatFromInt(c.L.detail_row_h));
    self.detail_scroll = @max(0, self.detail_scroll);
    if (comptime !is_android) {
        if (rl.isKeyPressed(.h)) self.detail_show_pw = !self.detail_show_pw;
        if (rl.isKeyPressed(.escape) or rl.isKeyPressed(.backspace))
            self.phase = .browser;
    }
    const del_btn_h = c.L.detail_btn_h;
    const del_btn_y = c.sh - del_btn_h - c.L.pad;
    const hist_btn_h = c.L.detail_btn_h;
    const hist_btn_y = del_btn_y - hist_btn_h - @divTrunc(c.L.pad, 2);
    if (c.is_tap) {
        if (ui.inRect(c.cmx, c.my, 0, 0, c.L.back_btn_w, c.L.hdr_h)) {
            self.detail_delete_confirm.reset();
            self.phase = .browser;
        } else if (ui.inRect(c.cmx, c.my, c.L.pad, hist_btn_y, c.cw() - 2 * c.L.pad, hist_btn_h)) {
            // "View History" — build chain and enter history phase.
            self.hist_idx = 0;
            self.hist_show_pw = false;
            self.hist_scroll = 0;
            self.loadHistory(self.detail_head_hash);
            self.phase = .history;
        } else if (ui.inRect(c.cmx, c.my, c.cw() - c.L.back_btn_w, 0, c.L.back_btn_w, c.L.hdr_h)) {
            if (self.detail_entry) |e| {
                const vals = [ui.field_count][]const u8{
                    e.title, e.path, e.description, e.url, e.username, e.password, e.notes,
                };
                for (0..ui.field_count) |fi| {
                    self.edit_fields[fi] = .{ .masked = fi == ui.PW_IDX };
                    self.edit_fields[fi].setDefault(vals[fi]);
                }
            }
            self.edit_is_new = false;
            self.edit_show_pw = false;
            self.edit_pending = null;
            self.edit_err = null;
            self.edit_focus = 0;
            self.edit_scroll = 0;
            self.edit_notes_scroll = 0;
            self.phase = .edit;
        } else if (ui.inRect(c.cmx, c.my, c.L.pad, del_btn_y, c.cw() - 2 * c.L.pad, del_btn_h)) {
            if (self.detail_delete_confirm.pending) {
                if (self.db) |*d| {
                    d.deleteEntry(self.detail_entry_id) catch {};
                    d.save() catch {};
                    self.repopulateRows(d) catch {};
                }
                if (self.detail_entry) |e| e.deinit(self.allocator);
                self.detail_entry = null;
                self.detail_delete_confirm.reset();
                self.phase = .browser;
            } else {
                self.detail_delete_confirm.arm();
            }
        } else {
            const scroll_i: i32 = @intFromFloat(self.detail_scroll);
            const toggle_w = c.L.toggle_w;
            const pw_row_y = c.L.hdr_h + c.L.pad + ui.DETAIL_PW_IDX * c.L.detail_row_h - scroll_i;
            if (ui.inRect(c.cmx, c.my, c.cw() - toggle_w - c.L.pad, pw_row_y, toggle_w, c.L.detail_row_h)) {
                self.detail_show_pw = !self.detail_show_pw;
            } else if (c.my >= @as(f32, @floatFromInt(c.L.hdr_h)) and
                c.my < @as(f32, @floatFromInt(del_btn_y)))
            {
                if (self.detail_entry) |e| {
                    const vals = [ui.field_count][]const u8{
                        e.title, e.path, e.description, e.url, e.username, e.password, e.notes,
                    };
                    for (0..ui.field_count) |fi| {
                        const fy = c.L.hdr_h + c.L.pad + @as(i32, @intCast(fi)) * c.L.detail_row_h - scroll_i;
                        if (ui.inRect(c.cmx, c.my, 0, fy, c.cw(), c.L.detail_row_h)) {
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
    // If the generator overlay is open, route all input to it.
    if (self.pwgen_open) {
        self.inputPwGen(c);
        return;
    }

    const notes_h = c.L.detail_row_h * 4;

    // On press, decide whether the drag belongs to the Notes inner scroll or the form scroll.
    if (rl.isMouseButtonPressed(.left)) {
        const si: i32 = @intFromFloat(self.edit_scroll);
        const notes_fy = c.L.hdr_h + @as(i32, @intCast(ui.EDIT_NOTES_IDX)) * c.L.detail_row_h - si;
        self.drag_in_notes = ui.inRect(c.cmx, c.my, 0, notes_fy, c.cw(), notes_h);
    }
    if (rl.isMouseButtonDown(.left)) {
        if (self.drag_in_notes) {
            self.edit_notes_scroll -= rl.getMouseDelta().y;
        } else {
            self.edit_scroll -= rl.getMouseDelta().y;
        }
    }
    self.edit_scroll -= c.wheel * @as(f32, @floatFromInt(c.L.detail_row_h));

    // Clamp form scroll.
    const edit_content_h: f32 = @floatFromInt(6 * c.L.detail_row_h + notes_h);
    const edit_visible_h: f32 = @floatFromInt(c.sh - c.L.hdr_h);
    self.edit_scroll = std.math.clamp(self.edit_scroll, 0, @max(0, edit_content_h - edit_visible_h));

    const enter_pressed = if (comptime !is_android) rl.isKeyPressed(.enter) else false;

    if (comptime is_android) {
        if (self.edit_pending) |fi| {
            var rbuf: [ui.max_field + 1]u8 = undefined;
            const r = ui.pollTextInputDialog(&rbuf, @intCast(rbuf.len));
            if (r > 0) {
                const n: usize = @intCast(r - 1);
                self.edit_fields[fi].len = n;
                @memcpy(self.edit_fields[fi].buf[0..n], rbuf[0..n]);
                self.edit_pending = null;
            } else if (r < 0) {
                self.edit_pending = null;
            }
        }
        if (c.is_tap and self.edit_pending == null) {
            const scroll_i: i32 = @intFromFloat(self.edit_scroll);
            const btn_w = c.L.toggle_w;
            for (0..ui.field_count) |fi| {
                const row_h = if (fi == ui.EDIT_NOTES_IDX) notes_h else c.L.detail_row_h;
                const fy = c.L.hdr_h + @as(i32, @intCast(fi)) * c.L.detail_row_h - scroll_i;
                if (fy >= c.L.hdr_h and ui.inRect(c.cmx, c.my, 0, fy, c.cw(), row_h)) {
                    if (fi == ui.EDIT_PW_IDX and
                        ui.inRect(c.cmx, c.my, c.cw() - btn_w - c.L.pad, fy, btn_w, c.L.detail_row_h))
                    {
                        // Show/Hide toggle (rightmost button)
                        self.edit_show_pw = !self.edit_show_pw;
                    } else if (fi == ui.EDIT_PW_IDX and
                        ui.inRect(c.cmx, c.my, c.cw() - 2 * btn_w - 2 * c.L.pad, fy, btn_w, c.L.detail_row_h))
                    {
                        // Gen button
                        self.pwgenRegenerate();
                        self.pwgen_open = true;
                    } else if (fi == ui.EDIT_NOTES_IDX) {
                        self.edit_fields[fi].showDialogMultiline(ui.edit_field_labels[fi].ptr);
                        self.edit_pending = fi;
                        self.edit_err = null;
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
        if (rl.isKeyPressed(.tab)) self.edit_focus = (self.edit_focus + 1) % ui.field_count;
        if (rl.isKeyPressed(.backspace)) self.edit_fields[self.edit_focus].pop();
        // Enter: insert newline when Notes is focused, otherwise handled as save below
        if (enter_pressed and self.edit_focus == ui.EDIT_NOTES_IDX) {
            self.edit_fields[ui.EDIT_NOTES_IDX].append('\n');
        }
        var ch = rl.getCharPressed();
        while (ch != 0) : (ch = rl.getCharPressed()) {
            if (ch >= 32 and ch < 127) self.edit_fields[self.edit_focus].append(@intCast(ch));
        }
        // After typing in Notes, scroll to end to keep cursor visible.
        if (self.edit_focus == ui.EDIT_NOTES_IDX) {
            self.edit_notes_scroll = std.math.floatMax(f32); // clamped to max on next frame
        }
        // 'g' key opens the password generator when password field is focused.
        if (rl.isKeyPressed(.g) and self.edit_focus == ui.EDIT_PW_IDX) {
            self.pwgenRegenerate();
            self.pwgen_open = true;
        }
        if (c.is_tap) {
            const scroll_i: i32 = @intFromFloat(self.edit_scroll);
            const btn_w = c.L.toggle_w;
            for (0..ui.field_count) |fi| {
                const row_h = if (fi == ui.EDIT_NOTES_IDX) notes_h else c.L.detail_row_h;
                const fy = c.L.hdr_h + @as(i32, @intCast(fi)) * c.L.detail_row_h - scroll_i;
                if (ui.inRect(c.cmx, c.my, 0, fy, c.cw(), row_h)) {
                    // Check Gen button tap on password row.
                    if (fi == ui.EDIT_PW_IDX and
                        ui.inRect(c.cmx, c.my, c.cw() - btn_w - c.L.pad, fy, btn_w, c.L.detail_row_h))
                    {
                        self.pwgenRegenerate();
                        self.pwgen_open = true;
                    } else {
                        self.edit_focus = fi;
                    }
                    break;
                }
            }
        }
        if (rl.isKeyPressed(.escape)) self.phase = .detail;
    }

    // Clamp Notes inner scroll (after input so floatMax auto-scroll is resolved here).
    const notes_fs = c.L.fs_body;
    const notes_line_spacing = notes_fs + @divTrunc(notes_fs, 3);
    const notes_text_top_offset = c.L.pad + c.L.fs_label + @divTrunc(c.L.pad, 2);
    const notes_visible_h = notes_h - notes_text_top_offset;
    var notes_line_count: i32 = 1;
    for (self.edit_fields[ui.EDIT_NOTES_IDX].buf[0..self.edit_fields[ui.EDIT_NOTES_IDX].len]) |ch| {
        if (ch == '\n') notes_line_count += 1;
    }
    const notes_content_h: f32 = @floatFromInt(notes_line_count * notes_line_spacing);
    self.edit_notes_scroll = std.math.clamp(
        self.edit_notes_scroll,
        0,
        @max(0, notes_content_h - @as(f32, @floatFromInt(notes_visible_h))),
    );

    // Cancel / Save (both platforms)
    const hdr_btn_w = c.L.hdr_btn_w;
    if (c.is_tap and ui.inRect(c.cmx, c.my, 0, 0, hdr_btn_w, c.L.hdr_h)) {
        self.edit_err = null;
        self.phase = .detail;
    }
    const do_save = c.is_tap and ui.inRect(c.cmx, c.my, c.cw() - hdr_btn_w, 0, hdr_btn_w, c.L.hdr_h);
    // Enter saves unless Notes is focused (where it inserts a newline instead)
    const do_save_key = enter_pressed and self.edit_focus != ui.EDIT_NOTES_IDX;
    if (do_save or do_save_key) self.doSave();
}

fn doSave(self: *Self) void {
    const d = if (self.db) |*d_| d_ else {
        self.edit_err = "No database.";
        return;
    };
    const new_entry = loki.Entry{
        .parent_hash = if (self.edit_is_new) null else self.detail_head_hash,
        .title = self.edit_fields[ui.TITLE_IDX].slice(),
        .path = self.edit_fields[ui.PATH_IDX].slice(),
        .description = self.edit_fields[ui.DESC_IDX].slice(),
        .url = self.edit_fields[ui.URL_IDX].slice(),
        .username = self.edit_fields[ui.USERNAME_IDX].slice(),
        .password = self.edit_fields[ui.PW_IDX].slice(),
        .notes = self.edit_fields[ui.NOTES_IDX].slice(),
    };
    if (self.edit_is_new) {
        _ = d.createEntry(new_entry) catch {
            self.edit_err = "Save failed.";
            return;
        };
        d.save() catch {
            self.edit_err = "Save failed.";
            return;
        };
        self.repopulateRows(d) catch {
            self.edit_err = "Save failed.";
            return;
        };
        self.browser_scroll = 0;
        self.phase = .browser;
    } else {
        _ = d.updateEntry(self.detail_entry_id, new_entry) catch {
            self.edit_err = "Save failed.";
            return;
        };
        d.save() catch {
            self.edit_err = "Save failed.";
            return;
        };
        self.repopulateRows(d) catch {
            self.edit_err = "Save failed.";
            return;
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

/// Populate hist_hashes with the full version chain starting from `head_hash`.
/// Index 0 = latest (head), last = genesis.  Also loads hist_entry for the
/// given index.  Caller must have cleared/deinited previous hist state first.
fn loadHistory(self: *Self, head_hash: [20]u8) void {
    self.hist_hashes.clearRetainingCapacity();
    if (self.hist_entry) |e| e.deinit(self.allocator);
    self.hist_entry = null;

    const d = if (self.db) |*d_| d_ else return;

    // Walk the parent_hash chain from HEAD to genesis.
    var cur_hash: [20]u8 = head_hash;
    while (true) {
        self.hist_hashes.append(self.allocator, cur_hash) catch break;
        const ver = d.getVersion(cur_hash) catch break;
        const maybe_parent = ver.parent_hash;
        ver.deinit(self.allocator);
        if (maybe_parent) |p| {
            cur_hash = p;
        } else {
            break;
        }
    }

    // Load the entry for the current index.
    self.loadHistEntry();
}

/// Load (or reload) hist_entry for hist_idx.
fn loadHistEntry(self: *Self) void {
    if (self.hist_entry) |e| e.deinit(self.allocator);
    self.hist_entry = null;
    if (self.hist_idx >= self.hist_hashes.items.len) return;
    const d = if (self.db) |*d_| d_ else return;
    self.hist_entry = d.getVersion(self.hist_hashes.items[self.hist_idx]) catch null;
}

fn inputHistory(self: *Self, c: Ctx) void {
    if (rl.isMouseButtonDown(.left)) {
        self.hist_scroll -= rl.getMouseDelta().y;
    }
    self.hist_scroll -= c.wheel * @as(f32, @floatFromInt(c.L.detail_row_h));
    self.hist_scroll = @max(0, self.hist_scroll);

    if (comptime !is_android) {
        if (rl.isKeyPressed(.h)) self.hist_show_pw = !self.hist_show_pw;
        if (rl.isKeyPressed(.escape) or rl.isKeyPressed(.backspace)) {
            // Return to latest version in normal detail view.
            self.phase = .detail;
        }
    }

    if (c.is_tap) {
        const hdr_btn_w = c.L.hdr_btn_w;
        const btn_h = c.L.detail_btn_h;
        const bar_y = c.sh - btn_h - c.L.pad;
        const third_w = @divTrunc(c.cw() - 4 * c.L.pad, 3);

        // "Prev" button — go to an older version (higher index).
        const prev_x = c.L.pad;
        const has_prev = self.hist_idx + 1 < self.hist_hashes.items.len;
        if (has_prev and ui.inRect(c.cmx, c.my, prev_x, bar_y, third_w, btn_h)) {
            self.hist_idx += 1;
            self.loadHistEntry();
            self.hist_scroll = 0;
            return;
        }

        // "Next" button — go to a newer version (lower index).
        const next_x = c.L.pad + third_w + c.L.pad + third_w + c.L.pad;
        const has_next = self.hist_idx > 0;
        if (has_next and ui.inRect(c.cmx, c.my, next_x, bar_y, third_w, btn_h)) {
            self.hist_idx -= 1;
            self.loadHistEntry();
            self.hist_scroll = 0;
            return;
        }

        // "Copy to new entry" button (middle).
        const copy_x = c.L.pad + third_w + c.L.pad;
        if (ui.inRect(c.cmx, c.my, copy_x, bar_y, third_w, btn_h)) {
            self.copyHistEntryToNew();
            return;
        }

        // "< Back" header tap — return to latest version in detail view.
        if (ui.inRect(c.cmx, c.my, 0, 0, hdr_btn_w, c.L.hdr_h)) {
            self.phase = .detail;
            return;
        }

        // Show/Hide password toggle.
        const entry = self.hist_entry orelse return;
        const scroll_i: i32 = @intFromFloat(self.hist_scroll);
        const toggle_w = c.L.toggle_w;
        const pw_row_y = c.L.hdr_h + c.L.pad + ui.DETAIL_PW_IDX * c.L.detail_row_h - scroll_i;
        if (ui.inRect(c.cmx, c.my, c.cw() - toggle_w - c.L.pad, pw_row_y, toggle_w, c.L.detail_row_h)) {
            self.hist_show_pw = !self.hist_show_pw;
            return;
        }

        // Tap any field row to copy value.
        const vals = [ui.field_count][]const u8{
            entry.title, entry.path,     entry.description,
            entry.url,   entry.username, entry.password,
            entry.notes,
        };
        for (0..ui.field_count) |fi| {
            const fy = c.L.hdr_h + c.L.pad + @as(i32, @intCast(fi)) * c.L.detail_row_h - scroll_i;
            if (ui.inRect(c.cmx, c.my, 0, fy, c.cw(), c.L.detail_row_h)) {
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

/// Copy the currently-viewed history entry as a new entry (with "(COPY) " prepended
/// to the title), add it to the index, and navigate to its detail view.
fn copyHistEntryToNew(self: *Self) void {
    const entry = self.hist_entry orelse return;
    const d = if (self.db) |*d_| d_ else return;

    // Build the new title: "(COPY) <original title>"
    var title_buf: [ui.max_field]u8 = undefined;
    const prefix = "(COPY) ";
    const prefix_len = prefix.len;
    @memcpy(title_buf[0..prefix_len], prefix);
    const orig_len = @min(entry.title.len, ui.max_field - prefix_len);
    @memcpy(title_buf[prefix_len .. prefix_len + orig_len], entry.title[0..orig_len]);
    const new_title_len = prefix_len + orig_len;

    const new_entry = loki.Entry{
        .parent_hash = null,
        .title = title_buf[0..new_title_len],
        .path = entry.path,
        .description = entry.description,
        .url = entry.url,
        .username = entry.username,
        .password = entry.password,
        .notes = entry.notes,
    };

    const new_id = d.createEntry(new_entry) catch return;
    d.save() catch return;
    self.repopulateRows(d) catch return;

    // Navigate to the new entry's detail view (outside history).
    if (self.detail_entry) |e| e.deinit(self.allocator);
    self.detail_entry = d.getEntry(new_id) catch null;
    self.detail_entry_id = new_id;
    self.detail_head_hash = new_id; // genesis: head == entry_id
    self.detail_show_pw = false;
    self.detail_scroll = 0;
    self.detail_delete_confirm.reset();
    self.phase = .detail;
}

// ============================================================
// PASSWORD GENERATOR OVERLAY
// ============================================================

/// Regenerate the preview password from the current generator settings.
fn pwgenRegenerate(self: *Self) void {
    const result = loki.generator.generate(self.pwgen_opts, self.pwgen_preview[0..self.pwgen_opts.length]);
    self.pwgen_preview_len = result.len;
    self.pwgen_preview[result.len] = 0;
}

/// Accept the generated password: write it into the password edit field and close.
fn pwgenAccept(self: *Self) void {
    const n = @min(self.pwgen_preview_len, ui.max_field);
    self.edit_fields[ui.EDIT_PW_IDX].len = n;
    @memcpy(self.edit_fields[ui.EDIT_PW_IDX].buf[0..n], self.pwgen_preview[0..n]);
    self.pwgen_open = false;
}

/// Handle taps/keys for the password generator overlay.
fn inputPwGen(self: *Self, c: Ctx) void {
    // The overlay is a vertically-centred card.  Compute its geometry the same
    // way drawPwGen does so hit-testing is consistent.
    const card_w = c.cw() - 4 * c.L.pad;
    const row_h = c.L.btn_h;
    // Rows: title, length, upper, lower, digits, symbols, preview, accept = 8
    const n_rows: i32 = 8;
    const card_h = c.L.pad + c.L.fs_hdr + c.L.pad + n_rows * row_h + @divTrunc(c.L.pad, 2) * (n_rows - 1) + c.L.pad;
    const card_x = c.cx() + 2 * c.L.pad;
    const card_y = @divTrunc(c.sh - card_h, 2);

    // On desktop, handle keyboard shortcuts.
    if (comptime !is_android) {
        if (rl.isKeyPressed(.escape)) {
            self.pwgen_open = false;
            return;
        }
        if (rl.isKeyPressed(.r)) {
            self.pwgenRegenerate();
            return;
        }
        if (rl.isKeyPressed(.enter)) {
            self.pwgenAccept();
            return;
        }
        if (rl.isKeyPressed(.left) or rl.isKeyPressed(.minus)) {
            if (self.pwgen_opts.length > loki.generator.MIN_LENGTH) {
                self.pwgen_opts.length -= 1;
                self.pwgenRegenerate();
            }
            return;
        }
        if (rl.isKeyPressed(.right) or rl.isKeyPressed(.equal)) {
            if (self.pwgen_opts.length < loki.generator.MAX_LENGTH) {
                self.pwgen_opts.length += 1;
                self.pwgenRegenerate();
            }
            return;
        }
    }

    if (!c.is_tap) return;

    // Tap outside the card → close.
    if (!ui.inRect(c.cmx, c.my, card_x, card_y, card_w, card_h)) {
        self.pwgen_open = false;
        return;
    }

    // Content starts below the title.
    const content_y = card_y + c.L.pad + c.L.fs_hdr + c.L.pad;
    const row_stride = row_h + @divTrunc(c.L.pad, 2);

    // Row 0: length  — left/right half-buttons to decrement/increment.
    const r0_y = content_y;
    if (ui.inRect(c.cmx, c.my, card_x, r0_y, card_w, row_h)) {
        const mid_x = card_x + @divTrunc(card_w, 2);
        if (c.mx < @as(f32, @floatFromInt(mid_x))) {
            // Left half → decrement
            if (self.pwgen_opts.length > loki.generator.MIN_LENGTH) {
                self.pwgen_opts.length -= 1;
                self.pwgenRegenerate();
            }
        } else {
            // Right half → increment
            if (self.pwgen_opts.length < loki.generator.MAX_LENGTH) {
                self.pwgen_opts.length += 1;
                self.pwgenRegenerate();
            }
        }
        return;
    }

    // Rows 1–4: checkbox toggles.
    const checkboxes = [4]struct { y: i32, field: *bool }{
        .{ .y = content_y + 1 * row_stride, .field = &self.pwgen_opts.use_upper },
        .{ .y = content_y + 2 * row_stride, .field = &self.pwgen_opts.use_lower },
        .{ .y = content_y + 3 * row_stride, .field = &self.pwgen_opts.use_digits },
        .{ .y = content_y + 4 * row_stride, .field = &self.pwgen_opts.use_symbols },
    };
    for (checkboxes) |cb| {
        if (ui.inRect(c.cmx, c.my, card_x, cb.y, card_w, row_h)) {
            cb.field.* = !cb.field.*;
            self.pwgenRegenerate();
            return;
        }
    }

    // Row 5: preview — tap regenerates.
    const preview_y = content_y + 5 * row_stride;
    if (ui.inRect(c.cmx, c.my, card_x, preview_y, card_w, row_h)) {
        self.pwgenRegenerate();
        return;
    }

    // Row 6: accept button.
    const accept_y = content_y + 6 * row_stride;
    if (ui.inRect(c.cmx, c.my, card_x, accept_y, card_w, row_h)) {
        self.pwgenAccept();
        return;
    }

    // Row 7: cancel button.
    const cancel_y = content_y + 7 * row_stride;
    if (ui.inRect(c.cmx, c.my, card_x, cancel_y, card_w, row_h)) {
        self.pwgen_open = false;
        return;
    }
}

/// Draw the password generator overlay card.
fn drawPwGen(self: *Self, c: Ctx) void {
    // Dim the full window background (intentionally full-screen, not just the column).
    rl.drawRectangle(0, 0, c.sw, c.sh, .{ .r = 0, .g = 0, .b = 0, .a = 160 });

    const card_w = c.cw() - 4 * c.L.pad;
    const row_h = c.L.btn_h;
    const n_rows: i32 = 8;
    const card_h = c.L.pad + c.L.fs_hdr + c.L.pad + n_rows * row_h + @divTrunc(c.L.pad, 2) * (n_rows - 1) + c.L.pad;
    const card_x = c.cx() + 2 * c.L.pad;
    const card_y = @divTrunc(c.sh - card_h, 2);

    // Card background + border.
    rl.drawRectangle(card_x, card_y, card_w, card_h, .{ .r = 22, .g = 24, .b = 36, .a = 255 });
    rl.drawRectangleLines(card_x, card_y, card_w, card_h, .{ .r = 60, .g = 80, .b = 130, .a = 255 });

    // Title.
    const title = "Generate Password";
    const title_tw = ui.measureText(title, c.L.fs_hdr);
    ui.drawText(title, card_x + @divTrunc(card_w - title_tw, 2), card_y + c.L.pad, c.L.fs_hdr, .white);

    const content_y = card_y + c.L.pad + c.L.fs_hdr + c.L.pad;
    const row_stride = row_h + @divTrunc(c.L.pad, 2);
    const inner_x = card_x + c.L.pad;
    const inner_w = card_w - 2 * c.L.pad;

    // Row 0: Length control  [−]  20  [+]
    {
        const ry = content_y;
        rl.drawRectangle(card_x, ry, card_w, row_h, .{ .r = 30, .g = 32, .b = 48, .a = 255 });
        const dec_w = @divTrunc(inner_w, 5);
        const inc_w = dec_w;
        const mid_w = inner_w - dec_w - inc_w;
        ui.drawButton("-", inner_x, ry, dec_w, row_h, .{ .r = 50, .g = 60, .b = 90, .a = 255 });
        ui.drawButton("+", inner_x + dec_w + mid_w, ry, inc_w, row_h, .{ .r = 50, .g = 60, .b = 90, .a = 255 });
        // Centre label
        var lbuf: [16:0]u8 = std.mem.zeroes([16:0]u8);
        _ = std.fmt.bufPrintZ(&lbuf, "Length: {d}", .{self.pwgen_opts.length}) catch {};
        const ltw = ui.measureText(&lbuf, c.L.fs_body);
        ui.drawText(&lbuf, inner_x + dec_w + @divTrunc(mid_w - ltw, 2), ry + @divTrunc(row_h - c.L.fs_body, 2), c.L.fs_body, .white);
    }

    // Rows 1–4: checkboxes.
    const checkbox_rows = [4]struct { label: [:0]const u8, val: bool }{
        .{ .label = "Uppercase (A-Z)", .val = self.pwgen_opts.use_upper },
        .{ .label = "Lowercase (a-z)", .val = self.pwgen_opts.use_lower },
        .{ .label = "Digits (0-9)", .val = self.pwgen_opts.use_digits },
        .{ .label = "Symbols (!@#…)", .val = self.pwgen_opts.use_symbols },
    };
    for (checkbox_rows, 0..) |row, i| {
        const ry = content_y + @as(i32, @intCast(i + 1)) * row_stride;
        const bg: rl.Color = if (i % 2 == 0)
            .{ .r = 26, .g = 28, .b = 42, .a = 255 }
        else
            .{ .r = 30, .g = 32, .b = 48, .a = 255 };
        rl.drawRectangle(card_x, ry, card_w, row_h, bg);
        // Checkbox indicator.
        const box_size = @divTrunc(row_h * 2, 3);
        const box_x = inner_x;
        const box_y = ry + @divTrunc(row_h - box_size, 2);
        rl.drawRectangle(box_x, box_y, box_size, box_size, .{ .r = 40, .g = 50, .b = 80, .a = 255 });
        rl.drawRectangleLines(box_x, box_y, box_size, box_size, .{ .r = 100, .g = 120, .b = 180, .a = 255 });
        if (row.val) {
            // Filled checkmark.
            rl.drawRectangle(box_x + 2, box_y + 2, box_size - 4, box_size - 4, .{ .r = 60, .g = 200, .b = 100, .a = 255 });
        }
        const label_x = inner_x + box_size + @divTrunc(c.L.pad, 2);
        ui.drawText(row.label, label_x, ry + @divTrunc(row_h - c.L.fs_body, 2), c.L.fs_body, .white);
    }

    // Row 5: preview (tap to regenerate).
    {
        const ry = content_y + 5 * row_stride;
        rl.drawRectangle(card_x, ry, card_w, row_h, .{ .r = 18, .g = 22, .b = 38, .a = 255 });
        rl.drawRectangleLines(card_x, ry, card_w, row_h, .{ .r = 50, .g = 70, .b = 110, .a = 255 });
        // Show preview (masked stars if password mode, but for generation show it plainly
        // so the user can verify what they're getting).
        const prev_cstr: *const [129:0]u8 = @ptrCast(&self.pwgen_preview);
        const ptw = ui.measureText(prev_cstr, c.L.fs_body);
        const avail = inner_w - c.L.pad;
        if (ptw <= avail) {
            ui.drawText(prev_cstr, inner_x, ry + @divTrunc(row_h - c.L.fs_body, 2), c.L.fs_body, .{ .r = 255, .g = 200, .b = 100, .a = 255 });
        } else {
            // Too wide: show as many chars as fit from the right (most unique end).
            var n: usize = self.pwgen_preview_len;
            while (n > 0) {
                n -= 1;
                var tbuf: [129:0]u8 = std.mem.zeroes([129:0]u8);
                @memcpy(tbuf[0..n], self.pwgen_preview[self.pwgen_preview_len - n ..][0..n]);
                if (ui.measureText(&tbuf, c.L.fs_body) <= avail) {
                    ui.drawText(&tbuf, inner_x, ry + @divTrunc(row_h - c.L.fs_body, 2), c.L.fs_body, .{ .r = 255, .g = 200, .b = 100, .a = 255 });
                    break;
                }
            }
        }
        // "↻" regen hint on right side.
        const regen_hint = "Tap to regen";
        ui.drawText(regen_hint, card_x + card_w - c.L.pad - ui.measureText(regen_hint, c.L.fs_small), ry + @divTrunc(row_h - c.L.fs_small, 2), c.L.fs_small, .gray);
    }

    // Row 6: Use this password button.
    {
        const ry = content_y + 6 * row_stride;
        ui.drawButton("Use this password", card_x, ry, card_w, row_h, .{ .r = 30, .g = 140, .b = 80, .a = 255 });
    }

    // Row 7: Cancel button.
    {
        const ry = content_y + 7 * row_stride;
        ui.drawButton("Cancel", card_x, ry, card_w, row_h, .{ .r = 80, .g = 40, .b = 40, .a = 255 });
    }

    if (comptime !is_android) {
        const hint = "r: regen  Enter: use  Esc: cancel  ←/→: length";
        ui.drawText(hint, card_x, card_y + card_h + @divTrunc(c.L.pad, 2), c.L.fs_small, .dark_gray);
    }
}

fn inputSyncSetup(self: *Self, c: Ctx) void {
    // ---- Biometric pre-fill poll (Android, sync-from-browser only) ----
    if (comptime is_android) {
        if (self.sync_bio_pending) {
            var rbuf: [ui.max_field + 1]u8 = std.mem.zeroes([ui.max_field + 1]u8);
            const poll = ui.pollBiometricResult(&rbuf, @intCast(rbuf.len));
            if (poll > 0) {
                // Success: fill the password field; stay on the form so the
                // user can confirm/edit the IP before pressing Sync.
                self.sync_bio_pending = false;
                const n: usize = @intCast(poll - 1);
                self.sync_pw_field.len = n;
                @memcpy(self.sync_pw_field.buf[0..n], rbuf[0..n]);
                @memset(&rbuf, 0);
                self.sync_pw_err = false;
            } else if (poll < 0) {
                // Cancelled — fall back to manual password entry.
                self.sync_bio_pending = false;
            }
            // While pending, block other input so the user waits for the prompt.
            if (self.sync_bio_pending) return;
        }
    }

    const form_top = if (self.sync_from_browser) c.L.hdr_h + c.L.pad else c.L.pad * 2;
    const fw = c.cw() - 2 * c.L.pad;
    const title_y = form_top;
    const sub_y = title_y + c.L.fs_hdr + c.L.pad;
    const ip_label_y = sub_y + c.L.fs_label + c.L.pad * 2;
    const ip_field_y = ip_label_y + c.L.fs_label + @divTrunc(c.L.pad, 2);
    const pw_label_y = ip_field_y + c.L.fh + c.L.pad;
    const pw_field_y = pw_label_y + c.L.fs_label + @divTrunc(c.L.pad, 2);
    const submit_btn_y = pw_field_y + c.L.fh + c.L.pad * 2;

    if (self.sync_from_browser and c.is_tap and ui.inRect(c.cmx, c.my, 0, 0, c.L.back_btn_w, c.L.hdr_h)) {
        self.sync_from_browser = false;
        self.sync_bio_pending = false;
        self.sync_pw_field.zeroAndClear();
        self.phase = .browser;
    }

    if (rl.isMouseButtonPressed(.left) and self.sync_pending_field == null) {
        if (ui.inRect(c.cmx, c.my, c.L.pad, ip_field_y, fw, c.L.fh)) {
            self.sync_focus_ip = true;
            if (comptime is_android) {
                self.ip_field.showDialog("Server IP", false);
                self.sync_pending_field = true;
            }
        } else if (ui.inRect(c.cmx, c.my, c.L.pad, pw_field_y, fw, c.L.fh)) {
            self.sync_focus_ip = false;
            if (comptime is_android) {
                if (self.sync_from_browser and self.bio_enrolled and self.sync_pw_field.len == 0) {
                    // "Use biometrics" button tapped — trigger auth.
                    ui.biometricAuthenticate();
                    self.sync_bio_pending = true;
                    self.sync_pw_err = false;
                } else {
                    self.sync_pw_field.showDialog("Password", true);
                    self.sync_pending_field = false;
                }
            }
        }
    }

    if (comptime is_android) {
        if (self.sync_pending_field) |is_ip| {
            var rbuf: [ui.max_field + 1]u8 = undefined;
            const r = ui.pollTextInputDialog(&rbuf, @intCast(rbuf.len));
            if (r > 0) {
                const field = if (is_ip) &self.ip_field else &self.sync_pw_field;
                const n: usize = @intCast(r - 1);
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

    // Create new local DB (first use only)
    const create_btn_y = submit_btn_y + c.L.btn_h + c.L.pad;
    if (self.first_use and c.is_tap and ui.inRect(c.cmx, c.my, c.L.pad, create_btn_y, fw, c.L.btn_h)) {
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
                self.allocator,
                base,
                fs.db_name,
                self.sync_pw_field.slice(),
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
            self.browser_path_len = 0;
            self.phase = .browser;
        }
    }

    // Sync / Fetch submit
    const clicked_submit = rl.isMouseButtonPressed(.left) and
        ui.inRect(c.cmx, c.my, c.L.pad, submit_btn_y, fw, c.L.btn_h);
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
            // Zero the field immediately — the password is now in sync.g_pw.
            self.sync_pw_field.zeroAndClear();
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
        // Use the password from sync.g_pw — sync_pw_field was zeroed after submit.
        self.openDbAndPopulate(sync.g_pw[0..sync.g_pw_len]) catch {};
        @memset(&sync.g_pw, 0);
        sync.g_pw_len = 0;
        if (self.db != null) {
            self.browser_scroll = 0;
            self.browser_path_len = 0;
            self.phase = .browser;
        } else {
            self.phase = .sync_result;
        }
    } else if (s == .failed) {
        @memset(&sync.g_pw, 0);
        sync.g_pw_len = 0;
        self.phase = .sync_result;
    }
}

fn inputSyncResult(self: *Self, c: Ctx) void {
    const btn_y = c.sh - c.L.btn_h - c.L.pad;
    const status = sync.g_status.load(.acquire);
    if (status == .done) {
        if (c.is_tap and ui.inRect(c.cmx, c.my, c.L.pad, btn_y, c.cw() - 2 * c.L.pad, c.L.btn_h)) {
            self.unlock_pw.zeroAndClear();
            self.unlock_pw.masked = true;
            self.unlock_err = null;
            self.unlock_dialog_shown = false;
            self.phase = .unlock;
        }
    } else if (status == .failed) {
        const half_w = @divTrunc(c.cw() - 3 * c.L.pad, 2);
        if (c.is_tap and ui.inRect(c.cmx, c.my, c.L.pad, btn_y, half_w, c.L.btn_h)) {
            self.sync_err = null;
            self.phase = .sync_setup;
        } else if (c.is_tap and ui.inRect(c.cmx, c.my, 2 * c.L.pad + half_w, btn_y, half_w, c.L.btn_h)) {
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
    const title_tw = ui.measureText("Loki", c.L.fs_hdr * 2);
    ui.drawText("Loki", c.cx() + @divTrunc(c.cw() - title_tw, 2), title_y, c.L.fs_hdr * 2, .white);

    const sub = "Enter password to open your database.";
    const sub_tw = ui.measureText(sub, c.L.fs_label);
    ui.drawText(sub, c.cx() + @divTrunc(c.cw() - sub_tw, 2), title_y + c.L.fs_hdr * 2 + c.L.pad, c.L.fs_label, .gray);

    const field_y = @divTrunc(c.sh * 2, 5);
    const fw = c.cw() - 2 * c.L.pad;
    ui.drawTextField(&self.unlock_pw, c.cx() + c.L.pad, field_y, fw, c.L.fh, true, false);

    if (self.unlock_err) |msg| {
        const etw = ui.measureText(msg, c.L.fs_label);
        ui.drawText(msg, c.cx() + @divTrunc(c.cw() - etw, 2), field_y + c.L.fh + c.L.pad, c.L.fs_label, .orange);
    }

    if (comptime !is_android) {
        const btn_y = @divTrunc(c.sh * 3, 5);
        ui.drawButton("Open", c.cx() + c.L.pad, btn_y, fw, c.L.btn_h, .{ .r = 30, .g = 140, .b = 200, .a = 255 });
        ui.drawText("Enter: open", c.cx() + c.L.pad, c.sh - c.L.fs_small * 2 - c.L.pad * 2, c.L.fs_small, .dark_gray);
    }

    // Delete DB button at bottom
    const del_btn_h = c.L.detail_btn_h;
    const del_btn_y = c.sh - del_btn_h - c.L.pad;
    if (self.delete_confirm.pending) {
        ui.drawButton("Tap again to confirm delete", c.cx() + c.L.pad, del_btn_y, fw, del_btn_h, .{ .r = 220, .g = 30, .b = 30, .a = 255 });
    } else {
        ui.drawButton("Delete DB", c.cx() + c.L.pad, del_btn_y, fw, del_btn_h, .{ .r = 120, .g = 30, .b = 30, .a = 255 });
    }
    if (self.delete_db_err) |msg| {
        ui.drawText(msg, c.cx() + c.L.pad, del_btn_y - c.L.fs_label - c.L.pad, c.L.fs_label, .red);
    }

    // Biometric button and status (Android only, when enrolled or auth pending).
    if (comptime is_android) {
        const bio_btn_y = del_btn_y - del_btn_h - @divTrunc(c.L.pad, 2);

        if (self.bio_auth_pending) {
            // Show a "waiting" indicator while the system prompt is up.
            ui.drawButton("Waiting for biometrics...", c.cx() + c.L.pad, bio_btn_y, fw, del_btn_h, .{ .r = 40, .g = 80, .b = 140, .a = 180 });
        } else if (self.bio_enrolled) {
            ui.drawButton("Unlock with biometrics", c.cx() + c.L.pad, bio_btn_y, fw, del_btn_h, .{ .r = 40, .g = 80, .b = 160, .a = 255 });
        }

        // Biometric status / error message.
        if (self.bio_err) |msg| {
            const color: rl.Color = if (self.bio_err_is_info)
                .{ .r = 80, .g = 200, .b = 120, .a = 255 }
            else
                .orange;
            const etw = ui.measureText(msg, c.L.fs_label);
            const msg_y = if (self.bio_enrolled or self.bio_auth_pending)
                bio_btn_y - c.L.fs_label - @divTrunc(c.L.pad, 2)
            else
                del_btn_y - c.L.fs_label - c.L.pad;
            ui.drawText(msg, c.cx() + @divTrunc(c.cw() - etw, 2), msg_y, c.L.fs_label, color);
        }
    }
}

fn drawBrowser(self: *Self, c: Ctx) void {
    const search_bar_h = c.L.fh + c.L.pad;
    const list_top = c.L.hdr_h + search_bar_h;
    const is_searching = self.search_field.len > 0;
    var draw_idx: i32 = 0;
    var any_visible = false;

    if (is_searching) {
        // Flat search results
        for (self.rows.items) |row| {
            if (!ui.matchesSearch(row, self.search_field.slice())) continue;
            any_visible = true;
            const row_y = list_top + draw_idx * c.L.row_h -
                @as(i32, @intFromFloat(self.browser_scroll));
            draw_idx += 1;
            if (row_y + c.L.row_h <= list_top or row_y > c.sh) continue;

            const bg: rl.Color = if (@mod(draw_idx, 2) == 0)
                .{ .r = 18, .g = 18, .b = 28, .a = 255 }
            else
                .{ .r = 24, .g = 24, .b = 36, .a = 255 };
            rl.drawRectangle(c.cx(), row_y, c.cw(), c.L.row_h, bg);

            if (row_y >= list_top) {
                const text_block_h = if (row.path.len > 0)
                    c.L.fs_body + @divTrunc(c.L.pad, 2) + c.L.fs_small
                else
                    c.L.fs_body;
                const text_y = row_y + @divTrunc(c.L.row_h - text_block_h, 2);
                ui.drawSlice(row.title, c.cx() + c.L.pad, text_y, c.L.fs_body, .white);
                if (row.path.len > 0) {
                    ui.drawSlice(row.path, c.cx() + c.L.pad, text_y + c.L.fs_body + @divTrunc(c.L.pad, 2), c.L.fs_small, .gray);
                }
                ui.drawText(">", c.cx() + c.cw() - c.L.pad - c.L.fs_body, row_y + @divTrunc(c.L.row_h - c.L.fs_body, 2), c.L.fs_body, .dark_gray);
            }
            rl.drawRectangle(c.cx(), row_y + c.L.row_h - 1, c.cw(), 1, .{ .r = 40, .g = 40, .b = 55, .a = 255 });
        }
    } else {
        // Hierarchical view
        const cur_path = self.browserPath();

        // First pass: immediate subdirectories (in stable first-appearance order)
        var seen_draw: SeenDirs = .{};
        for (self.rows.items) |row| {
            const dn = subdirName(row.path, cur_path) orelse continue;
            if (!seen_draw.add(dn)) continue;

            any_visible = true;
            const row_y = list_top + draw_idx * c.L.row_h -
                @as(i32, @intFromFloat(self.browser_scroll));
            draw_idx += 1;
            if (row_y + c.L.row_h <= list_top or row_y > c.sh) continue;

            // Directory row — dark blue background, folder icon "▸", sky-blue name
            rl.drawRectangle(c.cx(), row_y, c.cw(), c.L.row_h, .{ .r = 10, .g = 20, .b = 40, .a = 255 });
            const text_y = row_y + @divTrunc(c.L.row_h - c.L.fs_body, 2);
            ui.drawText("\xef\x83\x9a", c.cx() + c.L.pad, text_y, c.L.fs_body, .sky_blue); // U+F0DA fa-caret_right
            ui.drawSlice(dn, c.cx() + c.L.pad + c.L.fs_body + @divTrunc(c.L.pad, 2), text_y, c.L.fs_body, .sky_blue);
            ui.drawText("/", c.cx() + c.cw() - c.L.pad - c.L.fs_body, text_y, c.L.fs_body, .{ .r = 60, .g = 120, .b = 200, .a = 255 });
            rl.drawRectangle(c.cx(), row_y + c.L.row_h - 1, c.cw(), 1, .{ .r = 30, .g = 50, .b = 80, .a = 255 });
        }

        // Second pass: direct entries in this directory
        for (self.rows.items) |row| {
            if (!std.mem.eql(u8, row.path, cur_path)) continue;
            any_visible = true;
            const row_y = list_top + draw_idx * c.L.row_h -
                @as(i32, @intFromFloat(self.browser_scroll));
            draw_idx += 1;
            if (row_y + c.L.row_h <= list_top or row_y > c.sh) continue;

            const bg: rl.Color = if (@mod(draw_idx, 2) == 0)
                .{ .r = 18, .g = 18, .b = 28, .a = 255 }
            else
                .{ .r = 24, .g = 24, .b = 36, .a = 255 };
            rl.drawRectangle(c.cx(), row_y, c.cw(), c.L.row_h, bg);

            if (row_y >= list_top) {
                const text_y = row_y + @divTrunc(c.L.row_h - c.L.fs_body, 2);
                ui.drawSlice(row.title, c.cx() + c.L.pad, text_y, c.L.fs_body, .white);
                ui.drawText(">", c.cx() + c.cw() - c.L.pad - c.L.fs_body, text_y, c.L.fs_body, .dark_gray);
            }
            rl.drawRectangle(c.cx(), row_y + c.L.row_h - 1, c.cw(), 1, .{ .r = 40, .g = 40, .b = 55, .a = 255 });
        }
    }

    if (!any_visible) {
        const msg: [:0]const u8 = if (is_searching) "No results." else "Empty.";
        ui.drawText(msg, c.cx() + c.L.pad, list_top + c.L.pad, c.L.fs_body, .gray);
    }

    // Header (drawn last so it covers scrolled content)
    rl.drawRectangle(c.cx(), 0, c.cw(), c.L.hdr_h, .{ .r = 20, .g = 20, .b = 30, .a = 255 });

    if (!is_searching and self.browser_path_len > 0) {
        // In a subdirectory: show "< Back" and current dir name
        ui.drawText("< Back", c.cx() + c.L.pad, @divTrunc(c.L.hdr_h - c.L.fs_body, 2), c.L.fs_body, .sky_blue);
        const cur = self.browserPath();
        const last_slash = std.mem.lastIndexOfScalar(u8, cur, '/');
        const dir_name = if (last_slash) |i| cur[i + 1 ..] else cur;
        var dbuf: [ui.max_field + 1:0]u8 = std.mem.zeroes([ui.max_field + 1:0]u8);
        const dn = @min(dir_name.len, ui.max_field);
        @memcpy(dbuf[0..dn], dir_name[0..dn]);
        const dtw = ui.measureText(&dbuf, c.L.fs_hdr);
        ui.drawText(&dbuf, c.cx() + @divTrunc(c.cw() - dtw, 2), @divTrunc(c.L.hdr_h - c.L.fs_hdr, 2), c.L.fs_hdr, .white);
    } else {
        ui.drawText("Loki", c.cx() + c.L.pad, @divTrunc(c.L.hdr_h - c.L.fs_hdr, 2), c.L.fs_hdr, .white);
    }

    // Search bar
    rl.drawRectangle(c.cx(), c.L.hdr_h, c.cw(), search_bar_h, .{ .r = 15, .g = 15, .b = 22, .a = 255 });
    const sf_y = c.L.hdr_h + @divTrunc(c.L.pad, 2);
    ui.drawTextField(&self.search_field, c.cx() + c.L.pad, sf_y, c.cw() - 2 * c.L.pad, c.L.fh, self.search_focused or self.search_field.len > 0, false);
    if (self.search_field.len == 0) {
        ui.drawText("Search...", c.cx() + c.L.pad + 8, sf_y + @divTrunc(c.L.fh - c.L.fs_label, 2), c.L.fs_label, .gray);
    }

    // Bottom bar: Lock + Sync (left), "+" FAB (right)
    const fab_size = c.L.fab_size;
    const fab_x = c.cx() + c.cw() - fab_size - c.L.pad;
    const fab_y = c.sh - fab_size - c.L.pad;
    const lock_btn_w = c.L.hdr_btn_w;
    const sync_btn_w = c.L.hdr_btn_w;
    const small_btn_h = c.L.detail_btn_h;
    const small_btn_y = fab_y; // + @divTrunc(fab_size - small_btn_h, 2);
    ui.drawButton("Lock", c.cx() + c.L.pad, small_btn_y, lock_btn_w, small_btn_h, .{ .r = 70, .g = 70, .b = 90, .a = 255 });
    ui.drawButton("Sync", c.cx() + c.L.pad + lock_btn_w + c.L.pad, small_btn_y, sync_btn_w, small_btn_h, .{ .r = 30, .g = 130, .b = 180, .a = 255 });
    ui.drawButton("+", fab_x, small_btn_y, small_btn_h, small_btn_h, .{ .r = 0, .g = 135, .b = 190, .a = 255 });

    // Browser toast (e.g. biometric enroll result).
    if (self.browser_toast) |msg| {
        const tw = ui.measureText(msg, c.L.fs_label);
        const tpad = c.L.pad;
        const tw2 = tw + tpad * 2;
        const th = c.L.fs_label + tpad;
        const tx = c.cx() + @divTrunc(c.cw() - tw2, 2);
        const ty = fab_y - th - @divTrunc(c.L.pad, 2);
        rl.drawRectangle(tx, ty, tw2, th, .{ .r = 30, .g = 80, .b = 50, .a = 230 });
        ui.drawText(msg, tx + tpad, ty + @divTrunc(tpad, 2), c.L.fs_label, .white);
    }
}

/// Draw the 7 entry fields (shared by drawDetail and drawHistory).
/// `show_pw` controls whether the Password field is revealed.
/// `bottom_clip_y` is the y coordinate below which rows should not be drawn
/// (used to avoid overdrawing pinned buttons at the bottom).
fn drawEntryFields(
    entry: loki.Entry,
    show_pw: bool,
    scroll_i: i32,
    bottom_clip_y: i32,
    c: Ctx,
) void {
    const val_x = c.cx() + c.L.label_w + c.L.pad;
    const toggle_w = c.L.toggle_w;

    const Field = struct { label: []const u8, value: []const u8 };
    const fields = [ui.field_count]Field{
        .{ .label = "Title", .value = entry.title },
        .{ .label = "Path", .value = entry.path },
        .{ .label = "Desc", .value = entry.description },
        .{ .label = "URL", .value = entry.url },
        .{ .label = "Username", .value = entry.username },
        .{ .label = "Password", .value = entry.password },
        .{ .label = "Notes", .value = entry.notes },
    };

    for (fields, 0..) |f, fi| {
        const is_notes = fi == fields.len - 1;
        const fy = c.L.hdr_h + c.L.pad + @as(i32, @intCast(fi)) * c.L.detail_row_h - scroll_i;
        if (fy + c.L.detail_row_h < c.L.hdr_h or fy > bottom_clip_y) continue;

        const bg: rl.Color = if (fi % 2 == 0)
            .{ .r = 18, .g = 18, .b = 28, .a = 255 }
        else
            .{ .r = 26, .g = 26, .b = 38, .a = 255 };
        const draw_h = if (is_notes) @max(c.L.detail_row_h, bottom_clip_y - fy) else c.L.detail_row_h;
        rl.drawRectangle(c.cx(), fy, c.cw(), draw_h, bg);

        ui.drawSlice(f.label, c.cx() + c.L.pad, fy + @divTrunc(c.L.detail_row_h - c.L.fs_label, 2), c.L.fs_label, .gray);

        const val_y = fy + @divTrunc(c.L.detail_row_h - c.L.fs_body, 2);
        const is_pw = fi == ui.PW_IDX;

        if (is_pw and !show_pw) {
            var stars: [64:0]u8 = undefined;
            const n = @min(f.value.len, 63);
            @memset(stars[0..n], '*');
            stars[n] = 0;
            ui.drawText(&stars, val_x, val_y, c.L.fs_body, .white);
        } else if (is_pw) {
            ui.drawSlice(f.value, val_x, val_y, c.L.fs_body, .{ .r = 255, .g = 200, .b = 100, .a = 255 });
        } else {
            ui.drawSlice(f.value, val_x, val_y, c.L.fs_body, .white);
        }

        if (is_pw) {
            const toggle_h = c.L.detail_btn_h;
            const toggle_label: [:0]const u8 = if (show_pw) "Hide" else "Show";
            ui.drawButton(toggle_label, c.cx() + c.cw() - toggle_w - c.L.pad, fy + @divTrunc(c.L.detail_row_h - toggle_h, 2), toggle_w, toggle_h, .{ .r = 60, .g = 60, .b = 90, .a = 255 });
        }

        if (!is_notes) rl.drawRectangle(c.cx(), fy + c.L.detail_row_h - 1, c.cw(), 1, .{ .r = 40, .g = 40, .b = 55, .a = 255 });
    }
}

fn drawDetail(self: *Self, c: Ctx) void {
    const entry = self.detail_entry orelse {
        ui.drawText("No entry loaded.", c.cx() + c.L.pad, c.L.hdr_h + c.L.pad, c.L.fs_body, .gray);
        return;
    };

    const scroll_i: i32 = @intFromFloat(self.detail_scroll);

    // Delete button (pinned bottom)
    const del_btn_h = c.L.detail_btn_h;
    const del_btn_y = c.sh - del_btn_h - c.L.pad;

    drawEntryFields(entry, self.detail_show_pw, scroll_i, del_btn_y, c);
    if (self.detail_delete_confirm.pending) {
        ui.drawButton("Tap again to confirm delete", c.cx() + c.L.pad, del_btn_y, c.cw() - 2 * c.L.pad, del_btn_h, .{ .r = 220, .g = 30, .b = 30, .a = 255 });
    } else {
        ui.drawButton("Delete", c.cx() + c.L.pad, del_btn_y, c.cw() - 2 * c.L.pad, del_btn_h, .{ .r = 160, .g = 40, .b = 40, .a = 255 });
    }

    // "View History" button — sits above Delete.
    const hist_btn_h = c.L.detail_btn_h;
    const hist_btn_y = del_btn_y - hist_btn_h - @divTrunc(c.L.pad, 2);
    ui.drawButton("View History", c.cx() + c.L.pad, hist_btn_y, c.cw() - 2 * c.L.pad, hist_btn_h, .{ .r = 40, .g = 80, .b = 140, .a = 255 });

    // "Copied!" toast
    if (self.copy_feedback_timer > 0) {
        const toast = "Copied!";
        const ttw = ui.measureText(toast, c.L.fs_body);
        const toast_pad = c.L.pad * 2;
        const toast_w = ttw + toast_pad * 2;
        const toast_h = c.L.fs_body + toast_pad;
        const toast_x = c.cx() + @divTrunc(c.cw() - toast_w, 2);
        const toast_y = del_btn_y - toast_h - c.L.pad;
        rl.drawRectangle(toast_x, toast_y, toast_w, toast_h, .{ .r = 30, .g = 30, .b = 30, .a = 220 });
        ui.drawText(toast, toast_x + toast_pad, toast_y + @divTrunc(toast_pad, 2), c.L.fs_body, .white);
    }

    if (comptime !is_android) {
        ui.drawText("h: pw  Esc: back", c.cx() + c.L.pad, c.sh - c.L.fs_small - c.L.pad - del_btn_h - c.L.pad, c.L.fs_small, .dark_gray);
    }

    // Header (drawn last)
    rl.drawRectangle(c.cx(), 0, c.cw(), c.L.hdr_h, .{ .r = 20, .g = 20, .b = 30, .a = 255 });
    ui.drawText("< Back", c.cx() + c.L.pad, @divTrunc(c.L.hdr_h - c.L.fs_body, 2), c.L.fs_body, .sky_blue);
    const edit_lbl_tw = ui.measureText("Edit", c.L.fs_body);
    ui.drawText("Edit", c.cx() + c.cw() - edit_lbl_tw - c.L.pad, @divTrunc(c.L.hdr_h - c.L.fs_body, 2), c.L.fs_body, .sky_blue);
}

fn drawEdit(self: *Self, c: Ctx) void {
    const scroll_i: i32 = @intFromFloat(self.edit_scroll);
    const val_x = c.cx() + c.L.label_w + c.L.pad;
    const notes_h = c.L.detail_row_h * 4;

    for (0..ui.field_count) |fi| {
        const row_h = if (fi == ui.EDIT_NOTES_IDX) notes_h else c.L.detail_row_h;
        const fy = c.L.hdr_h + @as(i32, @intCast(fi)) * c.L.detail_row_h - scroll_i;
        if (fy + row_h <= c.L.hdr_h or fy > c.sh) continue;

        const is_focused = (comptime !is_android) and fi == self.edit_focus;
        const bg: rl.Color = if (is_focused)
            .{ .r = 22, .g = 30, .b = 48, .a = 255 }
        else if (fi % 2 == 0)
            .{ .r = 18, .g = 18, .b = 28, .a = 255 }
        else
            .{ .r = 26, .g = 26, .b = 38, .a = 255 };
        const draw_h = if (fi == ui.EDIT_NOTES_IDX) @max(row_h, c.sh - fy) else row_h;
        rl.drawRectangle(c.cx(), fy, c.cw(), draw_h, bg);

        if (fy >= c.L.hdr_h) {
            if (fi == ui.EDIT_NOTES_IDX) {
                // Multi-line Notes field with inner scroll
                ui.drawSlice(ui.edit_field_labels[fi], c.cx() + c.L.pad, fy + c.L.pad, c.L.fs_label, .gray);
                const notes_fs = c.L.fs_body;
                const line_spacing = notes_fs + @divTrunc(notes_fs, 3);
                const text_top = fy + c.L.pad + c.L.fs_label + @divTrunc(c.L.pad, 2);
                const text_bottom = fy + notes_h;
                const notes_scroll_i: i32 = @intFromFloat(self.edit_notes_scroll);
                const notes_text = self.edit_fields[fi].buf[0..self.edit_fields[fi].len];
                var seg_start: usize = 0;
                var ly = text_top - notes_scroll_i;
                var cursor_x: i32 = val_x;
                var cursor_y: i32 = text_top;
                while (true) {
                    const nl = std.mem.indexOfScalarPos(u8, notes_text, seg_start, '\n');
                    const seg_end = nl orelse notes_text.len;
                    const seg = notes_text[seg_start..seg_end];
                    var lbuf: [ui.max_field + 1:0]u8 = std.mem.zeroes([ui.max_field + 1:0]u8);
                    const ln = @min(seg.len, ui.max_field);
                    @memcpy(lbuf[0..ln], seg[0..ln]);
                    cursor_y = ly;
                    cursor_x = val_x + ui.measureText(&lbuf, notes_fs);
                    if (ly >= text_top - notes_fs and ly < text_bottom) {
                        ui.drawText(&lbuf, val_x, ly, notes_fs, .white);
                    }
                    if (nl == null) break;
                    seg_start = seg_end + 1;
                    ly += line_spacing;
                }
                if (is_focused and cursor_y >= text_top and cursor_y < text_bottom) {
                    rl.drawRectangle(cursor_x, cursor_y, 2, notes_fs, .sky_blue);
                }
                if (comptime is_android) {
                    ui.drawText(">", c.cx() + c.cw() - c.L.pad - c.L.fs_body, fy + c.L.pad, c.L.fs_body, .dark_gray);
                }
            } else {
                ui.drawSlice(ui.edit_field_labels[fi], c.cx() + c.L.pad, fy + @divTrunc(c.L.detail_row_h - c.L.fs_label, 2), c.L.fs_label, .gray);

                const is_pw_field = fi == ui.EDIT_PW_IDX;
                const show_plain = !is_pw_field or
                    (if (comptime is_android) self.edit_show_pw else fi == self.edit_focus);
                const val_y = fy + @divTrunc(c.L.detail_row_h - c.L.fs_body, 2);

                if (show_plain) {
                    var dbuf: [ui.max_field + 1:0]u8 = std.mem.zeroes([ui.max_field + 1:0]u8);
                    const n = self.edit_fields[fi].len;
                    @memcpy(dbuf[0..n], self.edit_fields[fi].buf[0..n]);
                    ui.drawText(&dbuf, val_x, val_y, c.L.fs_body, .white);
                    if (is_focused) {
                        const tw = ui.measureText(&dbuf, c.L.fs_body);
                        rl.drawRectangle(val_x + tw, val_y, 2, c.L.fs_body, .sky_blue);
                    }
                } else {
                    var stars: [64:0]u8 = undefined;
                    const n = @min(self.edit_fields[fi].len, 63);
                    @memset(stars[0..n], '*');
                    stars[n] = 0;
                    ui.drawText(&stars, val_x, val_y, c.L.fs_body, .white);
                }

                if (is_pw_field) {
                    const btn_w = c.L.toggle_w;
                    const btn_h2 = c.L.detail_btn_h;
                    const btn_y2 = fy + @divTrunc(c.L.detail_row_h - btn_h2, 2);
                    // Show/Hide toggle (rightmost)
                    if (comptime is_android) {
                        const toggle_label: [:0]const u8 = if (self.edit_show_pw) "Hide" else "Show";
                        ui.drawButton(toggle_label, c.cx() + c.cw() - btn_w - c.L.pad, btn_y2, btn_w, btn_h2, .{ .r = 60, .g = 60, .b = 90, .a = 255 });
                    }
                    // Gen button (left of Show/Hide on Android, or standalone on desktop)
                    const gen_x = if (comptime is_android)
                        c.cx() + c.cw() - 2 * btn_w - 2 * c.L.pad
                    else
                        c.cx() + c.cw() - btn_w - c.L.pad;
                    ui.drawButton("Gen", gen_x, btn_y2, btn_w, btn_h2, .{ .r = 40, .g = 90, .b = 150, .a = 255 });
                } else if (comptime is_android) {
                    ui.drawText(">", c.cx() + c.cw() - c.L.pad - c.L.fs_body, val_y, c.L.fs_body, .dark_gray);
                }
            }
        }

        rl.drawRectangle(c.cx(), fy + row_h - 1, c.cw(), 1, .{ .r = 40, .g = 40, .b = 55, .a = 255 });
    }

    if (self.edit_err) |msg| {
        ui.drawText(msg, c.cx() + c.L.pad, c.sh - c.L.fs_label - c.L.pad, c.L.fs_label, .orange);
    }

    // Header (drawn last)
    const hdr_btn_w = c.L.hdr_btn_w;
    rl.drawRectangle(c.cx(), 0, c.cw(), c.L.hdr_h, .{ .r = 20, .g = 20, .b = 30, .a = 255 });
    ui.drawText("Cancel", c.cx() + c.L.pad, @divTrunc(c.L.hdr_h - c.L.fs_body, 2), c.L.fs_body, .sky_blue);
    const save_tw = ui.measureText("Save", c.L.fs_body);
    ui.drawText("Save", c.cx() + c.cw() - hdr_btn_w + @divTrunc(hdr_btn_w - save_tw, 2), @divTrunc(c.L.hdr_h - c.L.fs_body, 2), c.L.fs_body, .{ .r = 80, .g = 200, .b = 100, .a = 255 });

    if (comptime !is_android) {
        ui.drawText("Tab: next   Enter: save   Esc: cancel   g: gen pw", c.cx() + c.L.pad, c.sh - c.L.fs_small - c.L.pad, c.L.fs_small, .dark_gray);
    }

    // Password generator overlay (drawn on top of everything else).
    if (self.pwgen_open) self.drawPwGen(c);
}

fn drawHistory(self: *Self, c: Ctx) void {
    const entry = self.hist_entry orelse {
        ui.drawText("No history entry.", c.cx() + c.L.pad, c.L.hdr_h + c.L.pad, c.L.fs_body, .gray);
        return;
    };

    const scroll_i: i32 = @intFromFloat(self.hist_scroll);

    // Bottom button bar.
    const btn_h = c.L.detail_btn_h;
    const bar_y = c.sh - btn_h - c.L.pad;

    drawEntryFields(entry, self.hist_show_pw, scroll_i, bar_y, c);

    // "Copied!" toast
    if (self.copy_feedback_timer > 0) {
        const toast = "Copied!";
        const ttw = ui.measureText(toast, c.L.fs_body);
        const toast_pad = c.L.pad * 2;
        const toast_w = ttw + toast_pad * 2;
        const toast_h = c.L.fs_body + toast_pad;
        const toast_x = c.cx() + @divTrunc(c.cw() - toast_w, 2);
        const toast_y = bar_y - toast_h - c.L.pad;
        rl.drawRectangle(toast_x, toast_y, toast_w, toast_h, .{ .r = 30, .g = 30, .b = 30, .a = 220 });
        ui.drawText(toast, toast_x + toast_pad, toast_y + @divTrunc(toast_pad, 2), c.L.fs_body, .white);
    }

    // Bottom button bar: [Prev] [Copy to new entry] [Next]
    const third_w = @divTrunc(c.cw() - 4 * c.L.pad, 3);
    const prev_x = c.cx() + c.L.pad;
    const copy_x = c.cx() + c.L.pad + third_w + c.L.pad;
    const next_x = c.cx() + c.L.pad + third_w + c.L.pad + third_w + c.L.pad;

    const has_prev = self.hist_idx + 1 < self.hist_hashes.items.len;
    const has_next = self.hist_idx > 0;
    const prev_color: rl.Color = if (has_prev)
        .{ .r = 30, .g = 130, .b = 180, .a = 255 }
    else
        .{ .r = 50, .g = 50, .b = 70, .a = 255 };
    const next_color: rl.Color = if (has_next)
        .{ .r = 30, .g = 130, .b = 180, .a = 255 }
    else
        .{ .r = 50, .g = 50, .b = 70, .a = 255 };

    ui.drawButton("Prev", prev_x, bar_y, third_w, btn_h, prev_color);
    ui.drawButton("Copy", copy_x, bar_y, third_w, btn_h, .{ .r = 50, .g = 120, .b = 60, .a = 255 });
    ui.drawButton("Next", next_x, bar_y, third_w, btn_h, next_color);

    // Header (drawn last so it covers scrolled content).
    rl.drawRectangle(c.cx(), 0, c.cw(), c.L.hdr_h, .{ .r = 20, .g = 20, .b = 30, .a = 255 });
    ui.drawText("< Back", c.cx() + c.L.pad, @divTrunc(c.L.hdr_h - c.L.fs_body, 2), c.L.fs_body, .sky_blue);

    // Version indicator: "Version N / M" centered in header.
    const total = self.hist_hashes.items.len;
    const ver_num = if (total > 0) total - self.hist_idx else 0;
    var vbuf: [48:0]u8 = std.mem.zeroes([48:0]u8);
    _ = std.fmt.bufPrintZ(&vbuf, "v{d}/{d}", .{ ver_num, total }) catch {};
    const vtw = ui.measureText(&vbuf, c.L.fs_body);
    ui.drawText(&vbuf, c.cx() + @divTrunc(c.cw() - vtw, 2), @divTrunc(c.L.hdr_h - c.L.fs_body, 2), c.L.fs_body, .{ .r = 180, .g = 180, .b = 200, .a = 255 });

    if (comptime !is_android) {
        ui.drawText("h: pw  Esc: back", c.cx() + c.L.pad, bar_y - c.L.fs_small - @divTrunc(c.L.pad, 2), c.L.fs_small, .dark_gray);
    }
}

fn drawSyncSetup(self: *Self, c: Ctx) void {
    const form_top = if (self.sync_from_browser) c.L.hdr_h + c.L.pad else c.L.pad * 2;
    const fw = c.cw() - 2 * c.L.pad;
    const title_y = form_top;
    const sub_y = title_y + c.L.fs_hdr + c.L.pad;
    const ip_label_y = sub_y + c.L.fs_label + c.L.pad * 2;
    const ip_field_y = ip_label_y + c.L.fs_label + @divTrunc(c.L.pad, 2);
    const pw_label_y = ip_field_y + c.L.fh + c.L.pad;
    const pw_field_y = pw_label_y + c.L.fs_label + @divTrunc(c.L.pad, 2);
    const submit_btn_y = pw_field_y + c.L.fh + c.L.pad * 2;
    const create_btn_y = submit_btn_y + c.L.btn_h + c.L.pad;

    ui.drawText("Loki Sync", c.cx() + c.L.pad, title_y, c.L.fs_hdr, .white);

    const subtitle: [:0]const u8 = if (self.first_use)
        "First use: fetch the database from server"
    else
        "Sync database with server";
    ui.drawText(subtitle, c.cx() + c.L.pad, sub_y, c.L.fs_label, .gray);

    ui.drawText("Server IP", c.cx() + c.L.pad, ip_label_y, c.L.fs_label, .light_gray);
    ui.drawTextField(&self.ip_field, c.cx() + c.L.pad, ip_field_y, fw, c.L.fh, self.sync_focus_ip, self.sync_ip_err);

    ui.drawText("Password", c.cx() + c.L.pad, pw_label_y, c.L.fs_label, .light_gray);
    if (comptime is_android) {
        if (self.sync_bio_pending) {
            ui.drawButton("Waiting for biometrics...", c.cx() + c.L.pad, pw_field_y, fw, c.L.fh, .{ .r = 40, .g = 80, .b = 140, .a = 180 });
        } else if (self.sync_from_browser and self.bio_enrolled and self.sync_pw_field.len == 0) {
            ui.drawButton("Use biometrics", c.cx() + c.L.pad, pw_field_y, fw, c.L.fh, .{ .r = 40, .g = 90, .b = 160, .a = 255 });
        } else if (self.sync_from_browser and self.bio_enrolled and self.sync_pw_field.len > 0) {
            ui.drawButton("Password set via biometrics", c.cx() + c.L.pad, pw_field_y, fw, c.L.fh, .{ .r = 30, .g = 80, .b = 50, .a = 255 });
        } else {
            ui.drawTextField(&self.sync_pw_field, c.cx() + c.L.pad, pw_field_y, fw, c.L.fh, !self.sync_focus_ip, self.sync_pw_err);
        }
    } else {
        ui.drawTextField(&self.sync_pw_field, c.cx() + c.L.pad, pw_field_y, fw, c.L.fh, !self.sync_focus_ip, self.sync_pw_err);
    }

    const submit_label: [:0]const u8 = if (self.first_use) "Fetch" else "Sync";
    ui.drawButton(submit_label, c.cx() + c.L.pad, submit_btn_y, fw, c.L.btn_h, .sky_blue);

    if (self.first_use) {
        ui.drawButton("Create new (no server)", c.cx() + c.L.pad, create_btn_y, fw, c.L.btn_h, .{ .r = 50, .g = 100, .b = 60, .a = 255 });
    }

    const err_y = create_btn_y + c.L.btn_h + c.L.pad;
    if (self.sync_err) |msg| ui.drawText(msg, c.cx() + c.L.pad, err_y, c.L.fs_label, .orange);

    if (comptime !is_android) {
        ui.drawText("Tab: switch field   Enter: submit", c.cx() + c.L.pad, c.sh - c.L.fs_small - c.L.pad, c.L.fs_small, .dark_gray);
    }

    // Back button in header when reached from browser
    if (self.sync_from_browser) {
        rl.drawRectangle(c.cx(), 0, c.cw(), c.L.hdr_h, .{ .r = 20, .g = 20, .b = 30, .a = 255 });
        ui.drawText("< Back", c.cx() + c.L.pad, @divTrunc(c.L.hdr_h - c.L.fs_body, 2), c.L.fs_body, .sky_blue);
    }
}

fn drawSyncRunning(_: *Self, c: Ctx) void {
    ui.drawText("Loki Sync", c.cx() + c.L.pad, c.L.pad * 2, c.L.fs_hdr, .white);
    const dot_count = @as(usize, @intCast(@mod(@as(i64, @intFromFloat(rl.getTime() * 3)), 4)));
    const dots = [4][:0]const u8{ "", ".", "..", "..." };
    var sbuf: [64:0]u8 = std.mem.zeroes([64:0]u8);
    const base_label: [:0]const u8 = switch (sync.g_status.load(.acquire)) {
        .connecting => "Connecting",
        .syncing => "Syncing",
        else => "Please wait",
    };
    _ = std.fmt.bufPrintZ(&sbuf, "{s}{s}", .{ base_label, dots[dot_count] }) catch {};
    const stw = ui.measureText(&sbuf, c.L.fs_body);
    ui.drawText(&sbuf, c.cx() + @divTrunc(c.cw() - stw, 2), @divTrunc(c.sh, 2), c.L.fs_body, .yellow);
}

fn drawSyncResult(_: *Self, c: Ctx) void {
    ui.drawText("Loki Sync", c.cx() + c.L.pad, c.L.pad * 2, c.L.fs_hdr, .white);
    const result_y = @divTrunc(c.sh, 4);
    const btn_y = c.sh - c.L.btn_h - c.L.pad;
    switch (sync.g_status.load(.acquire)) {
        .done => {
            ui.drawText("Sync complete!", c.cx() + c.L.pad, result_y, c.L.fs_body, .green);
            ui.drawText(&sync.g_msg_buf, c.cx() + c.L.pad, result_y + c.L.fs_body + c.L.pad, c.L.fs_label, .green);
            if (sync.g_conflict_count > 0) {
                var cbuf: [128:0]u8 = std.mem.zeroes([128:0]u8);
                _ = std.fmt.bufPrintZ(&cbuf, "{d} conflict(s) — server version kept", .{sync.g_conflict_count}) catch {};
                const conflict_y = result_y + c.L.fs_body + c.L.pad + c.L.fs_label + c.L.pad;
                ui.drawText(&cbuf, c.cx() + c.L.pad, conflict_y, c.L.fs_label, .orange);
                ui.drawText("Use the desktop TUI to review", c.cx() + c.L.pad, conflict_y + c.L.fs_label + @divTrunc(c.L.pad, 2), c.L.fs_small, .{ .r = 200, .g = 160, .b = 80, .a = 255 });
                ui.drawText("and resolve conflicts.", c.cx() + c.L.pad, conflict_y + c.L.fs_label + @divTrunc(c.L.pad, 2) + c.L.fs_small + 4, c.L.fs_small, .{ .r = 200, .g = 160, .b = 80, .a = 255 });
            }
            ui.drawButton("Open DB", c.cx() + c.L.pad, btn_y, c.cw() - 2 * c.L.pad, c.L.btn_h, .{ .r = 30, .g = 140, .b = 80, .a = 255 });
        },
        .failed => {
            ui.drawText("Sync failed:", c.cx() + c.L.pad, result_y, c.L.fs_body, .red);
            ui.drawText(&sync.g_msg_buf, c.cx() + c.L.pad, result_y + c.L.fs_body + c.L.pad, c.L.fs_label, .red);
            const half_w = @divTrunc(c.cw() - 3 * c.L.pad, 2);
            ui.drawButton("Back", c.cx() + c.L.pad, btn_y, half_w, c.L.btn_h, .{ .r = 70, .g = 70, .b = 90, .a = 255 });
            ui.drawButton("Retry", 2 * c.L.pad + half_w, btn_y, half_w, c.L.btn_h, .{ .r = 30, .g = 130, .b = 180, .a = 255 });
        },
        else => {},
    }
}
