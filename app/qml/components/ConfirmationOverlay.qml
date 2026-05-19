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
        id: card
        anchors.centerIn: parent
        width: 440
        height: bodyCol.implicitHeight + Theme.space.xl * 2
        // Squared per brand language — see PrimaryButton.qml for the app-wide
        // rationale. Filled `elevated` surface with `borderStrong` so the
        // card carries the same chrome as PopoverMenu / ScheduleDropdown.
        radius: 0
        color: Theme.color.elevated
        border.color: Theme.color.borderStrong
        border.width: 1
        MouseArea { anchors.fill: parent; onClicked: { /* swallow */ } }

        // Layered drop shadow — mirrors PopoverMenu so all floating surfaces
        // share one shadow language without pulling in QtQuick.Effects.
        Rectangle {
            anchors.fill: parent
            anchors.margins: -12
            anchors.topMargin: -6
            anchors.bottomMargin: -18
            radius: 0
            color: "#00000018"
            z: -3
        }
        Rectangle {
            anchors.fill: parent
            anchors.margins: -6
            anchors.topMargin: -3
            anchors.bottomMargin: -10
            radius: 0
            color: "#00000028"
            z: -2
        }
        Rectangle {
            anchors.fill: parent
            anchors.margins: -1
            anchors.topMargin: 1
            radius: 0
            color: "#00000048"
            z: -1
        }

        Column {
            id: bodyCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.leftMargin:  Theme.space.xl
            anchors.rightMargin: Theme.space.xl
            anchors.topMargin:   Theme.space.xl
            spacing: Theme.space.sm

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

            Item { width: parent.width; height: Theme.space.lg }

            Row {
                anchors.right: parent.right
                spacing: Theme.space.sm
                GhostButton {
                    text: root.cancelLabel
                    onClicked: { root.cancelled(); root.close() }
                }
                // Destructive variant — semantically correct for "discard /
                // delete / remove" actions, and brand-aligned via the
                // `live` crimson palette (dual-use: broadcast on-air state
                // + destructive UI, see Theme.qml color docs).
                PrimaryButton {
                    variant: "destructive"
                    text: root.confirmLabel
                    onClicked: { root.confirmed(); root.close() }
                }
            }
        }
    }
}
