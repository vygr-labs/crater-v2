import QtQuick

// Double-click then drag on a library row (press a second time and hold,
// the way Explorer starts a drag) picks the row up for the schedule. A
// double-click without moving is unchanged and comes out as `activated`.
//
// The row keeps its own MouseArea and click routing and feeds the events
// in:
//   MouseArea {
//       id: ma
//       preventStealing: toSchedule.armed
//       onDoubleClicked:   function(mouse) { toSchedule.doubleClicked(mouse) }
//       onPositionChanged: function(mouse) { toSchedule.moved(mouse) }
//       onReleased:        function(mouse) { toSchedule.released(mouse) }
//       onCanceled:        toSchedule.canceled()
//   }
//   ScheduleDragSource {
//       id: toSchedule
//       area: ma
//       payload: function() { return { label: "...", add: function() { ... } } }
//       onActivated: { /* what the double-click did before */ }
//   }
//
// `payload` is read when the drag starts. `add` appends the item the way
// the tab's Add to Schedule does, and the schedule moves it to the drop
// position (AppState "Library drag to the schedule").
QtObject {
    id: root

    property var area: null
    property var payload: null

    // True from the second press until its release. The row's MouseArea
    // binds preventStealing to it so the list doesn't take the movement
    // as a flick.
    readonly property bool armed: _armed

    signal activated()

    property bool _armed: false
    property bool _dragging: false
    property point _press: Qt.point(0, 0)

    function _windowPos(mouse) { return area.mapToItem(null, mouse.x, mouse.y) }

    function doubleClicked(mouse) {
        if (mouse.button !== Qt.LeftButton) return
        _armed = true
        _dragging = false
        _press = _windowPos(mouse)
    }

    function moved(mouse) {
        if (!_armed) return
        const p = _windowPos(mouse)
        if (!_dragging) {
            const d = Qt.styleHints.startDragDistance
            if (Math.abs(p.x - _press.x) < d && Math.abs(p.y - _press.y) < d) return
            const info = typeof payload === "function" ? payload() : null
            if (!info || typeof info.add !== "function") {
                // Nothing to carry. The pointer moved, so this is no longer
                // a double-click either.
                _armed = false
                return
            }
            _dragging = true
            AppState.beginLibraryDrag(info.label || "", info.add)
        }
        AppState.moveLibraryDrag(p.x, p.y)
    }

    function released(mouse) {
        if (!_armed) return
        _armed = false
        if (_dragging) {
            _dragging = false
            const p = _windowPos(mouse)
            AppState.endLibraryDrag(p.x, p.y)
        } else {
            activated()
        }
    }

    function canceled() {
        _armed = false
        if (!_dragging) return
        _dragging = false
        AppState.cancelLibraryDrag()
    }

    // The row can be rebuilt mid-drag (a media import finishing reloads the
    // grid). Its MouseArea never sees the release then, so end the drag
    // here, or the label would stay stuck to the pointer.
    Component.onDestruction: canceled()
}
