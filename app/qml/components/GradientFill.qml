import QtQuick
import Crater

// Animated gradient fill — renders a linear / radial / conic / mesh gradient
// through a single fragment shader (qml/shaders/gradient.frag, compiled to
// qrc:/crater/shaders/gradient.frag.qsb). Mounted as a container background
// layer by NodeRenderer when a node's data.fill.type is "gradient"; also
// reusable by the editor canvas and theme tiles.
//
// `spec` is the container's data.fill.gradient map:
//   { style:  "linear" | "radial" | "conic" | "mesh",
//     colors: ["#…", …],   // 2..6 stops
//     angle:  0..360,        // degrees (linear direction / conic offset)
//     speed:  number }       // flow-rate multiplier
// Every field has a safe default so a half-set spec still renders.
//
// `animate` gates the per-frame clock. Callers pass false for static surfaces
// (ThemePreview thumbnails) and when SettingsService.reduceMotion is on, so the
// gradient holds a still frame instead of burning a vsync timer per tile.
Item {
    id: root

    property var  spec: ({})
    property bool animate: true

    // Default: deep blue → violet → magenta — a calm worship-background palette
    // that reads well behind white lyric text. Used until the operator picks
    // their own stops.
    readonly property var _colors: (spec && spec.colors && spec.colors.length >= 1)
        ? spec.colors
        : ["#1e3a8a", "#7c3aed", "#db2777"]
    readonly property int _count: Math.max(2, Math.min(6, _colors.length))
    readonly property int _type: {
        switch (spec && spec.style) {
            case "linear": return 0
            case "radial": return 1
            case "conic":  return 2
            default:       return 3   // mesh
        }
    }
    readonly property real _angleRad: ((spec && spec.angle) || 0) * Math.PI / 180
    readonly property real _speed: (spec && spec.speed !== undefined) ? spec.speed : 1.0

    // Final flow gate: the surface must allow animation (live/edit, not a
    // thumbnail, reduceMotion off) AND this gradient must opt in. spec.animate
    // defaults to true (only an explicit false stops it), so older gradients
    // keep flowing.
    readonly property bool _flow: animate && (!spec || spec.animate !== false)

    ShaderEffect {
        id: fx
        anchors.fill: parent
        fragmentShader: "qrc:/crater/shaders/gradient.frag.qsb"

        // Up to six stops. Unused slots fall back to color0 so every uniform is
        // a valid color; the shader ignores them past colorCount.
        property color color0: root._colors[0] !== undefined ? root._colors[0] : "#000000"
        property color color1: root._colors[1] !== undefined ? root._colors[1] : color0
        property color color2: root._colors[2] !== undefined ? root._colors[2] : color0
        property color color3: root._colors[3] !== undefined ? root._colors[3] : color0
        property color color4: root._colors[4] !== undefined ? root._colors[4] : color0
        property color color5: root._colors[5] !== undefined ? root._colors[5] : color0
        property int   colorCount:   root._count
        property int   gradientType: root._type
        property real  angle:        root._angleRad
        property real  time:         0

        // Per-frame clock. FrameAnimation (Qt 6.4+) ticks on the render loop;
        // accumulating frameTime (rather than reading elapsedTime) means a
        // pause/resume never jumps the animation backwards — it just freezes
        // and continues. speed scales the flow rate.
        FrameAnimation {
            running: root._flow
            onTriggered: fx.time += frameTime * root._speed
        }
    }
}
