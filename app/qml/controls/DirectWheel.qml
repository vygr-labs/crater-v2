import QtQuick

// Desktop wheel scrolling for a vertical ListView / Flickable.
//
//   ListView { id: list }
//   DirectWheel { target: list }
//
// Qt's own wheel handling turns each notch into a flick: the list glides on
// after the wheel stops and stretches past the ends before springing back,
// and while it is still moving the next click only stops it instead of
// reaching the card under the cursor. Here each notch moves the content a
// fixed step at once, clamped to the ends, so the list is never left moving.
// Touchpads send pixel deltas, which pass through 1:1.
//
// Declare it as a SIBLING after the view, like HWheelArea: children of a
// Flickable land in its scrolling content item. NoButton leaves clicks and
// hover to the rows underneath, and a MouseArea still gets wheel events.
MouseArea {
    id: root

    required property Flickable target
    // Pixels per wheel notch (120 angle units).
    property real step: 120

    anchors.fill: target
    acceptedButtons: Qt.NoButton
    // Off while the view is hidden (Preview swaps in its PDF cropper),
    // so the wheel reaches whatever shows in its place.
    enabled: target.visible

    onWheel: function(wheel) {
        const t = root.target
        // A non-interactive view (the schedule mid-drag) ignores the wheel,
        // as Flickable itself would.
        if (!t.interactive) { wheel.accepted = false; return }
        const dy = wheel.pixelDelta.y !== 0 ? wheel.pixelDelta.y
                                            : wheel.angleDelta.y / 120 * root.step
        if (dy === 0) { wheel.accepted = false; return }
        const top = t.originY - t.topMargin
        const bottom = Math.max(top, t.originY + t.contentHeight + t.bottomMargin - t.height)
        t.cancelFlick()
        t.contentY = Math.max(top, Math.min(bottom, t.contentY - dy))
    }
}
