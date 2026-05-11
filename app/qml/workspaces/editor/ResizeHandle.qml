import QtQuick
import Crater

// One of 8 resize handles around a selected NodeDelegate. handleIndex maps
// clockwise starting from the top-left corner:
//   0: TL  1: T  2: TR  3: R  4: BR  5: B  6: BL  7: L
//
// Pulls the parent node's geometry in percentage space so dragging snaps
// cleanly to 0.1% increments — keeps JSON tidy and the on-canvas snap line
// stable.
Rectangle {
    id: handle
    property int handleIndex: 0
    property var parentNode    // NodeDelegate

    readonly property bool _corner: handleIndex === 0 || handleIndex === 2
                                 || handleIndex === 4 || handleIndex === 6
    readonly property bool _isLocked: parentNode._locked

    width: 10; height: 10
    radius: 5
    color: Theme.color.brand
    border.color: "#ffffff"
    border.width: 1
    visible: !_isLocked

    // Position relative to parent (NodeDelegate). Anchored by index.
    Component.onCompleted: _placeAnchors()
    function _placeAnchors() {
        switch (handleIndex) {
            case 0: anchors.right = parentNode.left;  anchors.bottom = parentNode.top;    return
            case 1: anchors.horizontalCenter = parentNode.horizontalCenter; anchors.bottom = parentNode.top; return
            case 2: anchors.left  = parentNode.right; anchors.bottom = parentNode.top;    return
            case 3: anchors.left  = parentNode.right; anchors.verticalCenter = parentNode.verticalCenter; return
            case 4: anchors.left  = parentNode.right; anchors.top    = parentNode.bottom; return
            case 5: anchors.horizontalCenter = parentNode.horizontalCenter; anchors.top    = parentNode.bottom; return
            case 6: anchors.right = parentNode.left;  anchors.top    = parentNode.bottom; return
            case 7: anchors.right = parentNode.left;  anchors.verticalCenter = parentNode.verticalCenter; return
        }
    }

    readonly property var _cursors: [
        Qt.SizeFDiagCursor, Qt.SizeVerCursor, Qt.SizeBDiagCursor, Qt.SizeHorCursor,
        Qt.SizeFDiagCursor, Qt.SizeVerCursor, Qt.SizeBDiagCursor, Qt.SizeHorCursor
    ]

    MouseArea {
        id: ma
        anchors.fill: parent
        anchors.margins: -4   // generous click target on a 10px handle
        cursorShape: handle._cursors[handle.handleIndex]
        property bool _resizing: false
        property real _startX: 0
        property real _startY: 0
        property var  _start0: ({ x: 0, y: 0, width: 0, height: 0 })

        onPressed: function(m) {
            if (handle._isLocked) return
            // Convert mouse coords to canvas pixels via the stage scale.
            const p = mapToItem(handle.parentNode.parent, m.x, m.y)
            _startX = p.x
            _startY = p.y
            _start0 = {
                x:      handle.parentNode._style.x      || 0,
                y:      handle.parentNode._style.y      || 0,
                width:  handle.parentNode._style.width  || 0,
                height: handle.parentNode._style.height || 0
            }
            _resizing = true
            handle.parentNode.workspace.saveToHistory()
        }
        onPositionChanged: function(m) {
            if (!_resizing || !pressed) return
            const p = mapToItem(handle.parentNode.parent, m.x, m.y)
            const stageW = handle.parentNode.stageW
            const stageH = handle.parentNode.stageH
            const dxPct = (p.x - _startX) / stageW * 100
            const dyPct = (p.y - _startY) / stageH * 100

            let nx = _start0.x, ny = _start0.y, nw = _start0.width, nh = _start0.height
            const minSize = 1   // 1% of canvas; prevents zero-area glitches

            // Horizontal edges
            if (handle.handleIndex === 0 || handle.handleIndex === 6 || handle.handleIndex === 7) {
                nx = _start0.x + dxPct
                nw = _start0.width - dxPct
                if (nw < minSize) { nx = _start0.x + _start0.width - minSize; nw = minSize }
            } else if (handle.handleIndex === 2 || handle.handleIndex === 3 || handle.handleIndex === 4) {
                nw = _start0.width + dxPct
                if (nw < minSize) nw = minSize
            }
            // Vertical edges
            if (handle.handleIndex === 0 || handle.handleIndex === 1 || handle.handleIndex === 2) {
                ny = _start0.y + dyPct
                nh = _start0.height - dyPct
                if (nh < minSize) { ny = _start0.y + _start0.height - minSize; nh = minSize }
            } else if (handle.handleIndex === 4 || handle.handleIndex === 5 || handle.handleIndex === 6) {
                nh = _start0.height + dyPct
                if (nh < minSize) nh = minSize
            }

            // Clamp to canvas, snap to 0.1%, write back.
            nx = Math.max(0, Math.min(100, Math.round(nx * 10) / 10))
            ny = Math.max(0, Math.min(100, Math.round(ny * 10) / 10))
            nw = Math.max(minSize, Math.min(100, Math.round(nw * 10) / 10))
            nh = Math.max(minSize, Math.min(100, Math.round(nh * 10) / 10))

            const wt = handle.parentNode.workspace.workingTheme
            const id = handle.parentNode.nodeId
            wt.setNodeStyle(id, "x",      nx)
            wt.setNodeStyle(id, "y",      ny)
            wt.setNodeStyle(id, "width",  nw)
            wt.setNodeStyle(id, "height", nh)
        }
        onReleased: _resizing = false
    }
}
