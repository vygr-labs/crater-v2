import QtQuick

// Window-level popup menu. Two open modes:
//   - openAt(x, y):           absolute position (right-click context menus)
//   - openBelow(item, dy):    anchored under an Item (TopBar dropdowns, gear menus)
//
// The popover renders as a backdrop + body inside whatever parent it's placed
// in — typically the root ApplicationWindow's content item or ModalLayer. The
// backdrop catches outside clicks to close.
//
// Model items: array of { label, iconName?, destructive?, separator?, action? }
// where action is an optional JS function called on selection.
Item {
    id: root

    property var   model: []
    property real  menuWidth: 240
    property bool  active: false
    property real  anchorX: 0
    property real  anchorY: 0

    signal itemActivated(int index, var itemData)

    function openAt(x, y) {
        anchorX = x
        anchorY = y
        active = true
    }

    function openBelow(item, dy) {
        if (!item) return
        const p = item.mapToItem(root, 0, item.height + (dy || 4))
        openAt(p.x, p.y)
    }

    function close() { active = false }

    visible: active
    z: 500
    anchors.fill: parent

    // Backdrop — catches clicks anywhere outside the menu body.
    MouseArea {
        anchors.fill: parent
        onPressed: function(mouse) {
            // Close unless click landed in the popup body (the body
            // sits above this MouseArea via Z-order, but its own
            // MouseArea blocks propagation).
            root.close()
            mouse.accepted = true
        }
    }

    // Menu body
    Rectangle {
        id: body
        // Clamp inside window so the menu never gets clipped off-screen.
        x: Math.max(8, Math.min(root.anchorX, root.width - width - 8))
        y: Math.max(8, Math.min(root.anchorY, root.height - height - 8))
        width: root.menuWidth
        height: contents.implicitHeight + Theme.space.sm * 2
        color: Theme.color.raised
        border.color: Theme.color.borderStrong
        border.width: 1
        radius: Theme.radius.md

        // Subtle shadow approximation via a slightly darker rectangle behind
        Rectangle {
            anchors.fill: parent
            anchors.margins: -1
            anchors.topMargin: 1
            radius: parent.radius + 1
            color: "#00000040"
            z: -1
        }

        // Block backdrop click-through inside the body
        MouseArea { anchors.fill: parent; acceptedButtons: Qt.NoButton }

        Column {
            id: contents
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Theme.space.sm
            spacing: 2

            Repeater {
                model: root.model
                delegate: Item {
                    width: contents.width
                    height: (modelData.separator === true) ? (1 + Theme.space.xs * 2) : 32

                    // Separator
                    Rectangle {
                        visible: modelData.separator === true
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        height: 1
                        color: Theme.color.borderSubtle
                    }

                    // Normal item
                    Rectangle {
                        visible: !(modelData.separator === true)
                        anchors.fill: parent
                        radius: Theme.radius.sm
                        color: itemMa.containsMouse ? Theme.color.overlay : "transparent"

                        Row {
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.space.md
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.space.md

                            AppIcon {
                                visible: !!modelData.iconName
                                anchors.verticalCenter: parent.verticalCenter
                                name: modelData.iconName || ""
                                color: modelData.destructive ? Theme.color.live : Theme.color.textSecondary
                                size: 13
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.label || ""
                                color: modelData.destructive ? Theme.color.live : Theme.color.textPrimary
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.bodySize
                            }
                        }

                        Text {
                            visible: !!modelData.detail
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.space.md
                            anchors.verticalCenter: parent.verticalCenter
                            text: modelData.detail || ""
                            color: Theme.color.textTertiary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.smallSize
                        }

                        MouseArea {
                            id: itemMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.itemActivated(index, modelData)
                                if (typeof modelData.action === "function") modelData.action()
                                root.close()
                            }
                        }
                    }
                }
            }
        }
    }
}
