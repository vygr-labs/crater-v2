import QtQuick
import Crater

// One node's chrome on the canvas: selection outline, resize / rotate /
// skew handles, and drag-and-select. The node itself is painted underneath
// by the canvas's ThemedNodeGraph, and this Item sits on the rect the graph
// laid it out at, so the outline wraps what the author actually sees.
//
// Nodes the layout places (see ThemedNodeGraph.layoutRoleOf) can't be
// edited like a free box, because some of their geometry is computed:
//   member : slot and size come from its card. No resize handles, and
//            dragging it moves the card.
//   group  : height hugs the members. Width handles only.
//   hug    : height follows content. Width handles only.
//   stack  : top follows another node. Width handles only.
// Where the top is computed (stack, or a hug wrapping another node), a drag
// moves the node sideways only. Plain nodes keep all 8 handles and a free
// drag, resolving to the same percent math as before.
//
// Reactivity: instead of binding directly to workspace.workingTheme.nodes
// (which would force the whole Repeater to rebuild on every style change),
// each delegate keeps a local `node` property that re-fetches from the C++
// WorkingTheme on its granular nodeStyleChanged / nodeDataChanged signals.
// That way only the affected delegate's bindings re-evaluate during drag.
Item {
    id: root
    property var    workspace
    property var    graph: null   // the canvas's ThemedNodeGraph
    property string nodeId
    property real   stageW: 0
    property real   stageH: 0

    // Local node copy — refreshed by Connections below.
    property var node: workspace.workingTheme.node(nodeId)

    readonly property bool   _selected: workspace.selectedNodeId === nodeId
    readonly property bool   _hidden:   !!(node && node.data && node.data.hidden)
    readonly property bool   _locked:   !!(node && node.data && node.data.locked)
    readonly property var    _style:    node && node.style ? node.style : ({})

    // ── Layout role ─────────────────────────────────────────────────────
    readonly property string _role: graph ? graph.layoutRoleOf(nodeId) : ""
    readonly property var    _laid: _role !== "" ? graph.layoutRectOf(nodeId) : null
    readonly property var _handleIndices:
        _role === "member" ? []
      : _role !== ""       ? [3, 7]   // right + left: width only
                           : [0, 1, 2, 3, 4, 5, 6, 7]

    // Authored box in stage px. Where the node sits unless the layout moved it.
    readonly property real _authX: stageW * ((_style.x      || 0) / 100)
    readonly property real _authY: stageH * ((_style.y      || 0) / 100)
    readonly property real _authW: stageW * ((_style.width  || 0) / 100)
    readonly property real _authH: stageH * ((_style.height || 0) / 100)

    x:        _laid ? _laid.x      : _authX
    y:        _laid ? _laid.y      : _authY
    width:    _laid ? _laid.width  : _authW
    height:   _laid ? _laid.height : _authH
    z:        _style.z || 0
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

    // The authored box of a card or hugged node, faint, while selected. It
    // is what the layout anchors against (a card pins to its bottom edge),
    // so the author can see why the card sits where it does.
    Rectangle {
        visible: root._selected && (root._role === "group" || root._role === "hug")
        x: root._authX - root.x
        y: root._authY - root.y
        width:  root._authW
        height: root._authH
        color: "transparent"
        border.color: Theme.color.brand
        border.width: 1
        opacity: 0.4
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
        // What the drag moves: the node, or its card for a card member.
        property string _dragId: ""
        property bool   _dragY:  true
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
            // What moves, and whether it moves vertically, is the
            // workspace's call (layoutRuleOf), shared with the arrow keys
            // and the align buttons.
            const rule = workspace.layoutRuleOf(root.nodeId)
            if (!rule || rule.locked) return
            const target = workspace.workingTheme.node(rule.target)
            if (!target) return
            _dragId = rule.target
            _dragY  = rule.y
            const ts = target.style || {}
            const p = mapToItem(root.parent, m.x, m.y)
            _startStageX = p.x
            _startStageY = p.y
            _startNodeX  = (ts.x || 0)
            _startNodeY  = (ts.y || 0)
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
            workspace.workingTheme.setNodeStyle(_dragId, "x", Math.round(nx * 10) / 10)
            if (_dragY)
                workspace.workingTheme.setNodeStyle(_dragId, "y", Math.round(ny * 10) / 10)
        }
        onReleased: {
            // Snapshot the post-drag state once — only when a real drag
            // occurred. Pure selection clicks fall through with no entry.
            if (_dragging && _moved) workspace.saveToHistory()
            _dragging = false
            _moved    = false
        }
    }

    // Resize handles. Rendered only when selected — the locked check
    // disables interaction within each handle individually so we keep the
    // visual affordance even on locked nodes (operator sees it's selected).
    // Laid-out nodes get fewer (see _handleIndices).
    Repeater {
        model: root._selected ? root._handleIndices : []
        delegate: ResizeHandle {
            handleIndex: modelData
            parentNode: root
        }
    }

    // Rotate + skew handles. Instantiated through a Repeater (model 0/1)
    // rather than a Loader: Repeater reparents its delegate to the
    // Repeater's OWN parent (this NodeDelegate), so the handle's
    // `anchors.* = parentNode.*` resolve correctly. A Loader keeps its
    // loaded item parented to the Loader itself — anchoring to the
    // grandparent NodeDelegate silently fails and the handle collapses
    // to (0,0). Same pattern the 8 ResizeHandles above use.
    Repeater {
        model: root._selected ? 1 : 0
        delegate: RotateHandle { parentNode: root }
    }
    Repeater {
        model: root._selected ? 1 : 0
        delegate: SkewHandle { parentNode: root }
    }
}
