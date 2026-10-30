//! The design tokens.
//!
//! Restaurant OS has a brand, and a brand that only exists in the app's own
//! stylesheet is a brand that dies with the stylesheet. The Native SDK
//! lets the app own its whole design system - colours, type scale,
//! spacing, radii - so the palette lives in one file that a designer
//! can read and a developer can diff.
//!
//! The palette below is the product's own: the cyan-and-teal of Eatery v1,
//! re-expressed on the SDK's semantic token names. Four registers are on
//! offer - Light, Dark, Warm and Night - plus one derivation, high
//! contrast, which pushes the tokens that carry meaning away from the
//! ground they sit on until they clear the threshold. Colours are sRGB
//! bytes; the runtime handles the rest.
//!
//! Every text pair in every register and in its high-contrast form is
//! asserted against WCAG in `src/tests.zig`. That is the only reason a
//! register can be added here without someone first finding an unreadable
//! chip on a till at 2am.

const std = @import("std");
const native_sdk = @import("native_sdk");

const core = @import("model.zig");

const canvas = native_sdk.canvas;
const Color = canvas.Color;
const ColorTokens = canvas.ColorTokens;
const DesignTokens = canvas.DesignTokens;
const Model = core.Model;

/// The Restaurant OS brand palette.
const brand = struct {
    // The light semantic fills are the darkest step of the v1 hues that
    // clears WCAG AA with white text, and as text on the light
    // background and surface. The test in tests.zig is the guard.
    const primary = rgb(0x17, 0x6B, 0x84); // v1 cyan blue, one step down
    const success = rgb(0x1B, 0x6E, 0x47);
    const warning = rgb(0x87, 0x52, 0x0C);
    const danger = rgb(0xB3, 0x2D, 0x22);
    const info = rgb(0x2F, 0x5E, 0xC2);
};

const white = rgb(0xFF, 0xFF, 0xFF);
const black = rgb(0x00, 0x00, 0x00);

fn rgb(r: u8, g: u8, b: u8) Color {
    return Color.rgb8(r, g, b);
}

fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
    return Color.rgba8(r, g, b, a);
}

/// The type scale, spacing and radii every register shares. A register is
/// a colour decision, so the blocks that are not colour are written once
/// and forwarded.
const shared_metrics = DesignTokens{
    .typography = .{
        .body_size = 14,
        .label_size = 13,
        .title_size = 20,
        .heading_size = 28,
        .display_size = 48,
        .button_size = 14,
    },
    .spacing = .{
        .xs = 4,
        .sm = 8,
        .md = 12,
        .lg = 16,
        .xl = 24,
    },
    .radius = .{
        .sm = 4,
        .md = 8,
        .lg = 12,
        .xl = 16,
        .none = 0,
    },
};

fn withColors(colors: ColorTokens) DesignTokens {
    var design = shared_metrics;
    design.colors = colors;
    return design;
}

/// The light palette.
pub fn light() DesignTokens {
    return withColors(.{
        .background = rgb(0xF7, 0xF8, 0xFA),
        .surface = rgb(0xFF, 0xFF, 0xFF),
        .surface_subtle = rgb(0xF1, 0xF3, 0xF6),
        .surface_pressed = rgb(0xE6, 0xEA, 0xEF),
        .text = rgb(0x15, 0x1A, 0x21),
        .text_muted = rgb(0x64, 0x6E, 0x7A),
        .border = rgb(0xE1, 0xE5, 0xEA),
        .accent = brand.primary,
        .accent_text = white,
        .destructive = brand.danger,
        .destructive_text = white,
        .success = brand.success,
        .success_text = white,
        .warning = brand.warning,
        .warning_text = white,
        .info = brand.info,
        .info_text = white,
        .focus_ring = brand.primary,
        // The SDK's default is the light register's own near-white step;
        // naming it here keeps a disabled control reading as a dimmed
        // surface rather than as an untouched one.
        .disabled = rgb(0xE8, 0xEC, 0xF1),
    });
}

