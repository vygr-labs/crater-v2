import QtQuick
import Crater

// Header row at the top of ThemeEditorWorkspace. Shows the kind, a saved/
// unsaved indicator, and a primary Save action on the right.
Rectangle {
    id: root
    property var workspace            // ThemeEditorWorkspace instance
    color: Theme.color.elevated

    Rectangle {
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 1
        color: Theme.color.borderSubtle
    }

    // Left: close + title
    Row {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Theme.space.lg
        spacing: Theme.space.md

        IconButton {
            iconName: "x"
            iconSize: 16
            anchors.verticalCenter: parent.verticalCenter
            onClicked: workspace.requestClose()
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: qsTr("Theme Editor")
            color: Theme.color.textPrimary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.titleSize
            font.weight: Theme.font.weightSemiBold
        }

        Rectangle {
            width: kindLabel.implicitWidth + Theme.space.md
            height: 22
            radius: 3
            color: Theme.color.brandSubtle
            border.color: Theme.color.brand
            border.width: 1
            anchors.verticalCenter: parent.verticalCenter

            Text {
                id: kindLabel
                anchors.centerIn: parent
                text: (workspace.themeKind || "").toUpperCase()
                color: Theme.color.brand
                font.family: Theme.font.monoFamily
                font.pixelSize: 10
                font.weight: Theme.font.weightSemiBold
                font.letterSpacing: 1
            }
        }
    }

    // Right: unsaved indicator + save button
    Row {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.rightMargin: Theme.space.lg
        spacing: Theme.space.md

        Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.space.xs
            visible: workspace.hasUnsavedChanges
            AppIcon { name: "alert-triangle"; color: Theme.color.warning; size: 12
                anchors.verticalCenter: parent.verticalCenter }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("Unsaved")
                color: Theme.color.warning
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                font.weight: Theme.font.weightMedium
            }
        }

        PrimaryButton {
            text: qsTr("Save Theme")
            enabled: workspace.themeName.length > 0
                  && !workspace._isBuiltin
            anchors.verticalCenter: parent.verticalCenter
            onClicked: workspace.saveTheme()
        }
    }
}
