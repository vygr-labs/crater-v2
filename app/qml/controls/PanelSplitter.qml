import QtQuick

// Drag handle on the line between two console panels (Main.qml). Invisible
// until hovered, then a brand-coloured line shows where the edge will go.
//
//   PanelSplitter {
//       vertical: true                    // a vertical line, dragged sideways
//       onMoved: function(delta) { ... }  // px from where the press started
//       onReleased: { ... }               // persist
//       onReset: { ... }                  // double-click: back to default
//   }
//
// The delta is measured in the coordinates of `frame`, not the handle's
// own, because the handle moves with the edge it is dragging. Measuring
// against itself would feed each step back into the next.
Item {
    id: root

    property bool vertical: true
    // A stable ancestor to measure the drag in. Defaults to the parent.
    property Item frame: parent
    readonly property bool active: ma.pressed || ma.containsMouse
    // True from press to release. A splitter whose panel collapses under
    // the drag stays visible while this holds, so the same drag can pull
    // the panel back out.
    readonly property bool dragging: ma.pressed

    signal pressed()
    signal moved(real delta)
    signal released()
    signal reset()

    // Hit area wider than the 1px line it sits on. A vertical one reaches
    // only 2px into the panel on its left: every panel's scrollbar runs
    // down its right edge, so a centred handle would cover part of it.
    // Callers place it at `line - leftOverlap`.
    width:  vertical ? 8 : undefined
    height: vertical ? undefined : 8
    readonly property int leftOverlap: vertical ? 2 : 4
    z: 50

    // The highlight sits on the line itself.
    Rectangle {
        x: root.vertical ? root.leftOverlap - 1 : 0
        y: root.vertical ? 0 : root.leftOverlap - 1
        width:  root.vertical ? 2 : parent.width
        height: root.vertical ? parent.height : 2
        color: Theme.color.brand
        opacity: root.active ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.motion.instant } }
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        cursorShape: root.vertical ? Qt.SplitHCursor : Qt.SplitVCursor
        preventStealing: true

        property real _start: 0
        function _pos(mouse) {
            const p = mapToItem(root.frame, mouse.x, mouse.y)
            return root.vertical ? p.x : p.y
        }
        onPressed: function(mouse) {
            _start = _pos(mouse)
            root.pressed()
        }
        onPositionChanged: function(mouse) {
            if (pressed) root.moved(_pos(mouse) - _start)
        }
        onReleased: root.released()
        onCanceled: root.released()
        onDoubleClicked: root.reset()
    }
}
