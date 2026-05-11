import QtQuick

// Theme editor — placeholder shell. Real editor (font picker, color tokens,
// padding/alignment, transition preview) ships with ThemeService.
ModalShell {
    id: root

    dialogWidth: 960
    dialogHeight: 640
    title: AppState.modalProps.themeIndex !== undefined
         ? qsTr("Edit Theme")
         : qsTr("New Theme")

    Item {
        anchors.fill: parent

        EmptyState {
            anchors.fill: parent
            iconName: "palette"
            title: qsTr("Theme editor coming soon")
            body: qsTr("Visual editor for font, color tokens, padding, alignment, and transitions will land alongside the ThemeService implementation.")
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
                    enabled: false
                    onClicked: AppState.closeModal()
                }
            }
        }
    }
}
