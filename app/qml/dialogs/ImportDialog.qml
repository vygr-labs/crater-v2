import QtQuick
import QtQuick.Layouts

// Import dialog — placeholder. Real file picker + parsing comes later.
// For now this just demonstrates the flow + the visual chrome.
ModalShell {
    id: root

    dialogWidth: 520
    dialogHeight: 360
    title: qsTr("Import")

    property string selectedType: "songs"

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.space.lg
        spacing: Theme.space.lg

        Text {
            Layout.fillWidth: true
            text: qsTr("Choose what you'd like to import:")
            color: Theme.color.textSecondary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.bodySize
        }

        Column {
            Layout.fillWidth: true
            spacing: Theme.space.xs

            Repeater {
                model: [
                    { id: "songs",     label: qsTr("Songs"),     iconName: "music",     hint: ".txt, .pro, .opensong" },
                    { id: "bible",     label: qsTr("Bible"),     iconName: "book-open", hint: ".osis, .usfm" },
                    { id: "themes",    label: qsTr("Themes"),    iconName: "palette",   hint: ".crater-theme" },
                    { id: "media",     label: qsTr("Media"),     iconName: "film",      hint: ".jpg, .mp4, .webm" }
                ]

                delegate: Rectangle {
                    width: parent.width
                    height: 48
                    radius: Theme.radius.md
                    color: root.selectedType === modelData.id ? Theme.color.brandSubtle
                         : optMa.containsMouse                ? Theme.color.elevated
                                                              : "transparent"
                    border.color: root.selectedType === modelData.id ? Theme.color.brand : Theme.color.borderSubtle
                    border.width: 1

                    Behavior on color        { ColorAnimation { duration: Theme.motion.instant } }
                    Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }

                    Row {
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.space.lg
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.space.md

                        AppIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: modelData.iconName
                            color: root.selectedType === modelData.id ? Theme.color.brand : Theme.color.textSecondary
                            size: 14
                        }
                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2

                            Text {
                                text: modelData.label
                                color: Theme.color.textPrimary
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.bodySize
                                font.weight: Theme.font.weightMedium
                            }
                            Text {
                                text: modelData.hint
                                color: Theme.color.textTertiary
                                font.family: Theme.font.monoFamily
                                font.pixelSize: Theme.font.smallSize
                            }
                        }
                    }

                    MouseArea {
                        id: optMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.selectedType = modelData.id
                    }
                }
            }
        }

        Item { Layout.fillHeight: true }

        Row {
            Layout.alignment: Qt.AlignRight
            spacing: Theme.space.sm

            GhostButton {
                text: qsTr("Cancel")
                onClicked: AppState.closeModal()
            }
            PrimaryButton {
                variant: "brand"
                iconName: "upload"
                text: qsTr("Choose file…")
                onClicked: {
                    console.log("[import] would open file picker for type=" + root.selectedType)
                    AppState.closeModal()
                }
            }
        }
    }
}
