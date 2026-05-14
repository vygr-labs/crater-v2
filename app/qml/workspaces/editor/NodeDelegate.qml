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
        AppIcon { anchors.centerIn: parent; name: "lock"; size: 10; color: "#ffffff" }
    }

    // Right-click context menu — sits above the left-button drag MouseArea
    // and accepts only the right button so it never competes with drag. The
    // drag/select MouseArea below stays unchanged.
    RightClickArea {
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        enabled: !root._hidden
        z: 1
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
    MouseArea {
        id: dragMa
        anchors.fill: parent
        enabled: !root._hidden
        acceptedButtons: Qt.LeftButton
        cursorShape: root._locked ? Qt.ForbiddenCursor : Qt.SizeAllCursor
        // dragging-state guards: lock the move plane to the canvas
        property bool _dragging: false
        property real _startMouseX: 0
        property real _startMouseY: 0
        property real _startNodeX:  0
        property real _startNodeY:  0

        onPressed: function(m) {
            workspace.selectedNodeId = root.nodeId
            if (root._locked) return
            _startMouseX = m.x
            _startMouseY = m.y
            _startNodeX  = (root._style.x || 0)
            _startNodeY  = (root._style.y || 0)
            _dragging    = true
            workspace.saveToHistory()
        }
        onPositionChanged: function(m) {
            if (!_dragging || !pressed) return
            const dxPct = (m.x - _startMouseX) / root.stageW * 100
            const dyPct = (m.y - _startMouseY) / root.stageH * 100
            const nx = Math.max(0, Math.min(100, _startNodeX + dxPct))
            const ny = Math.max(0, Math.min(100, _startNodeY + dyPct))
            workspace.workingTheme.setNodeStyle(root.nodeId, "x", Math.round(nx * 10) / 10)
            workspace.workingTheme.setNodeStyle(root.nodeId, "y", Math.round(ny * 10) / 10)
        }
        onReleased: _dragging = false
    }

    // 8 resize handles. Rendered only when selected — the locked check
    // disables interaction within each handle individually so we keep the
    // visual affordance even on locked nodes (operator sees it's selected).
    Repeater {
        model: root._selected ? 8 : 0
        delegate: ResizeHandle {
            handleIndex: index
            parentNode: root
        }
    }
}
