import QtQuick
import Crater

// Animated gradient fill — renders a linear / radial / conic / mesh / reflected
// / diamond gradient through a single fragment shader (qml/shaders/gradient.frag,
// compiled to qrc:/crater/shaders/gradient.frag.qsb). Mounted as a container
// background layer by NodeRenderer when a node's data.fill.type is "gradient",
// masked by GradientText to fill text, and used by the gradient editor preview.
//
// `spec` is the canonical gradient spec (see GradientPresets.qml):
//   { style, stops:[{color,pos}], angle, speed, animate, finish }
// Legacy specs shaped { colors:[…] } (no positions) still render — normalize()
// upgrades them to evenly-positioned stops, so existing themes are unchanged.
//
// `animate` gates the per-frame clock. Callers pass false for static surfaces
// (ThemePreview thumbnails) and when SettingsService.reduceMotion is on, so the
// gradient holds a still frame instead of burning a vsync timer per tile.
Item {
    id: root

    property var  spec: ({})
    property bool animate: true

    // Normalized once — positioned stops, valid style/angle/finish.
    readonly property var  _n:     GradientPresets.normalize(spec)
    readonly property var  _stops: _n.stops
    readonly property int  _count: Math.max(2, Math.min(6, _stops.length))
    readonly property int  _type: {
        switch (_n.style) {
            case "radial":    return 1
            case "conic":     return 2
            case "mesh":      return 3
            case "reflected": return 4
            case "diamond":   return 5
            default:          return 0   // linear
        }
    }
    readonly property int  _finish: _n.finish === "glossy" ? 1
                                  : _n.finish === "matte"  ? 2 : 0
    readonly property real _angleRad: ((_n.angle) || 0) * Math.PI / 180
    readonly property real _speed: _n.speed

    // Only the periodic styles (conic / mesh) consume `time`; a static linear/
    // radial/reflected/diamond gradient runs no FrameAnimation at all.
    readonly property bool _flow: animate && (_n.animate !== false)
                               && (_type === 2 || _type === 3)

    ShaderEffect {
        id: fx
        anchors.fill: parent
        fragmentShader: "qrc:/crater/shaders/gradient.frag.qsb"

        // Up to six stops. Unused color slots fall back to color0; unused
        // offsets to 1.0 (never read past colorCount, but every uniform must
        // be valid).
        property color color0: root._stops[0] !== undefined ? root._stops[0].color : "#000000"
        property color color1: root._stops[1] !== undefined ? root._stops[1].color : color0
        property color color2: root._stops[2] !== undefined ? root._stops[2].color : color0
        property color color3: root._stops[3] !== undefined ? root._stops[3].color : color0
        property color color4: root._stops[4] !== undefined ? root._stops[4].color : color0
        property color color5: root._stops[5] !== undefined ? root._stops[5].color : color0
        property real  offset0: root._stops[0] !== undefined ? root._stops[0].pos : 0.0
        property real  offset1: root._stops[1] !== undefined ? root._stops[1].pos : 1.0
        property real  offset2: root._stops[2] !== undefined ? root._stops[2].pos : 1.0
        property real  offset3: root._stops[3] !== undefined ? root._stops[3].pos : 1.0
        property real  offset4: root._stops[4] !== undefined ? root._stops[4].pos : 1.0
        property real  offset5: root._stops[5] !== undefined ? root._stops[5].pos : 1.0
        property int   colorCount:   root._count
        property int   gradientType: root._type
        property int   finish:       root._finish
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
