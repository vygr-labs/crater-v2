import QtQuick

// Destructive-action confirmation dialog. Bound to modalProps:
//   title:       string in title bar
//   body:        explanation text
//   confirmText: label on the destructive button (default "Confirm")
//   onConfirm:   JS function called when confirmed
ModalShell {
    id: root

    dialogWidth: 440
    dialogHeight: 220
    title: AppState.modalProps.title || qsTr("Confirm")

    Item {
        anchors.fill: parent
        anchors.margins: Theme.space.lg

        Text {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            text: AppState.modalProps.body || ""
            color: Theme.color.textSecondary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.bodySize
            wrapMode: Text.WordWrap
            lineHeight: 1.4
        }

        Row {
            anchors.bottom: parent.bottom
            anchors.right: parent.right
            spacing: Theme.space.sm

            GhostButton {
                text: qsTr("Cancel")
                onClicked: AppState.closeModal()
            }

            PrimaryButton {
                variant: "destructive"
                text: AppState.modalProps.confirmText || qsTr("Confirm")
                onClicked: {
                    const cb = AppState.modalProps.onConfirm
                    if (typeof cb === "function") cb()
                    AppState.closeModal()
                }
            }
        }
    }
}
