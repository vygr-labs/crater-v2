import QtQuick

// Compact "name your X" dialog. Bound to modalProps:
//   title:        string shown in the title bar
//   placeholder:  placeholder text inside the input
//   confirmText:  label on the confirm button (default "Create")
//   initialValue: optional pre-filled text; selected on open so a single
//                 keystroke replaces it (rename-style UX)
//   onConfirm:    JS function called with the entered name on confirm
ModalShell {
    id: root

    dialogWidth: 440
    dialogHeight: 200
    title: AppState.modalProps.title || qsTr("Name")

    Item {
        anchors.fill: parent
        anchors.margins: Theme.space.lg

        // Input
        Rectangle {
            id: inputWrap
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: 40
            radius: 0
            color: Theme.color.canvas
            border.color: input.activeFocus ? Theme.color.brand : Theme.color.borderStrong
            border.width: 1

            Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }

            TextInput {
                id: input
                anchors.fill: parent
                anchors.leftMargin: Theme.space.md
                anchors.rightMargin: Theme.space.md
                verticalAlignment: TextInput.AlignVCenter
                color: Theme.color.textPrimary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize
                selectByMouse: true
                focus: true
                onAccepted: confirm()

                // Pre-populate for rename-style invocations, then grab active
                // focus. `focus: true` alone is not enough: it only requests
                // focus within this dialog's scope, but the theme editor's
                // canvas calls forceActiveFocus() on itself, so without
                // actively taking focus here the dialog opens with a visible
                // caret/selection while keystrokes still fire the editor's
                // window-level shortcuts (and `inputFocused` reads false).
                // Deferred a tick so it runs after the modal Loader is fully
                // realized; selectAll() AFTER focusing so the seed stays
                // highlighted for single-keystroke replace (OS-native rename UX).
                Component.onCompleted: {
                    const seed = AppState.modalProps.initialValue
                    if (typeof seed === "string" && seed.length > 0)
                        text = seed
                    Qt.callLater(() => {
                        input.forceActiveFocus()
                        if (input.text.length > 0) input.selectAll()
                    })
                }

                Text {
                    visible: input.text.length === 0
                    anchors.verticalCenter: parent.verticalCenter
                    text: AppState.modalProps.placeholder || qsTr("Enter a name")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize
                }
            }
        }

        // Footer with Cancel + Confirm
        Row {
            anchors.bottom: parent.bottom
            anchors.right: parent.right
            spacing: Theme.space.sm

            GhostButton {
                text: qsTr("Cancel")
                onClicked: AppState.closeModal()
            }

            PrimaryButton {
                variant: "brand"
                text: AppState.modalProps.confirmText || qsTr("Create")
                enabled: input.text.trim().length > 0
                onClicked: confirm()
            }
        }
    }

    function confirm() {
        const trimmed = input.text.trim()
        if (trimmed.length === 0) return
        const cb = AppState.modalProps.onConfirm
        if (typeof cb === "function") cb(trimmed)
        AppState.closeModal()
    }
}
