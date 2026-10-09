import QtQuick

// Desktop wheel scrolling for a Flickable / ListView. Declare it inside the
// view and name the view:
//
//   ListView { id: list; DirectWheel { flickable: list } }
//
// Inside a Flickable the handler lands on its content item (see HWheelArea),
// so it sees the wheel over every delegate before the view's own wheel
// handling does, and `parent` is not the view. Hence the explicit property.
//
// Qt's own wheel handling turns each notch into a flick: the list glides on
// after the wheel stops and stretches past the ends before springing back.
// That reads as lag and rubber-banding on a console the operator drives with
// a mouse. Here each notch moves the content a fixed step at once, clamped to
// the ends, so the list stops exactly where the wheel stops. Touchpads send
// pixel deltas, which pass through 1:1.
WheelHandler {
    id: handler

    // The view to scroll.
    required property Flickable flickable
    // Pixels per wheel notch (120 angle units).
    property real step: 120

    target: null
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad

    onWheel: function(event) {
        const f = handler.flickable
        if (!f) return
        const dy = event.pixelDelta.y !== 0 ? event.pixelDelta.y
                                            : event.angleDelta.y / 120 * handler.step
        if (dy === 0) return
        const top = f.originY - f.topMargin
        const bottom = Math.max(top, f.originY + f.contentHeight + f.bottomMargin - f.height)
        f.cancelFlick()
        f.contentY = Math.max(top, Math.min(bottom, f.contentY - dy))
        event.accepted = true
    }
}
