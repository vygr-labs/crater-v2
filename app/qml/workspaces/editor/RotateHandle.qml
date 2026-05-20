import QtQuick
import Crater

// Rotation affordance — circle-on-a-stick handle anchored above the
// selected node's top edge. Drag rotates the node around its center;
// Shift snaps to 15° increments.
//
// Renders as a child of NodeDelegate, so it inherits the parent's
// rotation/skew/scale transforms — the handle visually "sticks" to the
// top of the shape regardless of how it's oriented. The drag math
// projects mouse events into the parent's stage frame (which doesn't
// move during a drag) so the rotation reads from real cursor
// displacement, not a self-cancelling local delta.
Item {
    id: handle
    property var parentNode    // NodeDelegate

    readonly property bool _isLocked: parentNode._locked
    visible: !_isLocked

    // Tall enough to contain the connecting line + grip dot. Width gives
    // the MouseArea a generous click target.
    width: 20; height: 30

    Component.onCompleted: _placeAnchors()
    function _placeAnchors() {
        anchors.horizontalCenter = parentNode.horizontalCenter
        anchors.bottom = parentNode.top
        anchors.bottomMargin = 4
    }

    // Connecting line — runs from just above the bbox up to the grip.
    Rectangle {
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        width: 2
        height: 14
        color: Theme.color.brand
    }

    // Grip circle — white fill / brand outline (inverse of resize handles'
    // brand-fill style) so the two handle families read as visually
    // distinct at a glance.
    Rectangle {
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        width: 14; height: 14; radius: 7
        color: "#ffffff"
        border.color: Theme.color.brand
        border.width: 2
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        anchors.margins: -4    // generous click target around the 14px circle
        cursorShape: Qt.PointingHandCursor

        property bool _rotating: false
        property bool _rotated:  false  // a real rotation happened this press
        property real _startAngle: 0   // cursor's angle at press, radians
        property real _startRot:   0   // node rotation at press, degrees
        property real _centerX:    0   // node center in stage frame
        property real _centerY:    0

        onPressed: function(m) {
            if (handle._isLocked) return
            const node = handle.parentNode
            // Node center in stage (== node.parent's) frame.
            const c = node.mapToItem(node.parent, node.width / 2, node.height / 2)
            _centerX = c.x
            _centerY = c.y
            const p = mapToItem(node.parent, m.x, m.y)
            _startAngle = Math.atan2(p.y - _centerY, p.x - _centerX)
            _startRot   = node._style.rotation || 0
            _rotating   = true
            _rotated    = false
            // No saveToHistory here — a press-without-drag must not
            // create an undo step. Snapshot on release, only if rotated.
        }
        onPositionChanged: function(m) {
            if (!_rotating || !pressed) return
            _rotated = true
            const node = handle.parentNode
            const p = mapToItem(node.parent, m.x, m.y)
            const angle = Math.atan2(p.y - _centerY, p.x - _centerX)
            let rot = _startRot + (angle - _startAngle) * 180 / Math.PI
            // Wrap to a sane display range. The renderer doesn't care
            // about the modular value, but the input shows it and ±360°
            // is friendlier than ±9999°.
            while (rot >  360) rot -= 360
            while (rot < -360) rot += 360
            // Shift snaps to 15° — same convention Figma / Illustrator
            // use for "constrain to nice angles" rotation.
            if (m.modifiers & Qt.ShiftModifier) {
                rot = Math.round(rot / 15) * 15
            }
            node.workspace.workingTheme.setNodeStyle(
                node.nodeId, "rotation", Math.round(rot * 10) / 10)
        }
        onReleased: {
            if (_rotating && _rotated) handle.parentNode.workspace.saveToHistory()
            _rotating = false
            _rotated  = false
        }
    }
}
