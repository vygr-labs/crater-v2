import QtQuick
import Crater

// Vertical list of nodes in the working theme. Top-of-list maps to top-of-z
// (rendered above everything else) so design-tool conventions hold. Each
// row hovers to reveal action icons (visibility / lock / duplicate / delete).
Rectangle {
    id: root
    property var workspace
    color: Theme.color.elevated

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
        height: 44
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right

        Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Theme.space.lg
            text: qsTr("LAYERS")
            color: Theme.color.textPrimary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.smallSize
            font.weight: Theme.font.weightSemiBold
            font.letterSpacing: 1.2
        }
        Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.rightMargin: Theme.space.lg
            text: workspace.workingTheme.nodes.length + ""
            color: Theme.color.textSecondary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.smallSize
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
                    size: Theme.icon.md
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
                IconButton { iconName: row._hidden ? "eye-off" : "eye"; iconSize: Theme.icon.sm
                    onClicked: {
                        workspace.workingTheme.setNodeData(modelData.id, "hidden", !row._hidden)
                        workspace.saveToHistory()
                    } }
                IconButton { iconName: row._locked ? "lock" : "unlock"; iconSize: Theme.icon.sm
                    onClicked: {
                        workspace.workingTheme.setNodeData(modelData.id, "locked", !row._locked)
                        workspace.saveToHistory()
                    } }
                IconButton { iconName: "copy"; iconSize: Theme.icon.sm
                    onClicked: {
                        const id = workspace.workingTheme.duplicateNode(modelData.id)
                        if (id) { workspace.selectedNodeId = id; workspace.saveToHistory() }
                    } }
                IconButton { iconName: "trash"; iconSize: Theme.icon.sm
                    onClicked: {
                        workspace.workingTheme.removeNode(modelData.id)
                        if (workspace.selectedNodeId === modelData.id)
                            workspace.selectedNodeId = ""
                        workspace.saveToHistory()
                    } }
            }

            RightClickArea {
                id: rowMa
                anchors.fill: parent
                // Don't intercept clicks on the action buttons (which sit above us in z).
                preventStealing: false

                function _select() { workspace.selectedNodeId = modelData.id }
                onLeftClicked:  _select()
                onRightClicked: _select()

                menuItems: [
                    { label: qsTr("Rename layer"), iconName: "edit-3",
                      action: function() {
                          AppState.openModal("naming", {
                              title:       qsTr("Rename layer"),
                              placeholder: qsTr("Layer name"),
                              confirmText: qsTr("Save"),
                              initialValue: (modelData.data && modelData.data.layerName) || "",
                              onConfirm:   function(name) {
                                  if (name && name.length > 0) {
                                      workspace.workingTheme.renameNode(modelData.id, name)
                                      workspace.saveToHistory()
                                  }
                              }
                          })
                      } },
                    { separator: true },
                    { label: row._hidden ? qsTr("Show") : qsTr("Hide"),
                      iconName: row._hidden ? "eye" : "eye-off",
                      action: function() {
                          workspace.workingTheme.setNodeData(modelData.id, "hidden", !row._hidden)
                          workspace.saveToHistory()
                      } },
                    { label: row._locked ? qsTr("Unlock") : qsTr("Lock"),
                      iconName: row._locked ? "unlock" : "lock",
                      action: function() {
                          workspace.workingTheme.setNodeData(modelData.id, "locked", !row._locked)
                          workspace.saveToHistory()
                      } },
                    { separator: true },
                    { label: qsTr("Bring to front"), iconName: "chevrons-up",
                      action: function() {
                          workspace.workingTheme.reorderZ(modelData.id, 999)
                          workspace.saveToHistory()
                      } },
                    { label: qsTr("Send to back"),   iconName: "chevrons-down",
                      action: function() {
                          workspace.workingTheme.reorderZ(modelData.id, -999)
                          workspace.saveToHistory()
                      } },
                    { separator: true },
                    { label: qsTr("Duplicate"), iconName: "copy",
                      action: function() {
                          const id = workspace.workingTheme.duplicateNode(modelData.id)
                          if (id) { workspace.selectedNodeId = id; workspace.saveToHistory() }
                      } },
                    { label: qsTr("Delete"), iconName: "trash", destructive: true,
                      action: function() {
                          workspace.workingTheme.removeNode(modelData.id)
                          if (workspace.selectedNodeId === modelData.id)
                              workspace.selectedNodeId = ""
                          workspace.saveToHistory()
                      } }
                ]
            }
        }
    }
}