/// The dark palette. The same brand, one step down in luminance.
pub fn dark() DesignTokens {
    return withColors(.{
        .background = rgb(0x0F, 0x13, 0x18),
        .surface = rgb(0x17, 0x1C, 0x23),
        .surface_subtle = rgb(0x1F, 0x26, 0x2E),
        .surface_pressed = rgb(0x27, 0x2F, 0x38),
        .text = rgb(0xEC, 0xEF, 0xF3),
        .text_muted = rgb(0x9A, 0xA5, 0xB1),
        .border = rgb(0x2A, 0x33, 0x3D),
        .accent = rgb(0x4C, 0xC2, 0xEA),
        .accent_text = rgb(0x08, 0x10, 0x14),
        .destructive = rgb(0xE8, 0x5D, 0x51),
        .destructive_text = rgb(0x12, 0x08, 0x08),
        .success = rgb(0x45, 0xB8, 0x86),
        .success_text = rgb(0x06, 0x14, 0x0E),
        .warning = rgb(0xE0, 0x9A, 0x3C),
        .warning_text = rgb(0x14, 0x0E, 0x04),
        .info = rgb(0x5B, 0x8C, 0xE0),
        .info_text = rgb(0x06, 0x0E, 0x18),
        .focus_ring = rgb(0x4C, 0xC2, 0xEA),
        .disabled = rgb(0x23, 0x2B, 0x34),
        // The struct defaults are light-register values - a shadow and a
        // scrim that are barely there read as nothing on a near-black
        // ground, and a modal loses the fact that it is modal.
        .shadow = rgba(0, 0, 0, 0x8C),
        .scrim = rgba(0, 0, 0, 0x8C),
        // The seven syntax_* tokens stay at their transparent default.
        // That default is not "the light palette's ink" - it is the
        // sentinel the SDK resolves to this palette's own text and
        // text_muted, so a code block follows the register it is drawn in.
    });
}

/// The warm register: the light structure on paper the colour of a
/// laminated menu, for a dining-room tablet where the cool grey reads as
/// a hospital tray.
pub fn warm() DesignTokens {
    return withColors(.{
        .background = rgb(0xFB, 0xF6, 0xEE),
        .surface = rgb(0xFF, 0xFB, 0xF4),
        .surface_subtle = rgb(0xF1, 0xE7, 0xD6),
        .surface_pressed = rgb(0xDE, 0xCF, 0xB6),
        .text = rgb(0x24, 0x1C, 0x12),
        .text_muted = rgb(0x5C, 0x4E, 0x3C),
        .border = rgb(0xC9, 0xBB, 0xA4),
        .accent = rgb(0x8A, 0x4B, 0x18),
        .accent_text = white,
        .destructive = rgb(0x8E, 0x2A, 0x1F),
        .destructive_text = white,
        .success = rgb(0x4F, 0x6B, 0x1E),
        .success_text = white,
        .warning = rgb(0x7A, 0x4A, 0x00),
        .warning_text = white,
        .info = rgb(0x2F, 0x5E, 0x6B),
        .info_text = white,
        .focus_ring = rgb(0x8A, 0x4B, 0x18),
        .disabled = rgb(0xE3, 0xD6, 0xC0),
    });
}

/// The night register: deeper than `dark`, with every label pulled to
/// near-black ink. This is the one a kitchen display uses at 3am, where a
/// screen that glows is the problem rather than the colour scheme.
pub fn night() DesignTokens {
    return withColors(.{
        .background = rgb(0x05, 0x07, 0x0A),
        .surface = rgb(0x0C, 0x11, 0x17),
        .surface_subtle = rgb(0x14, 0x1B, 0x23),
        .surface_pressed = rgb(0x1D, 0x25, 0x30),
        .text = rgb(0xE9, 0xEE, 0xF5),
        .text_muted = rgb(0xA9, 0xB6, 0xC4),
        .border = rgb(0x2B, 0x37, 0x45),
        .accent = rgb(0x62, 0xCF, 0xF5),
        .accent_text = rgb(0x04, 0x0B, 0x10),
        .destructive = rgb(0xFF, 0x7A, 0x6E),
        .destructive_text = rgb(0x15, 0x05, 0x04),
        .success = rgb(0x55, 0xC8, 0x94),
        .success_text = rgb(0x04, 0x14, 0x0C),
        .warning = rgb(0xF3, 0xB1, 0x50),
        .warning_text = rgb(0x15, 0x0C, 0x02),
        .info = rgb(0x79, 0xA9, 0xFF),
        .info_text = rgb(0x05, 0x0C, 0x18),
        .focus_ring = rgb(0x62, 0xCF, 0xF5),
        .disabled = rgb(0x1A, 0x22, 0x2C),
        .shadow = rgba(0, 0, 0, 0xA3),
        .scrim = rgba(0, 0, 0, 0xA3),
    });
}

