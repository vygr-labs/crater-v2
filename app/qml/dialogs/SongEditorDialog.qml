import QtQuick

// Song editor — placeholder shell. The real editor (lyrics with sectioning,
// CCLI metadata, theme picker, transposition) lands when SongService does.
ModalShell {
    id: root

    dialogWidth: 960
    dialogHeight: 640
    title: AppState.modalProps.songIndex !== undefined
         ? qsTr("Edit Song")
         : qsTr("New Song")

    Item {
        anchors.fill: parent

        EmptyState {
            anchors.fill: parent
            iconName: "edit"
            title: qsTr("Song editor coming soon")
            body: qsTr("Lyrics editor with section markers, CCLI metadata, transposition, and theme overrides will land alongside the SongService implementation.")
        }

        // Footer
        Rectangle {
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: 56
            color: "transparent"

            Rectangle {
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                height: 1
                color: Theme.color.borderSubtle
            }

            Row {
                anchors.right: parent.right
                anchors.rightMargin: Theme.space.lg
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.space.sm

                GhostButton {
                    text: qsTr("Cancel")
                    onClicked: AppState.closeModal()
                }
                PrimaryButton {
                    variant: "brand"
                    text: qsTr("Save")
                    enabled: false   // disabled until editor is real
                    onClicked: AppState.closeModal()
                }
            }
        }
    }
}
