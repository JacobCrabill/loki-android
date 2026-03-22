const std = @import("std");
const builtin = @import("builtin");
const android = @import("android");
const rl = @import("raylib");
const font = @import("font.zig");

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
// C-side result buffers (RESULT_BUF_SIZE in android_keyboard.c / android_biometric.c)
// must equal max_field + 1.  This comptime assertion documents the coupling.
comptime {
    std.debug.assert(max_field + 1 == 512);
}

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

    /// Overwrite the buffer contents with zeros and reset length.
    /// Call this as soon as a sensitive value (e.g. password) is no longer needed.
    pub fn zeroAndClear(self: *TextField) void {
        @memset(&self.buf, 0);
        self.len = 0;
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
// All proportional values scale from `content_w` — the width of the UI
// column.  On Android (portrait) content_w == sw.  On desktop, content_w is
// capped so the column never becomes unwieldy on wide windows.
//
// Design reference: content_w = 480px (portrait phone, 1x density).
//
pub const Layout = struct {
    /// Full screen / window width.
    sw: i32,
    /// X offset of the UI column (0 on Android; centred on wide desktop).
    content_x: i32,
    /// Width of the UI column — all layout values are proportional to this.
    content_w: i32,

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
    toggle_w: i32, // Show/Hide toggle button width
    hdr_btn_w: i32, // header button width (Back / Save / Edit)
    fab_size: i32, // floating action button size
    back_btn_w: i32, // "< Back" tap zone width (content_w / 3)
    detail_btn_h: i32, // height of secondary buttons in detail view (View History, Delete)

    pub fn compute(sw: i32, sh: i32) Layout {
        // On Android, use the full screen width.  On desktop, cap the column
        // at 3/4 of the screen height so it stays readable on wide windows.
        const cw = if (is_android) sw else @min(sw, @divTrunc(sh * 3, 4));
        const cx = @divTrunc(sw - cw, 2);
        return .{
            .sw = sw,
            .content_x = cx,
            .content_w = cw,
            .hdr_h = @divTrunc(cw, 8), //  60 @ 480
            .row_h = @divTrunc(cw, 6), //  80 @ 480
            .pad = @max(8, @divTrunc(cw, 30)), //  16 @ 480
            .fh = @divTrunc(cw, 9), //  53 @ 480
            .btn_h = @divTrunc(cw, 8), //  60 @ 480
            .fs_hdr = @divTrunc(cw, 17), //  28 @ 480
            .fs_body = @divTrunc(cw, 24), //  20 @ 480
            .fs_label = @divTrunc(cw, 26), //  18 @ 480
            .fs_small = @divTrunc(cw, 38), //  12 @ 480
            .detail_row_h = @divTrunc(cw * 3, 16), //  90 @ 480
            .label_w = @divTrunc(cw, 5), //  96 @ 480
            .toggle_w = @divTrunc(cw, 7), //  68 @ 480
            .hdr_btn_w = @divTrunc(cw, 4), // 120 @ 480
            .fab_size = @divTrunc(cw, 7), //  68 @ 480
            .back_btn_w = @divTrunc(cw, 3), // 160 @ 480
            .detail_btn_h = @divTrunc(cw, 12), //  40 @ 480
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

pub const field_count: usize = 7;
pub const edit_field_labels = [field_count][:0]const u8{
    "Title", "Path", "Desc", "URL", "Username", "Password", "Notes",
};
// Field indices — all usize; cast to i32 at use sites where needed.
pub const TITLE_IDX: usize = 0;
pub const PATH_IDX: usize = 1;
pub const DESC_IDX: usize = 2;
pub const URL_IDX: usize = 3;
pub const USERNAME_IDX: usize = 4;
pub const PW_IDX: usize = 5;
pub const NOTES_IDX: usize = 6;
// Legacy aliases — kept so existing code compiles without change;
// prefer the canonical names above for new code.
pub const EDIT_PW_IDX: usize = PW_IDX;
pub const EDIT_NOTES_IDX: usize = NOTES_IDX;
pub const DETAIL_PW_IDX: i32 = PW_IDX;

// ---- Draw helpers ----

pub fn fsByHeight(h: i32) i32 {
    return @max(12, @divTrunc(h * 11, 20));
}

/// Draw a null-terminated string using the custom font.
/// Drop-in replacement for rl.drawText with identical integer coordinates/size.
pub fn drawText(text: [:0]const u8, x: i32, y: i32, fs: i32, color: rl.Color) void {
    rl.drawTextEx(
        font.regular,
        text,
        .{ .x = @floatFromInt(x), .y = @floatFromInt(y) },
        @floatFromInt(fs),
        font.SPACING,
        color,
    );
}

/// Measure the pixel width of a string using the custom font.
/// Drop-in replacement for rl.measureText returning i32.
pub fn measureText(text: [:0]const u8, fs: i32) i32 {
    return @intFromFloat(rl.measureTextEx(
        font.regular,
        text,
        @floatFromInt(fs),
        font.SPACING,
    ).x);
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
    drawText(&disp, x + pad, y + @divTrunc(h - fs, 2), fs, .dark_gray);

    if (focused) {
        const tw = measureText(&disp, fs);
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
    drawText(&buf, x, y, fs, color);
}

pub fn drawButton(label: [:0]const u8, x: i32, y: i32, w: i32, h: i32, color: rl.Color) void {
    rl.drawRectangle(x, y, w, h, color);
    const fs = fsByHeight(h);
    const tw = measureText(label, fs);
    drawText(label, x + @divTrunc(w - tw, 2), y + @divTrunc(h - fs, 2), fs, .white);
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
