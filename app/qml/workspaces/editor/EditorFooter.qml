import QtQuick
import Crater

// Footer: theme name input + Cancel / Save buttons. Mirrors the Save button
// in the header but in the affordance position users expect on a form
// (bottom-right). The name is the only field that can be edited directly
// from the footer; everything else flows through the properties panel.
//
// When workspace.saveError is non-empty, an error bar grows above the
// buttons row. The workspace binds its `height` to errorBar.visible so the
// canvas area shrinks instead of the buttons jumping down — users keep
// their motor memory on the Save button location.
Rectangle {
    id: root
    property var workspace
    color: Theme.color.elevated

    readonly property bool _showError: workspace.saveError.length > 0
    readonly property int  _errorBarHeight: 32
    readonly property int  _buttonRowHeight: 56

    Rectangle {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 1
        color: Theme.color.borderSubtle
    }

    // Validation / save-error bar. Mirrors ThemesTab's import-error chip:
    // dismissable, brand-warning palette, full-width inside the footer's
    // gutter. Collapses to 0 when there's no error so the footer reverts
    // cleanly to the buttons-only layout.
    Rectangle {
        id: errorBar
        anchors.top: parent.top
        anchors.topMargin: 1
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Theme.space.lg
        anchors.rightMargin: Theme.space.lg
        visible: root._showError
        height: visible ? root._errorBarHeight - 4 : 0
        radius: Theme.radius.md
        color: Theme.color.liveSubtle
        border.color: Theme.color.live
        border.width: 1

        Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Theme.space.md
            anchors.right: dismissBtn.left
            anchors.rightMargin: Theme.space.sm
            spacing: Theme.space.sm

            AppIcon {
                name: "alert-triangle"
                color: Theme.color.live
                size: Theme.icon.sm
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 24
                text: workspace.saveError
                color: Theme.color.textPrimary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                elide: Text.ElideRight
            }
        }

        IconButton {
            id: dismissBtn
            iconName: "x"
            iconSize: Theme.icon.sm
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.rightMargin: Theme.space.sm
            onClicked: workspace.saveError = ""
        }
    }

    // Buttons row — anchored to the bottom so it stays put when the error
    // bar appears above it.
    Item {
        id: buttonRow
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: root._buttonRowHeight

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
                radius: 0
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
}
