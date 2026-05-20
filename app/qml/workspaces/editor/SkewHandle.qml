import QtQuick
import Crater

// Skew affordance — diamond-on-a-stick handle anchored to the left of
// the selected node's vertical center. Horizontal drag adjusts skewX;
// vertical drag adjusts skewY. A single handle covers both axes
// (diagonal drags produce compound skews); operators who need axis
// isolation use the SkX / SkY numeric inputs in the panel.
//
// Lifecycle and drag math match RotateHandle: child of NodeDelegate so
// it transforms with the parent, mouse events projected into the stage
// frame so the delta reads from real cursor displacement.
Item {
    id: handle
    property var parentNode    // NodeDelegate

    readonly property bool _isLocked: parentNode._locked
    visible: !_isLocked

    // Wide enough for line + diamond inline; tall enough for a generous
    // click target around the 14px grip.
    width: 30; height: 20

    Component.onCompleted: _placeAnchors()
    function _placeAnchors() {
        anchors.right          = parentNode.left
        anchors.rightMargin    = 4
        anchors.verticalCenter = parentNode.verticalCenter
    }

    // Connecting line — runs from just left of the bbox out to the grip.
    Rectangle {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: 14; height: 2
        color: Theme.color.brand
    }

    // Diamond grip — rotated square. Brand fill / white border —
    // intentionally opposite of the rotate handle's white-fill /
    // brand-border so the two affordances are unambiguous at a glance.
    Rectangle {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: 14; height: 14
        color: Theme.color.brand
        border.color: "#ffffff"
        border.width: 1
        rotation: 45
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        anchors.margins: -4
        cursorShape: Qt.SizeAllCursor

        property bool _skewing: false
        property bool _skewed:  false   // a real skew happened this press
        property real _startX: 0
        property real _startY: 0
        property real _startSkewX: 0
        property real _startSkewY: 0

        // Pixels-of-drag → degrees-of-skew ratio. 0.3°/px gives 15° at
        // 50px drag (visible but not extreme); ±45° clamp lands at ~150px
        // of lateral drag — roughly one bbox width on the editor canvas.
        // Operators naturally stop pushing once the shape looks skewed
        // enough.
        readonly property real _ratio: 0.3

        onPressed: function(m) {
            if (handle._isLocked) return
            const node = handle.parentNode
            const p = mapToItem(node.parent, m.x, m.y)
            _startX     = p.x
            _startY     = p.y
            _startSkewX = node._style.skewX || 0
            _startSkewY = node._style.skewY || 0
            _skewing    = true
            _skewed     = false
            // No saveToHistory here — a press-without-drag must not
            // create an undo step. Snapshot on release, only if skewed.
        }
        onPositionChanged: function(m) {
            if (!_skewing || !pressed) return
            _skewed = true
            const node = handle.parentNode
            const p = mapToItem(node.parent, m.x, m.y)
            const dx = p.x - _startX
            const dy = p.y - _startY
            const sx = Math.max(-45, Math.min(45, _startSkewX + dx * _ratio))
            const sy = Math.max(-45, Math.min(45, _startSkewY + dy * _ratio))
            // Shift constrains to one axis at a time — whichever the
            // user has pushed further so far. Matches the "shift =
            // constrain" convention used everywhere else in the editor.
            if (m.modifiers & Qt.ShiftModifier) {
                if (Math.abs(dx) > Math.abs(dy)) {
                    node.workspace.workingTheme.setNodeStyle(
                        node.nodeId, "skewX", Math.round(sx))
                } else {
                    node.workspace.workingTheme.setNodeStyle(
                        node.nodeId, "skewY", Math.round(sy))
                }
            } else {
                node.workspace.workingTheme.setNodeStyle(
                    node.nodeId, "skewX", Math.round(sx))
                node.workspace.workingTheme.setNodeStyle(
                    node.nodeId, "skewY", Math.round(sy))
            }
        }
        onReleased: {
            if (_skewing && _skewed) handle.parentNode.workspace.saveToHistory()
            _skewing = false
            _skewed  = false
        }
    }
}
