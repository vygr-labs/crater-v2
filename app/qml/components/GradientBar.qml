import QtQuick
import Crater

// Interactive gradient bar — the heart of the friendly gradient tool. Shows the
// color ramp (positions honored) with a draggable pin per stop:
//   • drag a pin left/right to reposition (pins can't cross — order stays stable)
//   • click the track between pins to add a stop (color sampled from the ramp)
//   • drag a pin down off the bar to remove it (min 2 stops)
//   • click a pin to select it (its color is edited by the row below, in the
//     GradientEditor)
//
// `stops` is the committed model that drives the Repeater; it is reassigned ONLY
// on structural changes (add / remove / drag-commit), never on every drag tick —
// reassigning it mid-drag would destroy the pin being dragged (same pitfall the
// theme editor's count-keyed stop rows avoid). Live drag feedback rides
// `_dragIndex`/`_dragPos` (the moving pin) and `_rampStops` (the live ramp);
// the parent's big preview follows the non-committing `changed(stops, false)`.
Item {
    id: bar

    property var stops: []        // [{color, pos}] ascending — committed model
    property int selectedIndex: 0

    signal changed(var stops, bool commit)
    signal selected(int index)

    implicitHeight: 42
    readonly property real _trackH: 22
    readonly property real _pad: 9
    readonly property real _removeDragPx: 32   // drag-down distance to delete

    // Live ramp — equals `stops` except mid-drag, when it reflects the moving
    // pin so the ramp follows without rebuilding the pins.
    property var _rampStops: stops
    onStopsChanged: _rampStops = stops
    property int  _dragIndex: -1
    property real _dragPos: 0

    function _clone() {
        var out = []
        for (var i = 0; i < stops.length; ++i)
            out.push({ color: stops[i].color, pos: stops[i].pos })
        return out
    }
    function _lerpColor(a, b, f) {
        var ca = GradientPresets.hexToRgb(a) || { r: 0, g: 0, b: 0 }
        var cb = GradientPresets.hexToRgb(b) || { r: 255, g: 255, b: 255 }
        return GradientPresets.rgbToHex(ca.r + (cb.r - ca.r) * f,
                                        ca.g + (cb.g - ca.g) * f,
                                        ca.b + (cb.b - ca.b) * f)
    }
    function _sampleAt(pos) {
        if (!stops || stops.length === 0) return "#ffffff"
        if (pos <= stops[0].pos) return stops[0].color
        for (var i = 0; i < stops.length - 1; ++i) {
            var a = stops[i], b = stops[i + 1]
            if (pos <= b.pos) {
                var f = (b.pos > a.pos) ? (pos - a.pos) / (b.pos - a.pos) : 0
                return _lerpColor(a.color, b.color, f)
            }
        }
        return stops[stops.length - 1].color
    }
    function _addAt(pos) {
        var s = _clone()
        var idx = s.length
        for (var i = 0; i < s.length; ++i) { if (pos < s[i].pos) { idx = i; break } }
        s.splice(idx, 0, { color: bar._sampleAt(pos), pos: pos })
        bar.changed(s, true)
        bar.selected(idx)
    }
    function _moveLive(index, rawPos) {
        var s = _clone()
        var lo = index > 0 ? s[index - 1].pos + 0.001 : 0
        var hi = index < s.length - 1 ? s[index + 1].pos - 0.001 : 1
        var p = Math.max(lo, Math.min(hi, rawPos))
        s[index].pos = p
        bar._dragIndex = index
        bar._dragPos = p
        bar._rampStops = s
        bar.changed(s, false)          // live preview, does NOT reassign `stops`
    }
    function _commitDrag() {
        if (bar._dragIndex < 0) return
        bar.changed(bar._rampStops, true)
        bar._dragIndex = -1
    }
    function _remove(index) {
        if (stops.length <= 2) return
        var s = _clone()
        s.splice(index, 1)
        bar._dragIndex = -1
        bar.changed(s, true)
        bar.selected(Math.max(0, index - 1))
    }

    // ── Track ramp ──────────────────────────────────────────────────────
    Rectangle {
        id: track
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: bar._pad
        anchors.rightMargin: bar._pad
        anchors.verticalCenter: parent.verticalCenter
        height: bar._trackH
        radius: 4
        clip: true
        color: "transparent"
        border.color: Theme.color.borderStrong
        border.width: 1

        GradientFill {
            anchors.fill: parent
            anchors.margins: 1
            spec: ({ style: "linear", angle: 0, finish: "none", animate: false,
                     stops: bar._rampStops })
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: function(m) { bar._addAt(Math.max(0, Math.min(1, m.x / width))) }
        }
    }

    // ── Stop pins ───────────────────────────────────────────────────────
    Repeater {
        model: bar.stops
        delegate: Item {
            id: pin
            required property int index
            required property var modelData
            readonly property real _pos: bar._dragIndex === index ? bar._dragPos : modelData.pos
            width: 16
            height: bar._trackH + 16
            x: track.x + (_pos * track.width) - width / 2
            anchors.verticalCenter: track.verticalCenter
            z: bar.selectedIndex === index ? 3 : 2

            Rectangle {
                anchors.fill: parent
                radius: 4
                color: Theme.color.elevated
                border.color: bar.selectedIndex === pin.index ? Theme.color.brand
                                                              : Theme.color.borderStrong
                border.width: bar.selectedIndex === pin.index ? 2 : 1
                Rectangle {
                    anchors.centerIn: parent
                    width: 8
                    height: parent.height - 8
                    radius: 2
                    color: pin.modelData.color
                    border.color: "#55000000"
                    border.width: 1
                }
            }

            MouseArea {
                id: pinMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.SizeHorCursor
                onPressed: function(m) { bar.selected(pin.index) }
                onPositionChanged: function(m) {
                    if (!pressed) return
                    var tx = mapToItem(track, m.x, 0).x
                    bar._moveLive(pin.index, tx / track.width)
                }
                onReleased: function(m) {
                    var ty = mapToItem(track, 0, m.y).y
                    if (ty > track.height + bar._removeDragPx && bar.stops.length > 2)
                        bar._remove(pin.index)
                    else
                        bar._commitDrag()
                }
            }
        }
    }
}
