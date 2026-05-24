import QtQuick
import Crater

// One node on the canvas. Renders the node via NodeRenderer (the same
// component the projection window uses) and overlays selection chrome
// (1px outline + 8 resize handles) when selected. Handles its own
// drag-and-select via a MouseArea.
//
// Reactivity: instead of binding directly to workspace.workingTheme.nodes
// (which would force the whole Repeater to rebuild on every style change),
// each delegate keeps a local `node` property that re-fetches from the C++
// WorkingTheme on its granular nodeStyleChanged / nodeDataChanged signals.
// That way only the affected delegate's bindings re-evaluate during drag.
Item {
    id: root
    property var    workspace
    property string nodeId
    property real   stageW: 0
    property real   stageH: 0

    // Local node copy — refreshed by Connections below.
    property var node: workspace.workingTheme.node(nodeId)

    readonly property bool   _selected: workspace.selectedNodeId === nodeId
    readonly property bool   _hidden:   !!(node && node.data && node.data.hidden)
    readonly property bool   _locked:   !!(node && node.data && node.data.locked)
    readonly property var    _style:    node && node.style ? node.style : ({})

    x:        stageW * ((_style.x      || 0) / 100)
    y:        stageH * ((_style.y      || 0) / 100)
    width:    stageW * ((_style.width  || 0) / 100)
    height:   stageH * ((_style.height || 0) / 100)
    z:        _style.z || 0
    opacity:  _hidden ? 0.3 : (_style.opacity !== undefined ? _style.opacity : 1)
    rotation: _style.rotation || 0

    // Center-origin skew. Bakes the pivot into the matrix as
    // T(+center) × Skew × T(-center) so the shape shears around its own
    // bounding-box center (design-tool convention) — Qt's Item has no
    // skew property and Matrix4x4 transforms from local origin (top-
    // left) by default. Applies BEFORE the implicit rotation above
    // (QML transform list runs before Item.rotation), so a skewed
    // parallelogram gets rotated as one unit.
    transform: Matrix4x4 {
        readonly property real _sx: (root._style.skewX || 0) * Math.PI / 180
        readonly property real _sy: (root._style.skewY || 0) * Math.PI / 180
        readonly property real _tx: Math.tan(_sx)
        readonly property real _ty: Math.tan(_sy)
        readonly property real _cx: root.width  / 2
        readonly property real _cy: root.height / 2
        matrix: Qt.matrix4x4(1,   _tx, 0, -_tx * _cy,
                             _ty, 1,   0, -_ty * _cx,
                             0,   0,   1, 0,
                             0,   0,   0, 1)
    }

    Connections {
        target: workspace.workingTheme
        function onNodeStyleChanged(id, field) {
            if (id === root.nodeId) root.node = workspace.workingTheme.node(id)
        }
        function onNodeDataChanged(id, field) {
            if (id === root.nodeId) root.node = workspace.workingTheme.node(id)
        }
        function onNodesChanged() { root.node = workspace.workingTheme.node(root.nodeId) }
    }

    // Render
    NodeRenderer {
        anchors.fill: parent
        node: root.node
        resolvedText: workspace.resolveText(root.node)
    }

    // Selection outline
    Rectangle {
        anchors.fill: parent
        color: "transparent"
        border.color: Theme.color.brand
        border.width: 1
        visible: root._selected
    }

    // Lock badge — bottom-right of node when locked.
    Rectangle {
        visible: root._locked
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 4
        width: 18; height: 18; radius: 3
        color: "#000000A0"
        AppIcon { anchors.centerIn: parent; name: "lock"; size: Theme.icon.xs; color: "#ffffff" }
    }

    // Right-click context menu — sits above the left-button drag MouseArea
    // and accepts only the right button so it never competes with drag. The
    // drag/select MouseArea below stays unchanged.
    RightClickArea {
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        enabled: !root._hidden
        z: 1
        // Hover tracking for the measurement overlay lives HERE, not on
        // dragMa: RightClickArea sets hoverEnabled:true and sits above
        // dragMa (z:1 vs 0), so it is the node's topmost hover-eligible
        // MouseArea — the only one that actually receives hover events.
        // onExited guards against clobbering a newer hovered node when
        // exit/enter of two adjacent nodes interleave.
        onEntered: workspace.hoveredNodeId = root.nodeId
        onExited:  if (workspace.hoveredNodeId === root.nodeId)
                       workspace.hoveredNodeId = ""
        onPositionChanged: function(mouse) {
            // Sample Alt from each hover-move so the overlay tracks the
            // modifier without a separate key handler.
            workspace.measureAlt = !!(mouse.modifiers & Qt.AltModifier)
        }
        onRightClicked: workspace.selectedNodeId = root.nodeId
        menuItems: [
            { label: qsTr("Duplicate"), iconName: "copy", kbd: "Ctrl+D",
              action: function() {
                  const id = workspace.workingTheme.duplicateNode(root.nodeId)
                  if (id) { workspace.selectedNodeId = id; workspace.saveToHistory() }
              } },
            { label: qsTr("Delete"), iconName: "trash", kbd: "Del", destructive: true,
              action: function() {
                  workspace.workingTheme.removeNode(root.nodeId)
                  if (workspace.selectedNodeId === root.nodeId) workspace.selectedNodeId = ""
                  workspace.saveToHistory()
              } },
            { separator: true },
            { label: qsTr("Bring to front"), iconName: "chevrons-up",
              action: function() {
                  workspace.workingTheme.reorderZ(root.nodeId, 999)
                  workspace.saveToHistory()
              } },
            { label: qsTr("Send to back"),   iconName: "chevrons-down",
              action: function() {
                  workspace.workingTheme.reorderZ(root.nodeId, -999)
                  workspace.saveToHistory()
              } },
            { label: qsTr("Bring forward"),  iconName: "chevron-up",
              action: function() {
                  workspace.workingTheme.reorderZ(root.nodeId, 1)
                  workspace.saveToHistory()
              } },
            { label: qsTr("Send backward"),  iconName: "chevron-down",
              action: function() {
                  workspace.workingTheme.reorderZ(root.nodeId, -1)
                  workspace.saveToHistory()
              } },
            { separator: true },
            { label: root._locked ? qsTr("Unlock") : qsTr("Lock"),
              iconName: root._locked ? "unlock" : "lock",
              action: function() {
                  workspace.workingTheme.setNodeData(root.nodeId, "locked", !root._locked)
                  workspace.saveToHistory()
              } },
            { label: root._hidden ? qsTr("Show") : qsTr("Hide"),
              iconName: root._hidden ? "eye" : "eye-off",
              action: function() {
                  workspace.workingTheme.setNodeData(root.nodeId, "hidden", !root._hidden)
                  workspace.saveToHistory()
              } }
        ]
    }

    // Drag / select
    //
    // Coordinate-frame note: m.x / m.y from a MouseArea are reported in the
    // MouseArea's LOCAL frame. This MouseArea fills the NodeDelegate, which
    // is itself positioned by binding x/y to `_style.x|y * stageW|H / 100`.
    // The instant a drag update writes back to setNodeStyle, the NodeDelegate
    // moves — and so does the MouseArea — which means the next event's m.x
    // is reported in a *different* local frame. Using local m.x directly
    // produces a self-cancelling delta and a visibly lagging drag.
    //
    // The fix: project the press point and every move point into the STAGE
    // frame via mapToItem(root.parent, ...). The stage doesn't move during
    // a drag, so the start point and the running point share a stable basis
    // and the delta is the true cursor displacement.
    MouseArea {
        id: dragMa
        anchors.fill: parent
        enabled: !root._hidden
        acceptedButtons: Qt.LeftButton
        cursorShape: root._locked ? Qt.ForbiddenCursor : Qt.SizeAllCursor
        property bool _dragging: false
        property bool _moved:    false   // a real drag happened this press
        property real _startStageX: 0
        property real _startStageY: 0
        property real _startNodeX:  0
        property real _startNodeY:  0

        onPressed: function(m) {
            workspace.selectedNodeId = root.nodeId
            // Claim focus back from any text input so editor shortcuts
            // re-enable (see EditorCanvas — MouseAreas don't take focus).
            root.forceActiveFocus()
            if (root._locked) return
            const p = mapToItem(root.parent, m.x, m.y)
            _startStageX = p.x
            _startStageY = p.y
            _startNodeX  = (root._style.x || 0)
            _startNodeY  = (root._style.y || 0)
            _dragging    = true
            _moved       = false
            // No saveToHistory here — a press that only SELECTS the node
            // (no drag) must not create an undo step. The snapshot is
            // taken on release, and only if the node actually moved.
        }
        onPositionChanged: function(m) {
            if (!_dragging || !pressed) return
            const p = mapToItem(root.parent, m.x, m.y)
            const dx = p.x - _startStageX
            const dy = p.y - _startStageY
            // Ignore sub-threshold jitter so a click that selects doesn't
            // nudge the node by a fraction of a percent. Once a real drag
            // is recognised (_moved) we keep applying without re-checking.
            if (!_moved && Math.abs(dx) < 3 && Math.abs(dy) < 3) return
            _moved = true
            const dxPct = dx / root.stageW * 100
            const dyPct = dy / root.stageH * 100
            // Allow nodes off-canvas — design-tool standard for off-screen
            // staging (reveals, lower-third slide-ins). Bounded at ±200%
            // so a node can't be lost forever; clicking its layer always
            // re-selects it.
            const nx = Math.max(-200, Math.min(200, _startNodeX + dxPct))
            const ny = Math.max(-200, Math.min(200, _startNodeY + dyPct))
            workspace.workingTheme.setNodeStyle(root.nodeId, "x", Math.round(nx * 10) / 10)
            workspace.workingTheme.setNodeStyle(root.nodeId, "y", Math.round(ny * 10) / 10)
        }
        onReleased: {
            // Snapshot the post-drag state once — only when a real drag
            // occurred. Pure selection clicks fall through with no entry.
            if (_dragging && _moved) workspace.saveToHistory()
            _dragging = false
            _moved    = false
        }
    }

    // Rotate + skew handles. Declared BEFORE the 8 resize handles so the
    // resize handles end up later in child order and therefore win hover
    // and press at the node edge. Both decorative handles size their
    // MouseArea with `anchors.margins: -4` for a fat click target, and
    // both anchor 4 px off the node (`bottomMargin: 4` / `rightMargin: 4`).
    // The negative margin and the gap exactly cancel, so each MouseArea
    // reaches right up to the node edge — the T resize handle's MouseArea
    // (centered on `parentNode.top`) is half-covered by RotateHandle's,
    // and L is half-covered by SkewHandle's. With this ordering the
    // resize MouseAreas sit on top of those overlap zones and the user
    // gets resize cursors / resize drags on the visible resize dots.
    // The rotate/skew grips and connecting sticks live ~20 px from the
    // node edge — well outside the overlap zone — so they still receive
    // events on their own visible targets.
    //
    // Instantiated through a Repeater (model 0/1) rather than a Loader:
    // Repeater reparents its delegate to the Repeater's OWN parent (this
    // NodeDelegate), so the handle's `anchors.* = parentNode.*` resolve
    // correctly. A Loader keeps its loaded item parented to the Loader
    // itself — anchoring to the grandparent NodeDelegate silently fails
    // and the handle collapses to (0,0). Same pattern the 8 ResizeHandles
    // below use.
    Repeater {
        model: root._selected ? 1 : 0
        delegate: RotateHandle { parentNode: root }
    }
    Repeater {
        model: root._selected ? 1 : 0
        delegate: SkewHandle { parentNode: root }
    }

    // 8 resize handles. Declared AFTER rotate/skew so the resize handles
    // sit on top at the node edges — see the rotate/skew comment above.
    // Drawn only when selected; the locked check disables interaction
    // within each handle individually so the affordance stays visible on
    // locked nodes (operator sees it's selected).
    Repeater {
        model: root._selected ? 8 : 0
        delegate: ResizeHandle {
            handleIndex: index
            parentNode: root
        }
    }
}
