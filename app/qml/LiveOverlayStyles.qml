pragma Singleton

import QtQuick

// LiveOverlayStyles — the per-type appearance ("theme") for the live overlay.
// Each overlay type (countdown / countup / clock / message) resolves to a style
// object; the operator picks a curated preset or customizes one (font, text
// fill incl. gradient, effect, background) in Settings → Overlay / the Timers
// dialog. Customizations persist via SettingsService.liveOverlayThemes (a JSON
// blob — no theme-table row, no DB migration).
//
// Style object shape:
//   { fontWeight, uppercase, letterSpacing,
//     textFillType: "solid"|"gradient", textColor, textGradient: <spec>,
//     effect: "none"|"shadow"|"glow", effectColor,
//     background: "none"|"dim"|"solid"|"gradient",
//     backgroundColor, backgroundGradient: <spec> }
// Gradient specs are GradientPresets-shaped (see GradientPresets.qml).
QtObject {
    id: styles

    readonly property var types: ["countdown", "countup", "clock", "message"]

    // ── Style construction / normalization ──────────────────────────────
    function _gp(id) {
        var p = GradientPresets.presetById(id)
        return p ? GradientPresets.cloneSpec(p.spec) : GradientPresets.normalize({})
    }

    function defaultStyle() {
        return {
            presetId: "",       // which curated preset this came from ("" = custom)
            fontWeight: 700, uppercase: false, letterSpacing: 0,
            textFillType: "solid", textColor: "#ffffff", textGradient: _gp("glossyGold"),
            effect: "shadow", effectColor: "#000000",
            background: "dim", backgroundColor: "#0a0a0c", backgroundGradient: _gp("midnight")
        }
    }

    // Fill every missing field from the default so a partial/older persisted
    // style still resolves, and normalize the nested gradient specs.
    function normalizeStyle(s) {
        var d = defaultStyle()
        if (!s) return d
        var out = {}
        for (var k in d) out[k] = (s[k] !== undefined && s[k] !== null) ? s[k] : d[k]
        out.textGradient = GradientPresets.normalize(out.textGradient)
        out.backgroundGradient = GradientPresets.normalize(out.backgroundGradient)
        return out
    }

    function cloneStyle(s) {
        var n = normalizeStyle(s)
        n.textGradient = GradientPresets.cloneSpec(n.textGradient)
        n.backgroundGradient = GradientPresets.cloneSpec(n.backgroundGradient)
        return n
    }

    // ── Curated overlay presets ─────────────────────────────────────────
    readonly property var presets: [
        { id: "cleanWhite", name: qsTr("Clean White"), style: {
            fontWeight: 700, uppercase: false, letterSpacing: 0,
            textFillType: "solid", textColor: "#ffffff", textGradient: _gp("glossyGold"),
            effect: "shadow", effectColor: "#000000",
            background: "dim", backgroundColor: "#0a0a0c", backgroundGradient: _gp("midnight") } },
        { id: "glossyGold", name: qsTr("Glossy Gold"), style: {
            fontWeight: 700, uppercase: false, letterSpacing: 0,
            textFillType: "gradient", textColor: "#ffd700", textGradient: _gp("glossyGold"),
            effect: "shadow", effectColor: "#000000",
            background: "solid", backgroundColor: "#0b0b0f", backgroundGradient: _gp("midnight") } },
        { id: "midnightGlow", name: qsTr("Midnight Glow"), style: {
            fontWeight: 700, uppercase: false, letterSpacing: 0,
            textFillType: "solid", textColor: "#eaf2ff", textGradient: _gp("silver"),
            effect: "glow", effectColor: "#3aa0ff",
            background: "gradient", backgroundColor: "#0a0f1e", backgroundGradient: _gp("midnight") } },
        { id: "aurora", name: qsTr("Aurora"), style: {
            fontWeight: 600, uppercase: false, letterSpacing: 0,
            textFillType: "solid", textColor: "#ffffff", textGradient: _gp("emerald"),
            effect: "shadow", effectColor: "#001b12",
            background: "gradient", backgroundColor: "#08110d", backgroundGradient: _gp("aurora") } },
        { id: "ember", name: qsTr("Ember"), style: {
            fontWeight: 700, uppercase: true, letterSpacing: 1,
            textFillType: "gradient", textColor: "#ff7a1a", textGradient: _gp("ember"),
            effect: "glow", effectColor: "#ff3b00",
            background: "solid", backgroundColor: "#140503", backgroundGradient: _gp("midnight") } },
        { id: "matteSlate", name: qsTr("Matte Slate"), style: {
            fontWeight: 600, uppercase: false, letterSpacing: 0,
            textFillType: "solid", textColor: "#e8edf5", textGradient: _gp("silver"),
            effect: "none", effectColor: "#000000",
            background: "gradient", backgroundColor: "#2a323f", backgroundGradient: _gp("slate") } },
        { id: "roseGold", name: qsTr("Rose Gold"), style: {
            fontWeight: 700, uppercase: false, letterSpacing: 0,
            textFillType: "gradient", textColor: "#e6a79a", textGradient: _gp("roseGold"),
            effect: "shadow", effectColor: "#2a0e0a",
            background: "solid", backgroundColor: "#120a09", backgroundGradient: _gp("midnight") } },
        { id: "neon", name: qsTr("Neon"), style: {
            fontWeight: 700, uppercase: true, letterSpacing: 2,
            textFillType: "gradient", textColor: "#22d3ee", textGradient: _gp("neon"),
            effect: "glow", effectColor: "#ff2d95",
            background: "solid", backgroundColor: "#0a0a12", backgroundGradient: _gp("midnight") } }
    ]

    function presetStyle(id) {
        for (var i = 0; i < presets.length; ++i)
            if (presets[i].id === id) {
                var s = normalizeStyle(presets[i].style)
                s.presetId = id
                return s
            }
        return defaultStyle()
    }
    function presetName(id) {
        for (var i = 0; i < presets.length; ++i)
            if (presets[i].id === id) return presets[i].name
        return ""
    }
    // Preset options for a Combobox ({label, value}).
    readonly property var presetOptions: {
        var out = []
        for (var i = 0; i < presets.length; ++i)
            out.push({ label: presets[i].name, value: presets[i].id })
        return out
    }

    // ── Per-type resolution + persistence ───────────────────────────────
    // _byType maps an overlay type → its resolved style object. Loaded from
    // SettingsService.liveOverlayThemes and written back on every change. A
    // type with no entry falls back to a tasteful built-in per-type default.
    property var _byType: ({})

    Component.onCompleted: _load()

    function _load() {
        var m = SettingsService.liveOverlayThemes || {}
        var copy = {}
        for (var k in m) copy[k] = m[k]
        _byType = copy
    }

    function _defaultForType(type) {
        switch (type) {
            case "countdown": return presetStyle("glossyGold")
            case "countup":   return presetStyle("matteSlate")
            case "clock":     return presetStyle("midnightGlow")
            case "message":   return presetStyle("cleanWhite")
        }
        return defaultStyle()
    }

    // Resolved style for a type — the operator's custom/assigned style, else
    // the built-in default.
    function styleFor(type) {
        if (_byType[type]) return normalizeStyle(_byType[type])
        return _defaultForType(type)
    }

    function setStyleFor(type, style) {
        var copy = {}
        for (var k in _byType) copy[k] = _byType[k]
        copy[type] = normalizeStyle(style)
        _byType = copy
        SettingsService.liveOverlayThemes = copy      // persist (JSON blob)
    }

    // Apply a curated preset to a type (tags it so the picker shows its name).
    function applyPreset(type, id) {
        setStyleFor(type, presetStyle(id))
    }

    // Which preset a type currently shows ("" = a hand-edited custom style).
    function assignedPresetId(type) {
        var s = styleFor(type)
        return (s && s.presetId) ? s.presetId : ""
    }
    function assignedLabel(type) {
        var id = assignedPresetId(type)
        return id ? presetName(id) : qsTr("Custom")
    }

    // Drop a type's customization → it reverts to the built-in default.
    function resetType(type) {
        var copy = {}
        for (var k in _byType) if (k !== type) copy[k] = _byType[k]
        _byType = copy
        SettingsService.liveOverlayThemes = copy
    }
}
