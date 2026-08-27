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
            iconSize: Theme.icon.lg
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
            radius: 0
            color: Theme.color.brandSubtle
            border.color: Theme.color.brand
            border.width: 1
            anchors.verticalCenter: parent.verticalCenter

            Text {
                id: kindLabel
                anchors.centerIn: parent
                text: (workspace.themeKind || "").toUpperCase()
                color: Theme.color.brand
                font.family: Theme.font.family
                font.pixelSize: Theme.font.microSize
                font.weight: Theme.font.weightSemiBold
                font.letterSpacing: 1.2
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
            AppIcon { name: "alert-triangle"; color: Theme.color.warning; size: Theme.icon.sm
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

        // Enabled on built-ins too. Save is not, but copying the prompt is
        // still useful there, and loading a reply gives a look at it on the
        // canvas exactly the way dragging a built-in's nodes already does.
        GhostButton {
            text: qsTr("Design with AI")
            iconName: "sparkles"
            anchors.verticalCenter: parent.verticalCenter
            onClicked: workspace.openAiDesign()
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
