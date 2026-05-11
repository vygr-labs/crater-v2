import QtQuick

// Themes tab — visual presets for projection text rendering.
// Each tile previews the theme's background + accent palette plus a
// sample of overlaid text.
Item {
    id: root

    EmptyState {
        anchors.fill: parent
        visible: AppState.themesList.count === 0
        iconName: "palette"
        title: qsTr("No themes yet")
        body: qsTr("Create a custom theme or pick from the presets")
    }

    GridView {
        id: grid
        anchors.fill: parent
        anchors.margins: Theme.space.lg
        visible: AppState.themesList.count > 0
        model: AppState.themesList
        cellWidth: 220
        cellHeight: 148
        clip: true
        cacheBuffer: 400

        delegate: Item {
            width: grid.cellWidth - 10
            height: grid.cellHeight - 10

            Rectangle {
                id: tile
                anchors.fill: parent
                radius: Theme.radius.lg
                color: model.background
                border.color: themeMa.containsMouse ? model.accent : Theme.color.borderStrong
                border.width: 2

                Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }

                // Faux verse preview overlaid on the theme's background.
                Text {
                    anchors.centerIn: parent
                    width: parent.width * 0.8
                    text: qsTr("For God so loved\nthe world…")
                    color: model.background === "#f5f5f0" ? "#1a1a1f" : "#f1f1f5"
                    font.family: Theme.font.family
                    font.pixelSize: 14
                    font.weight: Theme.font.weightMedium
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                }

                // Theme name in corner
                Rectangle {
                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                    anchors.margins: 8
                    width: nameLabel.implicitWidth + Theme.space.md * 2
                    height: 22
                    radius: 3
                    color: "#000000A0"

                    Text {
                        id: nameLabel
                        anchors.centerIn: parent
                        text: model.name
                        color: model.accent
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                        font.weight: Theme.font.weightSemiBold
                    }
                }

                MouseArea {
                    id: themeMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onDoubleClicked: AppState.openModal("themeEditor", { themeIndex: index })
                }
            }
        }
    }
}
