import QtQuick

// Search input with leading icon and optional trailing shortcut hint.
//
// Debouncing convention: the parent observes `text` and debounces filtering
// using its own Timer if needed. The bar itself stays dumb so it composes
// cleanly across tabs that have different debounce policies (e.g., Songs
// uses 150ms, real FTS Bible search will use 250ms later).
Item {
    id: root

    property alias text: input.text
    property string placeholder: ""
    property string shortcutHint: ""

    signal accepted()

    implicitHeight: 36
    implicitWidth: 240

    Rectangle {
        anchors.fill: parent
        radius: Theme.radius.md
        color: Theme.color.canvas
        border.color: input.activeFocus ? Theme.color.brand : Theme.color.borderStrong
        border.width: 1

        Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }

        AppIcon {
            id: leadingIcon
            anchors.left: parent.left
            anchors.leftMargin: Theme.space.md
            anchors.verticalCenter: parent.verticalCenter
            name: "search"
            color: Theme.color.textTertiary
            size: 14
        }

        TextInput {
            id: input
            anchors.left: leadingIcon.right
            anchors.leftMargin: Theme.space.md
            anchors.right: hintChip.visible ? hintChip.left : parent.right
            anchors.rightMargin: Theme.space.sm
            anchors.verticalCenter: parent.verticalCenter
            color: Theme.color.textPrimary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.bodySize
            selectByMouse: true
            clip: true
            onAccepted: root.accepted()

            // Placeholder text (TextInput doesn't have placeholderText built in)
            Text {
                visible: !input.activeFocus && input.text.length === 0
                anchors.verticalCenter: parent.verticalCenter
                text: root.placeholder
                color: Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize
            }
        }

        Rectangle {
            id: hintChip
            anchors.right: parent.right
            anchors.rightMargin: 5
            anchors.verticalCenter: parent.verticalCenter
            visible: root.shortcutHint.length > 0 && !input.activeFocus && input.text.length === 0
            width: 28; height: 18
            radius: 3
            color: Theme.color.elevated
            border.color: Theme.color.borderStrong
            border.width: 1

            Text {
                anchors.centerIn: parent
                text: root.shortcutHint
                color: Theme.color.textTertiary
                font.family: Theme.font.monoFamily
                font.pixelSize: 9
            }
        }
    }
}
