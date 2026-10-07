import QtQuick

// Mouse wheel for a horizontal ListView / Flickable. A plain wheel only turns
// vertically, which a horizontal view ignores, so this maps it onto contentX.
// A trackpad's sideways swipe (angleDelta.x) wins when present.
//
//   ListView { id: strip; orientation: ListView.Horizontal }
//   HWheelArea { target: strip }
//
// Declare it as a SIBLING after the view, not inside it: children of a
// Flickable land in its scrolling content item. NoButton leaves clicks and
// hover to the cells underneath, and a MouseArea still gets wheel events.
MouseArea {
    id: root

    required property Flickable target

    anchors.fill: target
    acceptedButtons: Qt.NoButton

    onWheel: function(wheel) {
        const d = wheel.angleDelta.x !== 0 ? wheel.angleDelta.x
                                           : wheel.angleDelta.y
        const t = root.target
        const maxX = t.originX + Math.max(0, t.contentWidth - t.width)
        t.contentX = Math.max(t.originX, Math.min(maxX, t.contentX - d))
        wheel.accepted = true
    }
}
