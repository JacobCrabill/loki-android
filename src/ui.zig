const std = @import("std");
const builtin = @import("builtin");
const android = @import("android");
const rl = @import("raylib");

pub const is_android = builtin.abi.isAndroid();

// ---- Android text-input dialog ----

pub extern fn showTextInputDialog(title: [*c]const u8, current: [*c]const u8, is_password: c_int) void;
pub extern fn showTextInputDialogMultiline(title: [*c]const u8, current: [*c]const u8) void;
pub extern fn pollTextInputDialog(out_buf: [*]u8, buf_size: c_int) c_int;

// ---- Android biometric unlock ----

pub extern fn biometricIsAvailable() c_int;
pub extern fn biometricHasEnrolled() c_int;
/// Encrypt `password` under the Keystore key and store the blob.
/// Result delivered via pollBiometricResult().
pub extern fn biometricEnroll(password: [*c]const u8) void;
/// Show the biometric prompt for decryption.
/// Result (plaintext password or cancel) via pollBiometricResult().
pub extern fn biometricAuthenticate() void;
pub extern fn biometricClearEnrollment() void;
/// Returns 0=waiting, -1=failed/cancel, >0=success (strlen+1 in out_buf).
pub extern fn pollBiometricResult(out_buf: [*]u8, buf_size: c_int) c_int;

// ---- Text input field ----

pub const max_field = 511;

pub const TextField = struct {
    buf: [max_field + 1]u8 = std.mem.zeroes([max_field + 1]u8),
    len: usize = 0,
    masked: bool = false,

    pub fn append(self: *TextField, ch: u8) void {
        if (self.len < max_field) {
            self.buf[self.len] = ch;
            self.len += 1;
        }
    }

    pub fn pop(self: *TextField) void {
        if (self.len > 0) self.len -= 1;
    }

    pub fn setDefault(self: *TextField, s: []const u8) void {
        const n = @min(s.len, max_field);
        @memcpy(self.buf[0..n], s[0..n]);
        self.len = n;
    }

    pub fn slice(self: *const TextField) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn showDialog(self: *const TextField, title: [*c]const u8, is_password: bool) void {
        if (comptime is_android) {
            var tmp: [max_field + 1]u8 = std.mem.zeroes([max_field + 1]u8);
            @memcpy(tmp[0..self.len], self.buf[0..self.len]);
            showTextInputDialog(title, &tmp, @intFromBool(is_password));
        }
    }

    pub fn showDialogMultiline(self: *const TextField, title: [*c]const u8) void {
        if (comptime is_android) {
            var tmp: [max_field + 1]u8 = std.mem.zeroes([max_field + 1]u8);
            @memcpy(tmp[0..self.len], self.buf[0..self.len]);
            showTextInputDialogMultiline(title, &tmp);
        }
    }
};

// ---- Responsive layout ----
//
// All values scale with screen width so the UI looks right on any phone.
// Design reference: 480 × 854 (portrait, 1x density).
//
pub const Layout = struct {
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

    pub fn compute(sw: i32) Layout {
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

pub const BrowserRow = struct {
    entry_id: [20]u8,
    head_hash: [20]u8,
    title: []u8,
    path: []u8,

    pub fn deinit(self: BrowserRow, a: std.mem.Allocator) void {
        a.free(self.title);
        a.free(self.path);
    }
};

pub fn rowLessThan(_: void, a: BrowserRow, b: BrowserRow) bool {
    const pc = std.mem.order(u8, a.path, b.path);
    if (pc != .eq) return pc == .lt;
    return std.mem.order(u8, a.title, b.title) == .lt;
}

// ---- App phases ----

pub const Phase = enum {
    unlock,
    browser,
    detail,
    edit,
    history,
    sync_setup,
    sync_running,
    sync_result,
};

// ---- Edit / detail field metadata ----

pub const edit_field_labels = [7][:0]const u8{
    "Title", "Path", "Desc", "URL", "Username", "Password", "Notes",
};
pub const EDIT_PW_IDX: usize = 5;
pub const EDIT_NOTES_IDX: usize = 6;
pub const DETAIL_PW_IDX: i32 = 5;

// ---- Draw helpers ----

pub fn fsByHeight(h: i32) i32 {
    return @max(12, @divTrunc(h * 11, 20));
}

pub fn drawTextField(f: *const TextField, x: i32, y: i32, w: i32, h: i32, focused: bool, err: bool) void {
    rl.drawRectangle(x, y, w, h, if (focused) .white else .light_gray);
    const border: rl.Color = if (err) .{ .r = 220, .g = 50, .b = 50, .a = 255 } else if (focused) .sky_blue else .gray;
    rl.drawRectangleLines(x, y, w, h, border);

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

pub fn inRect(mx: f32, my: f32, x: i32, y: i32, w: i32, h: i32) bool {
    return mx >= @as(f32, @floatFromInt(x)) and
        mx < @as(f32, @floatFromInt(x + w)) and
        my >= @as(f32, @floatFromInt(y)) and
        my < @as(f32, @floatFromInt(y + h));
}

pub fn drawSlice(text: []const u8, x: i32, y: i32, fs: i32, color: rl.Color) void {
    var buf: [512:0]u8 = undefined;
    const n = @min(text.len, 511);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    rl.drawText(&buf, x, y, fs, color);
}

pub fn drawButton(label: [:0]const u8, x: i32, y: i32, w: i32, h: i32, color: rl.Color) void {
    rl.drawRectangle(x, y, w, h, color);
    const fs = fsByHeight(h);
    const tw = rl.measureText(label, fs);
    rl.drawText(label, x + @divTrunc(w - tw, 2), y + @divTrunc(h - fs, 2), fs, .white);
}

// ---- Search helpers ----

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

pub fn matchesSearch(row: BrowserRow, query: []const u8) bool {
    if (query.len == 0) return true;
    return containsIgnoreCase(row.title, query) or containsIgnoreCase(row.path, query);
}
