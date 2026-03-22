//! Font loading for Loki.
//!
//! Fonts are embedded at compile time via @embedFile so they are available
//! on both desktop and Android without any filesystem access at runtime.
//!
//! Call `load()` once after `rl.initWindow()` and `unload()` before
//! `rl.closeWindow()`.  All other modules access the loaded fonts through
//! the `regular` and `bold` globals.
//!
//! The atlas is rasterised at ATLAS_SIZE pixels — a large value so that
//! Raylib has plenty of detail to draw from when scaling to smaller sizes
//! on high-DPI screens.  Bilinear filtering is enabled on the atlas texture
//! so down-scaled text stays smooth.

const rl = @import("raylib");

// ---- Embedded font data ----

const regular_ttf = @embedFile("assets/fonts/RobotoMono/RobotoMonoNerdFont-Regular.ttf");
const bold_ttf = @embedFile("assets/fonts/RobotoMono/RobotoMonoNerdFont-Bold.ttf");

// ---- Public globals ----

pub var regular: rl.Font = undefined;
pub var bold: rl.Font = undefined;

// ---- Configuration ----

/// Size (in pixels) at which the glyph atlas is rasterised.
/// Using a large value means the atlas looks sharp at any screen density.
/// Individual draw calls pass their own (smaller) fontSize to drawTextEx,
/// which Raylib scales from this atlas size.
const ATLAS_SIZE: i32 = 64;

/// Character spacing passed to drawTextEx / measureTextEx.
/// 0 reproduces the same default advance used by drawText.
pub const SPACING: f32 = 0;

// ---- Codepoint ranges to include in the atlas ----
//
// We keep the atlas small so it fits within OpenGL's maximum texture size on
// all devices (including Android, which commonly limits textures to 4096px).
//
// Ranges included:
//   0x0020–0x00FF  Basic Latin + Latin-1 Supplement (standard ASCII + common accented chars)
//   0xF0DA–0xF0DA  U+F0DA fa-caret_right — the folder arrow used in the browser view
//
// Each range is [first, last] inclusive.
const ranges = [_][2]i32{
    .{ 0x0020, 0x00FF },
    .{ 0xF0DA, 0xF0DA },
};

fn codepointCount() comptime_int {
    var n: comptime_int = 0;
    for (ranges) |r| n += r[1] - r[0] + 1;
    return n;
}

fn buildCodepoints() [codepointCount()]i32 {
    // The three ranges total ~8 000 codepoints; raise the quota to match.
    @setEvalBranchQuota(100_000);
    var arr: [codepointCount()]i32 = undefined;
    var i: usize = 0;
    for (ranges) |r| {
        var cp: i32 = r[0];
        while (cp <= r[1]) : (cp += 1) {
            arr[i] = cp;
            i += 1;
        }
    }
    return arr;
}

const codepoints: [codepointCount()]i32 = buildCodepoints();

// ---- Lifecycle ----

pub fn load() void {
    // Raylib's LoadFontData sorts the codepoint array in-place, so we must
    // provide a mutable copy rather than a pointer into read-only memory.
    var cp_buf: [codepointCount()]i32 = codepoints;

    regular = rl.loadFontFromMemory(".ttf", regular_ttf, ATLAS_SIZE, &cp_buf) catch {
        // Fall back to the Raylib default font so the app is still usable.
        regular = rl.getFontDefault() catch unreachable;
        bold = regular;
        return;
    };
    rl.setTextureFilter(regular.texture, .bilinear);

    // Reset the buffer before the second load (sort may have reordered it).
    cp_buf = codepoints;

    bold = rl.loadFontFromMemory(".ttf", bold_ttf, ATLAS_SIZE, &cp_buf) catch {
        bold = regular; // fall back to regular if bold fails
        return;
    };
    rl.setTextureFilter(bold.texture, .bilinear);
}

pub fn unload() void {
    // Only unload if the font is a real loaded font (not the Raylib default).
    if (regular.glyphCount > 0) rl.unloadFont(regular);
    // Only unload bold separately if it isn't aliased to regular.
    if (bold.texture.id != regular.texture.id and bold.glyphCount > 0) {
        rl.unloadFont(bold);
    }
}
