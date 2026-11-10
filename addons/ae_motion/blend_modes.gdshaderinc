// blend_modes.gdshaderinc
// ae-motion 1.0 — blend-mode library for Godot 4 canvas_item shaders.
//
// WHY THIS EXISTS
// Godot's CanvasItemMaterial only offers Mix / Add / Sub / Mul. AE's blend
// modes (Overlay, Linear Burn, Vivid Light, ...) have to be computed in a
// shader that samples the already-drawn backdrop through
// `hint_screen_texture`, which means you need a BackBufferCopy node placed
// right before the blended node.
//
// COMPOSITING FORMULA (get this wrong and everything looks washed out):
//     out = mix(backdrop, blend(backdrop, source), src_alpha * layer_opacity)
// i.e. opacity interpolates AFTER blending, not inside it.
//
// COLOUR SPACE
// These formulas assume sRGB-ish, per-channel math — the same thing AE calls
// "Classic" blend modes. If your project runs a linear pipeline, results will
// differ unless you convert. Keep AE on CLASSIC_* while this is in use.
//
// NOT PROVIDED: Hue / Saturation / Color / Luminosity. Those need a full
// RGB<->HSL round trip and cannot be done correctly per-layer on top of an
// arbitrary backdrop. Precompose them in AE instead.

// ---------------------------------------------------------------------------
// Mode ids — keep in sync with ae-motion.md and with the JSON `blend.role`.
// ---------------------------------------------------------------------------

const int AE_BLEND_NORMAL       = 0;
const int AE_BLEND_MULTIPLY     = 1;
const int AE_BLEND_SCREEN       = 2;
const int AE_BLEND_OVERLAY      = 3;
const int AE_BLEND_DARKEN       = 4;
const int AE_BLEND_LIGHTEN      = 5;
const int AE_BLEND_COLOR_DODGE  = 6;
const int AE_BLEND_COLOR_BURN   = 7;
const int AE_BLEND_LINEAR_DODGE = 8;
const int AE_BLEND_LINEAR_BURN  = 9;
const int AE_BLEND_HARD_LIGHT   = 10;
const int AE_BLEND_SOFT_LIGHT   = 11;
const int AE_BLEND_VIVID_LIGHT  = 12;
const int AE_BLEND_LINEAR_LIGHT = 13;
const int AE_BLEND_PIN_LIGHT    = 14;
const int AE_BLEND_HARD_MIX     = 15;
const int AE_BLEND_DIFFERENCE   = 16;
const int AE_BLEND_EXCLUSION    = 17;
const int AE_BLEND_SUBTRACT     = 18;
const int AE_BLEND_DIVIDE       = 19;
const int AE_BLEND_DARKER_COLOR = 20;
const int AE_BLEND_LIGHTER_COLOR = 21;

const float AE_EPS = 1e-5;

// ---------------------------------------------------------------------------
// Primitives
// ---------------------------------------------------------------------------

vec3 ae_blend_normal(vec3 cb, vec3 cs) { return cs; }

vec3 ae_blend_multiply(vec3 cb, vec3 cs) { return cb * cs; }

vec3 ae_blend_screen(vec3 cb, vec3 cs) { return cb + cs - cb * cs; }

vec3 ae_blend_overlay(vec3 cb, vec3 cs) {
    return mix(2.0 * cb * cs, 1.0 - 2.0 * (1.0 - cb) * (1.0 - cs), step(vec3(0.5), cb));
}

vec3 ae_blend_darken(vec3 cb, vec3 cs) { return min(cb, cs); }

vec3 ae_blend_lighten(vec3 cb, vec3 cs) { return max(cb, cs); }

vec3 ae_blend_color_dodge(vec3 cb, vec3 cs) {
    vec3 safe = max(1.0 - cs, vec3(AE_EPS));
    return mix(min(vec3(1.0), cb / safe), vec3(1.0), step(vec3(1.0), cs));
}

vec3 ae_blend_color_burn(vec3 cb, vec3 cs) {
    vec3 safe = max(cs, vec3(AE_EPS));
    return mix(1.0 - min(vec3(1.0), (1.0 - cb) / safe), vec3(0.0), step(cs, vec3(AE_EPS)));
}

vec3 ae_blend_linear_dodge(vec3 cb, vec3 cs) { return min(vec3(1.0), cb + cs); }

vec3 ae_blend_linear_burn(vec3 cb, vec3 cs) { return max(vec3(0.0), cb + cs - 1.0); }

vec3 ae_blend_hard_light(vec3 cb, vec3 cs) { return ae_blend_overlay(cs, cb); }

vec3 ae_blend_soft_light(vec3 cb, vec3 cs) {
    vec3 d = mix(sqrt(cb), ((16.0 * cb - 12.0) * cb + 4.0) * cb, step(vec3(0.25), cb));
    vec3 lo = cb - (1.0 - 2.0 * cs) * cb * (1.0 - cb);
    vec3 hi = cb + (2.0 * cs - 1.0) * (d - cb);
    return mix(lo, hi, step(vec3(0.5), cs));
}

