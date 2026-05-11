import QtQuick
import Crater

// Vertical list of nodes in the working theme. Top-of-list maps to top-of-z
// (rendered above everything else) so design-tool conventions hold. Each
// row hovers to reveal action icons (visibility / lock / duplicate / delete).
Rectangle {
    id: root
    property var workspace
    color: Theme.color.bgSidebar

    // Right hairline border separating from the canvas.
    Rectangle {
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 1
        color: Theme.color.borderSubtle
    }

    Item {
        id: header
        height: 36
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right

        Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Theme.space.lg
            text: qsTr("LAYERS")
            color: Theme.color.textTertiary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.microSize
            font.weight: Theme.font.weightSemiBold
            font.letterSpacing: 1.2
        }
        Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.rightMargin: Theme.space.lg
            text: workspace.workingTheme.nodes.length + ""
            color: Theme.color.textTertiary
            font.family: Theme.font.monoFamily
            font.pixelSize: Theme.font.microSize
        }
    }

    ListView {
        id: list
        anchors.top: header.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.rightMargin: 1
        clip: true
        spacing: 1
        // Top of list = top of z-order. The model is z-sorted descending so
        // the rendering order on the canvas matches what the operator sees.
        model: {
            const arr = workspace.workingTheme.nodes.slice()
            arr.sort((a, b) => ((b.style && b.style.z) || 0) - ((a.style && a.style.z) || 0))
            return arr
        }

        delegate: Rectangle {
            id: row
            width: list.width
            height: 36
            readonly property bool _selected: workspace.selectedNodeId === modelData.id
            readonly property bool _hidden:   !!(modelData.data && modelData.data.hidden)
            readonly property bool _locked:   !!(modelData.data && modelData.data.locked)

            color: _selected             ? Theme.color.brandSubtle
                 : rowMa.containsMouse   ? Theme.color.overlay
                                         : "transparent"
            opacity: _hidden ? 0.5 : 1.0

            Row {
                anchors.fill: parent
                anchors.leftMargin: Theme.space.md
                anchors.rightMargin: Theme.space.sm
                spacing: Theme.space.sm

                AppIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: modelData.kind === "text" ? "type" : "square"
                    color: row._selected ? Theme.color.brand : Theme.color.textSecondary
                    size: 14
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: (modelData.data && modelData.data.layerName)
                        || (modelData.kind === "text" ? qsTr("Text") : qsTr("Container"))
                    color: row._selected ? Theme.color.textPrimary : Theme.color.textSecondary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize
                    elide: Text.ElideRight
                    width: row.width - 90
                }
            }

            // Hover-revealed actions
            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.rightMargin: Theme.space.sm
                spacing: 0
                visible: rowMa.containsMouse || row._selected || row._hidden || row._locked
                IconButton { iconName: row._hidden ? "eye-off" : "eye"; iconSize: 12
                    onClicked: {
                        workspace.workingTheme.setNodeData(modelData.id, "hidden", !row._hidden)
                        workspace.saveToHistory()
                    } }
                IconButton { iconName: row._locked ? "lock" : "unlock"; iconSize: 12
                    onClicked: {
                        workspace.workingTheme.setNodeData(modelData.id, "locked", !row._locked)
                        workspace.saveToHistory()
                    } }
                IconButton { iconName: "copy"; iconSize: 12
                    onClicked: {
                        const id = workspace.workingTheme.duplicateNode(modelData.id)
                        if (id) { workspace.selectedNodeId = id; workspace.saveToHistory() }
                    } }
                IconButton { iconName: "trash"; iconSize: 12
                    onClicked: {
                        workspace.workingTheme.removeNode(modelData.id)
                        if (workspace.selectedNodeId === modelData.id)
                            workspace.selectedNodeId = ""
                        workspace.saveToHistory()
                    } }
            }

            MouseArea {
                id: rowMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: workspace.selectedNodeId = modelData.id
                // Don't intercept clicks on the action buttons (which sit above us in z).
                preventStealing: false
            }
        }
    }
}
