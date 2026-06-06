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

        // ── Drag-to-reorder ─────────────────────────────────────────────
        // Commit-on-drop: the dragged row lifts to follow the cursor (a pure
        // transform, so nothing reflows) and an insertion line shows the
        // target slot; on release we reassign z once via reorderNodes. The
        // model is a derived z-sorted array, so live shuffling would fight the
        // binding — this avoids that. Flicking is off while dragging so the
        // list can't scroll out from under the pointer.
        readonly property int rowStride: 36 + spacing
        property string dragId: ""
        property int    dragFrom: -1
        property int    dragTo:   -1
        property real   dragCursorY: 0          // cursor Y in contentItem coords
        interactive: dragId === ""

        function dragBegin(fromIndex) {
            dragFrom = fromIndex
            dragTo   = fromIndex
            dragId   = model[fromIndex].id
        }
        function dragMove(contentY) {
            dragCursorY = contentY
            dragTo = Math.max(0, Math.min(count - 1, Math.floor(contentY / rowStride)))
        }
        function dragEnd() {
            if (dragId !== "" && dragTo >= 0 && dragTo !== dragFrom) {
                const ids = []
                for (let k = 0; k < model.length; ++k) ids.push(model[k].id)
                ids.splice(dragFrom, 1)
                ids.splice(dragTo, 0, dragId)
                workspace.workingTheme.reorderNodes(ids)
                workspace.selectedNodeId = dragId
                workspace.saveToHistory()
            }
            dragId = ""; dragFrom = -1; dragTo = -1
        }

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
            readonly property bool _dragging: list.dragId === modelData.id

            color: _selected         ? Theme.color.brandSubtle
                 : rowHover.hovered  ? Theme.color.overlay
                                     : "transparent"
            opacity: _hidden ? 0.5 : (_dragging ? 0.9 : 1.0)

            // Whole-row hover that survives the action buttons grabbing the
            // pointer. A plain MouseArea (rowMa) loses containsMouse the moment
            // the cursor enters a child button stacked on top of it; a
            // HoverHandler keeps reporting hovered for the entire row, so the
            // action buttons stay visible while you reach for them.
            HoverHandler { id: rowHover }

            // Lift the dragged row to follow the cursor. Transform only, so
            // the row keeps its layout slot and neighbours don't reflow — the
            // insertion line (below) shows where it will land. Raised z so the
            // lifted row floats above the others.
            z: _dragging ? 5 : 0
            transform: Translate {
                y: row._dragging
                   ? (list.dragCursorY - index * list.rowStride - row.height / 2)
                   : 0
            }

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

            // Hover-revealed actions. z:1 lifts this above rowMa so the buttons
            // actually receive clicks — rowMa is declared later and would
            // otherwise sit on top and swallow them (the bug that made every
            // action button dead, only selecting the row). Visibility keys off
            // the row-wide HoverHandler so the buttons don't vanish the instant
            // the cursor reaches them.
            Row {
                z: 1
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.rightMargin: Theme.space.sm
                spacing: 0
                visible: rowHover.hovered || row._selected || row._hidden || row._locked
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
                // Keep the press through a vertical drag so the row reorders
                // instead of the ListView stealing it for a flick.
                preventStealing: true
                cursorShape: _moved ? Qt.ClosedHandCursor : Qt.PointingHandCursor

                property real _pressY: 0
                property bool _moved: false          // crossed the drag threshold
                property bool _suppressClick: false  // a finished drag also emits clicked

                function _select() { workspace.selectedNodeId = modelData.id }

                onPressed: function(mouse) { _pressY = mouse.y; _moved = false }
                onPositionChanged: function(mouse) {
                    if (!pressed) return
                    if (!_moved && Math.abs(mouse.y - _pressY) < 6) return
                    if (!_moved) { _moved = true; list.dragBegin(index) }
                    list.dragMove(mapToItem(list.contentItem, mouse.x, mouse.y).y)
                }
                onReleased: function(mouse) {
                    if (_moved) { list.dragEnd(); _moved = false; _suppressClick = true }
                }

                onLeftClicked: function(mouse) {
                    if (_suppressClick) { _suppressClick = false; return }
                    _select()
                }
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

    // Drop indicator — a brand-coloured insertion line marking the slot the
    // dragged row will land in. Positioned in panel coords: the list's offset
    // plus the target slot's top (minus any scroll). Above the list so it's
    // always visible during a drag.
    Rectangle {
        visible: list.dragId !== "" && list.dragTo >= 0
        x: list.x
        width: list.width - 1
        height: 2
        color: Theme.color.brand
        y: list.y + (list.dragTo * list.rowStride - list.contentY)
        z: 100
    }
}
