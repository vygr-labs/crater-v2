import QtQuick
import Crater

// Footer: theme name input + Cancel / Save buttons. Mirrors the Save button
// in the header but in the affordance position users expect on a form
// (bottom-right). The name is the only field that can be edited directly
// from the footer; everything else flows through the properties panel.
Rectangle {
    id: root
    property var workspace
    color: Theme.color.elevated

    Rectangle {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 1
        color: Theme.color.borderSubtle
    }

    Row {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Theme.space.lg
        spacing: Theme.space.md

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: qsTr("Name")
            color: Theme.color.textSecondary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.smallSize
            font.weight: Theme.font.weightMedium
        }

        Rectangle {
            width: 280
            height: 30
            radius: Theme.radius.md
            color: Theme.color.canvas
            border.color: nameInput.activeFocus ? Theme.color.brand : Theme.color.borderStrong
            border.width: 1
            anchors.verticalCenter: parent.verticalCenter

            TextInput {
                id: nameInput
                anchors.fill: parent
                anchors.leftMargin: Theme.space.md
                anchors.rightMargin: Theme.space.md
                verticalAlignment: TextInput.AlignVCenter
                text: workspace.themeName
                color: Theme.color.textPrimary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize
                selectByMouse: true
                onTextChanged: if (text !== workspace.themeName) workspace.themeName = text
                onActiveFocusChanged: workspace.inputFocused = activeFocus
            }
        }

        Text {
            visible: workspace._isBuiltin
            anchors.verticalCenter: parent.verticalCenter
            text: qsTr("Built-in themes can't be edited — duplicate to customize")
            color: Theme.color.warning
            font.family: Theme.font.family
            font.pixelSize: Theme.font.smallSize
        }
    }

    Row {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.rightMargin: Theme.space.lg
        spacing: Theme.space.sm

        GhostButton {
            text: qsTr("Cancel")
            anchors.verticalCenter: parent.verticalCenter
            onClicked: workspace.requestClose()
        }
        PrimaryButton {
            text: qsTr("Save Theme")
            enabled: workspace.themeName.length > 0 && !workspace._isBuiltin
            anchors.verticalCenter: parent.verticalCenter
            onClicked: workspace.saveTheme()
        }
    }
}