/// The register the operator chose.
pub fn register(which: core.Palette) DesignTokens {
    return switch (which) {
        .light => light(),
        .dark => dark(),
        .warm => warm(),
        .night => night(),
    };
}

fn srgbToLinear(channel: f32) f32 {
    return if (channel <= 0.04045) channel / 12.92 else std.math.pow(f32, (channel + 0.055) / 1.055, 2.4);
}

fn luminance(color: Color) f32 {
    return 0.2126 * srgbToLinear(color.r) +
        0.7152 * srgbToLinear(color.g) +
        0.0722 * srgbToLinear(color.b);
}

fn ratio(a: Color, b: Color) f32 {
    const la = luminance(a);
    const lb = luminance(b);
    return (@max(la, lb) + 0.05) / (@min(la, lb) + 0.05);
}

fn mix(from: Color, toward: Color, amount: f32) Color {
    return .{
        .r = from.r + (toward.r - from.r) * amount,
        .g = from.g + (toward.g - from.g) * amount,
        .b = from.b + (toward.b - from.b) * amount,
        .a = from.a,
    };
}

fn minRatio(colour: Color, grounds: []const Color) f32 {
    var worst = ratio(colour, grounds[0]);
    for (grounds[1..]) |ground| worst = @min(worst, ratio(colour, ground));
    return worst;
}

/// `colour` moved, in steps, until it clears `target` against every ground
/// it can be drawn on - in whichever direction, toward white or toward
/// black, actually gets there. This is how high contrast keeps a brand hue
/// instead of replacing it: the token is pushed until it carries its label,
/// and the only colours that end at an extreme are the ones that were
/// unreadable anyway.
fn pushAway(colour: Color, grounds: []const Color, target: f32) Color {
    if (minRatio(colour, grounds) >= target) return colour;
    for ([_]Color{ white, black }) |extreme| {
        var step: usize = 1;
        while (step <= 12) : (step += 1) {
            const candidate = mix(colour, extreme, @as(f32, @floatFromInt(step)) * 0.08);
            if (minRatio(candidate, grounds) >= target) return candidate;
        }
    }
    // Nothing clears it, which only happens when the grounds straddle the
    // middle: answer with the colour that is loudest against the register.
    return if (luminance(grounds[0]) > 0.5) black else white;
}

/// The high-contrast derivation of a register: the same palette with every
/// pair that carries meaning - ink, hairline, and each fill against its
/// own label - pushed past the WCAG AAA thresholds.
fn highContrast(base: ColorTokens, on_dark: bool) ColorTokens {
    var colors = base;
    const ink: Color = if (on_dark) white else black;
    const label: Color = if (on_dark) black else white;
    const ground = base.background;

    // The steps that are not ink still have to be told apart from the
    // surface they sit on, or a hover wash and a disabled control look
    // like the same "nothing here" panel. They go first, because muted
    // text is drawn on the wash they become.
    colors.surface_subtle = pushAway(base.surface_subtle, &.{ground}, 1.6);
    colors.surface_pressed = pushAway(base.surface_pressed, &.{ground}, 2.2);
    colors.disabled = pushAway(base.disabled, &.{ground}, 2.6);
    colors.border = pushAway(base.border, &.{ground}, 3.0);

    colors.text = ink;
    colors.text_muted = pushAway(
        base.text_muted,
        &.{ ground, base.surface, colors.surface_subtle },
        7.0,
    );
    colors.focus_ring = ink;

    colors.accent = pushAway(base.accent, &.{label}, 7.0);
    colors.accent_text = label;
    colors.destructive = pushAway(base.destructive, &.{label}, 7.0);
    colors.destructive_text = label;
    colors.success = pushAway(base.success, &.{label}, 7.0);
    colors.success_text = label;
    colors.warning = pushAway(base.warning, &.{label}, 7.0);
    colors.warning_text = label;
    colors.info = pushAway(base.info, &.{label}, 7.0);
    colors.info_text = label;

    return colors;
}

/// The tokens for the current model state. The runtime asks for these
/// on every rebuild, so changing the theme is a model change and
/// nothing else.
pub fn tokens(model: *const Model) DesignTokens {
    const chosen = model.theme_palette;
    if (!model.theme_contrast_high) return register(chosen);
    return withColors(highContrast(register(chosen).colors, chosen.is_dark()));
}
