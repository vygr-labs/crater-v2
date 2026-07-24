import QtQuick
import QtQuick.Effects
import Crater

// Gradient-filled text — the signature "glossy gold countdown digits" look.
// The text is captured to a texture and used as an alpha mask over a full-bleed
// GradientFill, so the gradient (glossy/matte, any style) shows only through the
// glyphs. Reusable anywhere a gradient text fill is wanted; the live overlay
// uses it for timer/clock/message text.
//
// Both the text and the gradient are rendered through ShaderEffectSource (which
// captures even a hidden source item into a texture — a plain `visible:false`
// + `layer.enabled` item can yield an empty layer), then composited by a
// MultiEffect masking pass.
//
// Size is explicit (fontPixelSize) — callers that need auto-fit compute the
// size themselves (LiveOverlayLayer sizes to a fraction of its height).
Item {
    id: root

    property string text: ""
    property var    spec: ({})
    property bool   animate: true

    property string fontFamily: Theme.font.family
    property int    fontPixelSize: 48
    property int    fontWeight: Theme.font.weightBold
    property bool   fontItalic: false
    property real   letterSpacing: 0
    property int    horizontalAlignment: Text.AlignHCenter
    property int    verticalAlignment: Text.AlignVCenter
    property int    wrapMode: Text.NoWrap
    property int    maximumLineCount: 1

    // Painted glyph height (px) — callers stack a caption beneath the digits.
    readonly property real contentHeight: label.contentHeight

    // ── Mask: white glyphs on transparent (captured even though hidden) ──
    Text {
        id: label
        anchors.fill: parent
        visible: false
        text: root.text
        color: "#ffffff"
        font.family: root.fontFamily
        font.pixelSize: root.fontPixelSize
        font.weight: root.fontWeight
        font.italic: root.fontItalic
        font.letterSpacing: root.letterSpacing
        horizontalAlignment: root.horizontalAlignment
        verticalAlignment: root.verticalAlignment
        wrapMode: root.wrapMode
        maximumLineCount: root.maximumLineCount
        elide: Text.ElideRight
    }
    ShaderEffectSource {
        id: maskTex
        anchors.fill: parent
        sourceItem: label
        hideSource: true
        live: true          // digits change every tick — must re-capture
    }

    // ── The gradient, captured to a texture ─────────────────────────────
    GradientFill {
        id: grad
        anchors.fill: parent
        visible: false
        spec: root.spec
        animate: root.animate
    }
    ShaderEffectSource {
        id: gradTex
        anchors.fill: parent
        sourceItem: grad
        hideSource: true
        // Re-capture per frame only when motion is allowed (flowing gradient
        // or live editing); a static fill under reduceMotion captures once.
        live: root.animate
    }

    // ── Composite: gradient masked by glyph alpha ───────────────────────
    MultiEffect {
        anchors.fill: parent
        source: gradTex
        maskEnabled: true
        maskSource: maskTex
        // Text alpha is anti-aliased; a low threshold + a little spread keeps
        // edges smooth without eating thin strokes.
        maskThresholdMin: 0.15
        maskSpreadAtMin: 0.6
    }
}