vec3 ae_blend_vivid_light(vec3 cb, vec3 cs) {
    vec3 lo = ae_blend_color_burn(cb, min(vec3(1.0), 2.0 * cs));
    vec3 hi = ae_blend_color_dodge(cb, max(vec3(0.0), 2.0 * cs - 1.0));
    return mix(lo, hi, step(vec3(0.5), cs));
}

vec3 ae_blend_linear_light(vec3 cb, vec3 cs) {
    return clamp(cb + 2.0 * cs - 1.0, vec3(0.0), vec3(1.0));
}

vec3 ae_blend_pin_light(vec3 cb, vec3 cs) {
    vec3 lo = min(cb, 2.0 * cs);
    vec3 hi = max(cb, 2.0 * cs - 1.0);
    return mix(lo, hi, step(vec3(0.5), cs));
}

vec3 ae_blend_hard_mix(vec3 cb, vec3 cs) {
    return step(vec3(1.0), cb + cs);
}

vec3 ae_blend_difference(vec3 cb, vec3 cs) { return abs(cb - cs); }

vec3 ae_blend_exclusion(vec3 cb, vec3 cs) { return cb + cs - 2.0 * cb * cs; }

vec3 ae_blend_subtract(vec3 cb, vec3 cs) { return max(vec3(0.0), cb - cs); }

vec3 ae_blend_divide(vec3 cb, vec3 cs) {
    return min(vec3(1.0), cb / max(cs, vec3(AE_EPS)));
}

vec3 ae_blend_darker_color(vec3 cb, vec3 cs) {
    float lb = dot(cb, vec3(0.299, 0.587, 0.114));
    float ls = dot(cs, vec3(0.299, 0.587, 0.114));
    return (ls < lb) ? cs : cb;
}

vec3 ae_blend_lighter_color(vec3 cb, vec3 cs) {
    float lb = dot(cb, vec3(0.299, 0.587, 0.114));
    float ls = dot(cs, vec3(0.299, 0.587, 0.114));
    return (ls > lb) ? cs : cb;
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

vec3 ae_blend(vec3 cb, vec3 cs, int mode) {
    if (mode == AE_BLEND_MULTIPLY)     return ae_blend_multiply(cb, cs);
    if (mode == AE_BLEND_SCREEN)       return ae_blend_screen(cb, cs);
    if (mode == AE_BLEND_OVERLAY)      return ae_blend_overlay(cb, cs);
    if (mode == AE_BLEND_DARKEN)       return ae_blend_darken(cb, cs);
    if (mode == AE_BLEND_LIGHTEN)      return ae_blend_lighten(cb, cs);
    if (mode == AE_BLEND_COLOR_DODGE)  return ae_blend_color_dodge(cb, cs);
    if (mode == AE_BLEND_COLOR_BURN)   return ae_blend_color_burn(cb, cs);
    if (mode == AE_BLEND_LINEAR_DODGE) return ae_blend_linear_dodge(cb, cs);
    if (mode == AE_BLEND_LINEAR_BURN)  return ae_blend_linear_burn(cb, cs);
    if (mode == AE_BLEND_HARD_LIGHT)   return ae_blend_hard_light(cb, cs);
    if (mode == AE_BLEND_SOFT_LIGHT)   return ae_blend_soft_light(cb, cs);
    if (mode == AE_BLEND_VIVID_LIGHT)  return ae_blend_vivid_light(cb, cs);
    if (mode == AE_BLEND_LINEAR_LIGHT) return ae_blend_linear_light(cb, cs);
    if (mode == AE_BLEND_PIN_LIGHT)    return ae_blend_pin_light(cb, cs);
    if (mode == AE_BLEND_HARD_MIX)     return ae_blend_hard_mix(cb, cs);
    if (mode == AE_BLEND_DIFFERENCE)   return ae_blend_difference(cb, cs);
    if (mode == AE_BLEND_EXCLUSION)    return ae_blend_exclusion(cb, cs);
    if (mode == AE_BLEND_SUBTRACT)     return ae_blend_subtract(cb, cs);
    if (mode == AE_BLEND_DIVIDE)       return ae_blend_divide(cb, cs);
    if (mode == AE_BLEND_DARKER_COLOR) return ae_blend_darker_color(cb, cs);
    if (mode == AE_BLEND_LIGHTER_COLOR) return ae_blend_lighter_color(cb, cs);
    return ae_blend_normal(cb, cs);
}

// The formula the whole file exists for. `a` already includes layer opacity.
vec3 ae_composite(vec3 cb, vec3 cs, float a, int mode) {
    return mix(cb, ae_blend(cb, cs, mode), clamp(a, 0.0, 1.0));
}

// ---------------------------------------------------------------------------
// Single-channel helpers (JSON channelPlan == "multiplier" / "alpha_only")
// ---------------------------------------------------------------------------

// Multiply family shipped as one channel: m = (1 - a) + a * C.
// IMPORTANT: an uninitialised texture must be filled with the neutral value
// 1.0, never 0.0 — a 0 multiplier turns the whole screen black.
vec3 ae_apply_multiplier(vec3 cb, float m) { return cb * m; }

// A layer whose colour is constant: keep the mask in one channel and tint it.
vec3 ae_tint_alpha(float mask, vec3 constant_color) { return constant_color * mask; }
