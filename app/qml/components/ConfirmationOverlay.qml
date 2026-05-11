import QtQuick
import Crater

// In-workspace confirmation prompt. Built without QtQuick.Dialogs (project
// rule). Two-button card with backdrop. Caller wires `onConfirmed`.
//
//   ConfirmationOverlay {
//       id: confirm
//       title: "Discard changes?"
//       body:  "Your unsaved edits will be lost."
//       confirmLabel: "Discard"
//       onConfirmed: workspace.close()
//   }
//   ...
//   confirm.openConfirm()
Rectangle {
    id: root
    color: "#000000B0"
    visible: false
    z: 200
    property string title: ""
    property string body: ""
    property string confirmLabel: qsTr("Confirm")
    property string cancelLabel:  qsTr("Cancel")

    signal confirmed()
    signal cancelled()

    function openConfirm() { visible = true }
    function close()       { visible = false }

    MouseArea {
        anchors.fill: parent
        onClicked: root.close()
    }

    Rectangle {
        anchors.centerIn: parent
        width: 380
        height: 180
        radius: Theme.radius.lg
        color: Theme.color.elevated
        border.color: Theme.color.borderStrong
        border.width: 1
        MouseArea { anchors.fill: parent; onClicked: { /* swallow */ } }

        Column {
            anchors.fill: parent
            anchors.margins: Theme.space.lg
            spacing: Theme.space.md

            Text {
                text: root.title
                color: Theme.color.textPrimary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.titleSize
                font.weight: Theme.font.weightSemiBold
                width: parent.width
                wrapMode: Text.WordWrap
            }
            Text {
                text: root.body
                color: Theme.color.textSecondary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize
                width: parent.width
                wrapMode: Text.WordWrap
            }

            Item { width: parent.width; height: Theme.space.md }

            Row {
                anchors.right: parent.right
                spacing: Theme.space.sm
                GhostButton {
                    text: root.cancelLabel
                    onClicked: { root.cancelled(); root.close() }
                }
                PrimaryButton {
                    text: root.confirmLabel
                    onClicked: { root.confirmed(); root.close() }
                }
            }
        }
    }
}
