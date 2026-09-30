import QtQuick
import Crater

// Action toolbar — Add | Undo/Redo | Duplicate/Delete | Align | Z-order | Zoom.
// All actions affect workspace state via the WorkingTheme model.
Rectangle {
    id: root
    property var workspace
    color: Theme.color.elevated

    Rectangle {
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 1
        color: Theme.color.borderSubtle
    }

    readonly property bool _hasSel: workspace.selectedNodeId !== ""

    function _setSel(id) { workspace.selectedNodeId = id || "" }
    function _addNode(kind) {
        const id = workspace.workingTheme.addNode(kind)
        if (id) { _setSel(id); workspace.saveToHistory() }
    }
    // Aligns what the author sees: the box the layout drew (a card hugs
    // its text, so its style height isn't what is on screen), moved by
    // shifting the layer's style by the difference. A card member aligns
    // its card. Vertical align does nothing where the layout decides the
    // top (workspace.layoutRuleOf).
    function _align(target, axis) {
        const id = workspace.selectedNodeId
        if (!id) return
        const rule = workspace.layoutRuleOf(id)
        if (!rule || rule.locked || (axis === "y" && !rule.y)) return
        const n = workspace.workingTheme.node(rule.target); if (!n) return
        const box  = workspace.shownBoxOf(rule.target)
        const pos  = axis === "x" ? box.x : box.y
        const size = axis === "x" ? box.width : box.height
        const want = (target === "left" || target === "top")      ? 0
                   : (target === "right" || target === "bottom")  ? (100 - size)
                                                                  : (100 - size) / 2
        const cur = (n.style && n.style[axis]) || 0
        const v = Math.max(-200, Math.min(200, cur + (want - pos)))
        workspace.workingTheme.setNodeStyle(rule.target, axis, Math.round(v * 10) / 10)
        workspace.saveToHistory()
    }
    function _alignH(target) { _align(target, "x") }
    function _alignV(target) { _align(target, "y") }

    Row {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Theme.space.lg
        spacing: Theme.space.sm

        // Add
        GhostButton { text: qsTr("Text");      iconName: "type";   onClicked: root._addNode("text") }
        GhostButton { text: qsTr("Container"); iconName: "square"; onClicked: root._addNode("container") }

        Rectangle { width: 1; height: 24; color: Theme.color.borderSubtle; anchors.verticalCenter: parent.verticalCenter }

        // Undo / Redo
        IconButton { iconName: "undo"; enabled: workspace.historyIndex > 0
            anchors.verticalCenter: parent.verticalCenter
            onClicked: workspace.undo() }
        IconButton { iconName: "redo"; enabled: workspace.historyIndex < workspace.historyStack.length - 1
            anchors.verticalCenter: parent.verticalCenter
            onClicked: workspace.redo() }

        Rectangle { width: 1; height: 24; color: Theme.color.borderSubtle; anchors.verticalCenter: parent.verticalCenter }

        // Duplicate / Delete
        IconButton { iconName: "copy"; enabled: root._hasSel
            anchors.verticalCenter: parent.verticalCenter
            onClicked: {
                const id = workspace.workingTheme.duplicateNode(workspace.selectedNodeId)
                if (id) { workspace.selectedNodeId = id; workspace.saveToHistory() }
            } }
        IconButton { iconName: "trash"; enabled: root._hasSel
            anchors.verticalCenter: parent.verticalCenter
            onClicked: {
                workspace.workingTheme.removeNode(workspace.selectedNodeId)
                workspace.selectedNodeId = ""
                workspace.saveToHistory()
            } }

        Rectangle { width: 1; height: 24; color: Theme.color.borderSubtle; anchors.verticalCenter: parent.verticalCenter }

        // Horizontal align
        IconButton { iconName: "align-left";   enabled: root._hasSel
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root._alignH("left") }
        IconButton { iconName: "align-center"; enabled: root._hasSel
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root._alignH("center") }
        IconButton { iconName: "align-right";  enabled: root._hasSel
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root._alignH("right") }

        // Vertical align
        IconButton { iconName: "align-start-horizontal";   enabled: root._hasSel
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root._alignV("top") }
        IconButton { iconName: "align-center-horizontal";  enabled: root._hasSel
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root._alignV("center") }
        IconButton { iconName: "align-end-horizontal";     enabled: root._hasSel
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root._alignV("bottom") }

        Rectangle { width: 1; height: 24; color: Theme.color.borderSubtle; anchors.verticalCenter: parent.verticalCenter }

        // Z-order
        IconButton { iconName: "bring-to-front"; enabled: root._hasSel
            anchors.verticalCenter: parent.verticalCenter
            onClicked: {
                workspace.workingTheme.reorderZ(workspace.selectedNodeId, 999)
                workspace.saveToHistory()
            } }
        IconButton { iconName: "send-to-back";   enabled: root._hasSel
            anchors.verticalCenter: parent.verticalCenter
            onClicked: {
                workspace.workingTheme.reorderZ(workspace.selectedNodeId, -999)
                workspace.saveToHistory()
            } }
    }

    // Zoom (right side)
    Row {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.rightMargin: Theme.space.lg
        spacing: Theme.space.xs

        IconButton { iconName: "zoom-out"
            anchors.verticalCenter: parent.verticalCenter
            onClicked: workspace.zoom = Math.max(0.1, Math.round((workspace.zoom - 0.1) * 10) / 10) }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            width: 40
            horizontalAlignment: Text.AlignHCenter
            text: Math.round(workspace.zoom * 100) + "%"
            color: Theme.color.textSecondary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.smallSize
        }
        IconButton { iconName: "zoom-in"
            anchors.verticalCenter: parent.verticalCenter
            onClicked: workspace.zoom = Math.min(4.0, Math.round((workspace.zoom + 0.1) * 10) / 10) }
        IconButton { iconName: "maximize-2"
            anchors.verticalCenter: parent.verticalCenter
            onClicked: workspace.zoom = 1.0 }
    }
}
