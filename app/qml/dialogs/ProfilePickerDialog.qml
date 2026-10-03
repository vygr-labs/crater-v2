import QtQuick
import Crater

// Startup profile picker (ARCHITECTURE.md §12). Main.qml opens it once the
// console is up when ProfileService.shouldPromptAtStartup is true: the
// operator asked to be asked and more than one profile exists.
//
// The console behind it has already opened the last-used profile, so
// choosing that one just closes this. Choosing another restarts straight
// into it. Nothing is live this early, so there is no confirm step.
ModalShell {
    id: root

    dialogWidth: 460
    dialogHeight: Math.min(560, 196 + ProfileService.profiles.length * 56)
    title: qsTr("Choose a profile")
    showCloseButton: true

    function _choose(id) {
        if (id === ProfileService.currentProfileId) {
            AppState.closeModal()
            return
        }
        ProfileService.switchTo(id)
    }

    Item {
        anchors.fill: parent
        anchors.margins: Theme.space.lg

        Flickable {
            id: listFlick
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: footer.top
            anchors.bottomMargin: Theme.space.md
            clip: true
            contentHeight: listCol.implicitHeight
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: listCol
                width: listFlick.width
                spacing: 2

                Repeater {
                    model: ProfileService.profiles
                    delegate: Rectangle {
                        required property var modelData
                        width: listCol.width
                        height: 52
                        color: pickMa.containsMouse ? Theme.color.overlay : "transparent"
                        border.color: modelData.isCurrent ? Theme.color.brand : "transparent"
                        border.width: 1

                        AppIcon {
                            id: pickIcon
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.space.md
                            anchors.verticalCenter: parent.verticalCenter
                            name: "user"
                            color: modelData.isCurrent ? Theme.color.brand : Theme.color.textSecondary
                            size: Theme.icon.md
                        }
                        Column {
                            anchors.left: pickIcon.right
                            anchors.leftMargin: Theme.space.md
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.space.md
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2
                            Text {
                                width: parent.width
                                elide: Text.ElideRight
                                text: modelData.name
                                color: Theme.color.textPrimary
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.bodySize
                                font.weight: Theme.font.weightMedium
                            }
                            Text {
                                width: parent.width
                                elide: Text.ElideRight
                                text: modelData.isCurrent
                                          ? qsTr("Open now")
                                          : (modelData.lastUsedAt > 0
                                                 ? qsTr("Last used %1").arg(Qt.formatDateTime(new Date(modelData.lastUsedAt), "d MMM yyyy"))
                                                 : qsTr("Not used yet"))
                                color: Theme.color.textTertiary
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.smallSize
                            }
                        }
                        MouseArea {
                            id: pickMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root._choose(modelData.id)
                        }
                    }
                }
            }
        }

        Item {
            id: footer
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 40

            CheckRow {
                anchors.left: parent.left
                anchors.right: continueButton.left
                anchors.rightMargin: Theme.space.md
                anchors.verticalCenter: parent.verticalCenter
                label: qsTr("Ask every time Crater opens")
                checked: ProfileService.askAtStartup
                onToggled: ProfileService.askAtStartup = !ProfileService.askAtStartup
            }
            PrimaryButton {
                id: continueButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                variant: "brand"
                text: qsTr("Continue with %1").arg(ProfileService.currentProfileName)
                onClicked: AppState.closeModal()
            }
        }
    }
}
