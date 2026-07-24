pragma Singleton

import QtQuick

// GradientPresets — the shared data + math behind the friendly gradient tool.
// Curated professional gradient presets, a one-color "harmony" generator (so a
// user who doesn't know color theory can get a tasteful multi-stop gradient
// from a single pick), and the colour helpers both the editor and the harmony
// generator lean on. Pure data + functions, reusable anywhere.
//
// Canonical gradient spec (what GradientFill, GradientText and the editor all
// speak):
//   { style:  "linear"|"radial"|"conic"|"mesh"|"reflected"|"diamond",
//     stops:  [ { color: "#rrggbb"|"#aarrggbb", pos: 0..1 }, … ],  // 2..6
//     angle:  0..360,      // linear/reflected direction, conic offset
//     speed:  0.1..3.0,    // flow rate (conic / mesh)
//     animate: bool,       // opt out of flow
//     finish: "none"|"glossy"|"matte" }
//
// Legacy specs shaped { colors:[…] } (no positions) are still understood by
// GradientFill; normalize() upgrades them to positioned stops.
QtObject {
    id: gp

    // ── Style + finish vocab (for pickers) ──────────────────────────────
    readonly property var styles: [
        { value: "linear",    label: qsTr("Linear") },
        { value: "radial",    label: qsTr("Radial") },
        { value: "conic",     label: qsTr("Angular") },
        { value: "reflected", label: qsTr("Reflected") },
        { value: "diamond",   label: qsTr("Diamond") },
        { value: "mesh",      label: qsTr("Aurora") }
    ]
    readonly property var finishes: [
        { value: "none",   label: qsTr("Flat") },
        { value: "glossy", label: qsTr("Glossy") },
        { value: "matte",  label: qsTr("Matte") }
    ]
    // Styles whose flow the `time` uniform actually drives.
    function isAnimatable(style) { return style === "conic" || style === "mesh" }

    // ── Curated presets ─────────────────────────────────────────────────
    // Hand-tuned so any of them reads well with no further editing. `metallic`
    // flags the ones that shine as a text fill (glossy digits); the rest are
    // primarily backgrounds — the editor just labels, it doesn't restrict.
    readonly property var presets: [
        { id: "glossyGold",  name: qsTr("Glossy Gold"),  metallic: true,
          spec: { style: "linear", angle: 90, finish: "glossy", animate: false, stops: [
            { color: "#7a5a12", pos: 0.0 }, { color: "#f6d979", pos: 0.42 },
            { color: "#fff6c9", pos: 0.5 }, { color: "#c9962f", pos: 0.62 },
            { color: "#6e4e10", pos: 1.0 } ] } },
        { id: "roseGold",    name: qsTr("Rose Gold"),    metallic: true,
          spec: { style: "linear", angle: 90, finish: "glossy", animate: false, stops: [
            { color: "#7d4a43", pos: 0.0 }, { color: "#e6a79a", pos: 0.45 },
            { color: "#ffe3dc", pos: 0.5 }, { color: "#c67d70", pos: 0.7 },
            { color: "#6f403a", pos: 1.0 } ] } },
        { id: "silver",      name: qsTr("Silver"),       metallic: true,
          spec: { style: "linear", angle: 90, finish: "glossy", animate: false, stops: [
            { color: "#6b7280", pos: 0.0 }, { color: "#d7dbe0", pos: 0.46 },
            { color: "#ffffff", pos: 0.5 }, { color: "#9aa1ab", pos: 0.66 },
            { color: "#5a616b", pos: 1.0 } ] } },
        { id: "ember",       name: qsTr("Ember"),        metallic: true,
          spec: { style: "linear", angle: 90, finish: "glossy", animate: false, stops: [
            { color: "#7a1f0a", pos: 0.0 }, { color: "#f0641e", pos: 0.5 },
            { color: "#ffd08a", pos: 0.55 }, { color: "#b23411", pos: 1.0 } ] } },
        { id: "emerald",     name: qsTr("Emerald"),      metallic: true,
          spec: { style: "linear", angle: 90, finish: "glossy", animate: false, stops: [
            { color: "#0b3f2b", pos: 0.0 }, { color: "#37c98a", pos: 0.48 },
            { color: "#c9ffe8", pos: 0.5 }, { color: "#128a5b", pos: 0.7 },
            { color: "#093524", pos: 1.0 } ] } },
        { id: "ivory",       name: qsTr("Ivory"),        metallic: false,
          spec: { style: "linear", angle: 90, finish: "none", animate: false, stops: [
            { color: "#ffffff", pos: 0.0 }, { color: "#f3efe2", pos: 0.55 },
            { color: "#ded7c2", pos: 1.0 } ] } },
        { id: "sunset",      name: qsTr("Sunset"),       metallic: false,
          spec: { style: "linear", angle: 120, finish: "none", animate: false, stops: [
            { color: "#f9a03f", pos: 0.0 }, { color: "#e0508f", pos: 0.55 },
            { color: "#5b2a86", pos: 1.0 } ] } },
        { id: "ocean",       name: qsTr("Ocean"),        metallic: false,
          spec: { style: "linear", angle: 135, finish: "none", animate: false, stops: [
            { color: "#0ea5b5", pos: 0.0 }, { color: "#1e5fb0", pos: 0.6 },
            { color: "#132a63", pos: 1.0 } ] } },
        { id: "aurora",      name: qsTr("Aurora"),       metallic: false,
          spec: { style: "mesh", angle: 0, finish: "none", animate: true, speed: 1.0, stops: [
            { color: "#0b3d2e", pos: 0.0 }, { color: "#1f9e78", pos: 0.4 },
            { color: "#3ad0c0", pos: 0.7 }, { color: "#6c3fb5", pos: 1.0 } ] } },
        { id: "royal",       name: qsTr("Royal"),        metallic: true,
          spec: { style: "radial", angle: 0, finish: "glossy", animate: false, stops: [
            { color: "#7c3aed", pos: 0.0 }, { color: "#4c1d95", pos: 0.65 },
            { color: "#20103f", pos: 1.0 } ] } },
        { id: "midnight",    name: qsTr("Midnight"),     metallic: false,
          spec: { style: "linear", angle: 90, finish: "none", animate: false, stops: [
            { color: "#1a2540", pos: 0.0 }, { color: "#0b1020", pos: 0.6 },
            { color: "#05060c", pos: 1.0 } ] } },
        { id: "slate",       name: qsTr("Matte Slate"),  metallic: false,
          spec: { style: "linear", angle: 90, finish: "matte", animate: false, stops: [
            { color: "#3b4657", pos: 0.0 }, { color: "#2a323f", pos: 1.0 } ] } },
        { id: "charcoal",    name: qsTr("Matte Charcoal"), metallic: false,
          spec: { style: "linear", angle: 90, finish: "matte", animate: false, stops: [
            { color: "#26262b", pos: 0.0 }, { color: "#141418", pos: 1.0 } ] } },
        { id: "sky",         name: qsTr("Sky"),          metallic: false,
          spec: { style: "linear", angle: 90, finish: "none", animate: false, stops: [
            { color: "#bfe6ff", pos: 0.0 }, { color: "#5aa9e6", pos: 0.6 },
            { color: "#2563cc", pos: 1.0 } ] } },
        { id: "neon",        name: qsTr("Neon"),         metallic: false,
          spec: { style: "conic", angle: 0, finish: "none", animate: true, speed: 0.8, stops: [
            { color: "#ff2d95", pos: 0.0 }, { color: "#7c3aed", pos: 0.34 },
            { color: "#22d3ee", pos: 0.67 }, { color: "#ff2d95", pos: 1.0 } ] } }
    ]

    function presetById(id) {
        for (var i = 0; i < presets.length; ++i)
            if (presets[i].id === id) return presets[i]
        return null
    }

    // ── Spec normalization ──────────────────────────────────────────────
    // Always returns a fresh, valid, positioned-stop spec. Accepts the modern
    // { stops } shape, the legacy { colors } shape, or a half-set object.
    function normalize(spec) {
        var s = spec || {}
        var stops = []
        if (s.stops && s.stops.length >= 1) {
            for (var i = 0; i < s.stops.length && stops.length < 6; ++i) {
                var st = s.stops[i] || {}
                stops.push({ color: st.color || "#ffffff",
                             pos: _clamp01(st.pos !== undefined ? st.pos : i / Math.max(1, s.stops.length - 1)) })
            }
        } else if (s.colors && s.colors.length >= 1) {
            stops = evenStops(s.colors)
        }
        if (stops.length < 2) {
            stops = evenStops(["#1e3a8a", "#7c3aed", "#db2777"])
        }
        stops.sort(function(a, b) { return a.pos - b.pos })
        return {
            style:   s.style || "linear",
            stops:   stops,
            angle:   (s.angle !== undefined) ? s.angle : 90,
            speed:   (s.speed !== undefined) ? s.speed : 1.0,
            animate: s.animate !== false,
            finish:  s.finish || "none"
        }
    }

    // Evenly distribute colors as positioned stops.
    function evenStops(colors) {
        var out = []
        var n = Math.max(2, Math.min(6, colors.length))
        for (var i = 0; i < n; ++i)
            out.push({ color: colors[i], pos: (n === 1) ? 0 : i / (n - 1) })
        return out
    }

    // Deep-ish copy so callers never mutate a preset in place.
    function cloneSpec(spec) {
        var s = normalize(spec)
        var stops = []
        for (var i = 0; i < s.stops.length; ++i)
            stops.push({ color: s.stops[i].color, pos: s.stops[i].pos })
        s.stops = stops
        return s
    }

    // ── Harmony: one color → a tasteful multi-stop gradient ─────────────
    // modes: "shades" | "analogous" | "complementary" | "triad" | "vibrant".
    function harmony(baseHex, mode) {
        var hsl = hexToHsl(baseHex)
        if (!hsl) hsl = { h: 210, s: 0.6, l: 0.5 }
        var cols
        switch (mode) {
        case "shades":
            cols = [ hslToHex(hsl.h, hsl.s, _clamp01(hsl.l * 0.55)),
                     hslToHex(hsl.h, hsl.s, hsl.l),
                     hslToHex(hsl.h, hsl.s * 0.9, _clamp01(hsl.l * 1.35)) ]
            break
        case "complementary":
            cols = [ hslToHex(hsl.h, hsl.s, hsl.l),
                     hslToHex((hsl.h + 30) % 360, hsl.s, _clamp01(hsl.l * 1.05)),
                     hslToHex((hsl.h + 180) % 360, hsl.s, hsl.l) ]
            break
        case "triad":
            cols = [ hslToHex(hsl.h, hsl.s, hsl.l),
                     hslToHex((hsl.h + 120) % 360, hsl.s, hsl.l),
                     hslToHex((hsl.h + 240) % 360, hsl.s, hsl.l) ]
            break
        case "vibrant":
            cols = [ hslToHex((hsl.h + 340) % 360, _clamp01(hsl.s * 1.15), _clamp01(hsl.l * 0.95)),
                     hslToHex(hsl.h, _clamp01(hsl.s * 1.15), hsl.l),
                     hslToHex((hsl.h + 40) % 360, _clamp01(hsl.s * 1.15), _clamp01(hsl.l * 1.05)) ]
            break
        default: // analogous
            cols = [ hslToHex((hsl.h + 330) % 360, hsl.s, _clamp01(hsl.l * 0.9)),
                     hslToHex(hsl.h, hsl.s, hsl.l),
                     hslToHex((hsl.h + 30) % 360, hsl.s, _clamp01(hsl.l * 1.1)) ]
        }
        return { style: "linear", angle: 90, finish: "none", animate: false,
                 stops: evenStops(cols) }
    }

    readonly property var harmonyModes: [
        { value: "shades",        label: qsTr("Shades") },
        { value: "analogous",     label: qsTr("Analogous") },
        { value: "complementary", label: qsTr("Complementary") },
        { value: "triad",         label: qsTr("Triad") },
        { value: "vibrant",       label: qsTr("Vibrant") }
    ]

    // ── Colour helpers (hex ↔ hsl) ──────────────────────────────────────
    function _clamp01(v) { return Math.max(0, Math.min(1, v)) }
    function _pad2(n) { var s = Math.round(n).toString(16); return s.length < 2 ? "0" + s : s }

    // Accepts "#rgb", "#rrggbb", "#aarrggbb" — returns {r,g,b} 0..255 (drops alpha).
    function hexToRgb(hex) {
        if (!hex) return null
        var h = String(hex).replace("#", "")
        if (h.length === 3) h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2]
        if (h.length === 8) h = h.substring(2)       // strip AA
        if (h.length !== 6) return null
        return { r: parseInt(h.substring(0, 2), 16),
                 g: parseInt(h.substring(2, 4), 16),
                 b: parseInt(h.substring(4, 6), 16) }
    }
    function rgbToHex(r, g, b) {
        return "#" + _pad2(r) + _pad2(g) + _pad2(b)
    }
    function hexToHsl(hex) {
        var rgb = hexToRgb(hex)
        if (!rgb) return null
        var r = rgb.r / 255, g = rgb.g / 255, b = rgb.b / 255
        var max = Math.max(r, g, b), min = Math.min(r, g, b)
        var h = 0, s = 0, l = (max + min) / 2
        var d = max - min
        if (d > 0.00001) {
            s = l > 0.5 ? d / (2 - max - min) : d / (max + min)
            if (max === r)      h = (g - b) / d + (g < b ? 6 : 0)
            else if (max === g) h = (b - r) / d + 2
            else                h = (r - g) / d + 4
            h *= 60
        }
        return { h: h, s: s, l: l }
    }
    function hslToHex(h, s, l) {
        h = ((h % 360) + 360) % 360
        s = _clamp01(s); l = _clamp01(l)
        var c = (1 - Math.abs(2 * l - 1)) * s
        var x = c * (1 - Math.abs(((h / 60) % 2) - 1))
        var m = l - c / 2
        var r = 0, g = 0, b = 0
        if      (h < 60)  { r = c; g = x; b = 0 }
        else if (h < 120) { r = x; g = c; b = 0 }
        else if (h < 180) { r = 0; g = c; b = x }
        else if (h < 240) { r = 0; g = x; b = c }
        else if (h < 300) { r = x; g = 0; b = c }
        else              { r = c; g = 0; b = x }
        return rgbToHex((r + m) * 255, (g + m) * 255, (b + m) * 255)
    }
}
