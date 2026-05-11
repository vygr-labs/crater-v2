import QtQuick

// Media tab — gradient-thumbnail grid as a stand-in for the real media
// library. Real thumbnails will replace the gradients when MediaService
// generates them on import.
Item {
    id: root

    EmptyState {
        anchors.fill: parent
        visible: AppState.mediaList.count === 0
        iconName: "film"
        title: qsTr("No media yet")
        body: qsTr("Import images or videos from the toolbar above")
    }

    GridView {
        id: grid
        anchors.fill: parent
        anchors.margins: Theme.space.lg
        visible: AppState.mediaList.count > 0
        model: AppState.mediaList
        cellWidth: 168
        cellHeight: 110
        clip: true
        cacheBuffer: 600

        // Procedural gradient colors per tile — gives the demo grid
        // visual variety without shipping placeholder image assets.
        readonly property var gradientPairs: [
            ["#3a1f6b", "#0e0822"],   // purple → black
            ["#1b4d3e", "#0a1f17"],   // teal → black
            ["#6b3a1f", "#220e08"],   // amber → black
            ["#1f3a6b", "#080e22"],   // blue → black
            ["#6b1f4d", "#220817"],   // magenta → black
            ["#4d6b1f", "#170822"]    // olive → black
        ]

        delegate: Item {
            width: grid.cellWidth - 8
            height: grid.cellHeight - 8

            Rectangle {
                anchors.fill: parent
                radius: Theme.radius.md
                border.color: tileMa.containsMouse ? Theme.color.brand : Theme.color.borderStrong
                border.width: 1

                Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 1
                    radius: parent.radius - 1
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: grid.gradientPairs[index % 6][0] }
                        GradientStop { position: 1.0; color: grid.gradientPairs[index % 6][1] }
                    }
                }

                // Type chip (image / video)
                Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.margins: Theme.space.sm
                    width: typeChipLabel.implicitWidth + Theme.space.sm * 2
                    height: 18
                    radius: 2
                    color: "#00000080"

                    Text {
                        id: typeChipLabel
                        anchors.centerIn: parent
                        text: (model.type || "image").toUpperCase()
                        color: "#ffffff"
                        font.family: Theme.font.family
                        font.pixelSize: 9
                        font.weight: Theme.font.weightSemiBold
                        font.letterSpacing: 0.8
                    }
                }

                Text {
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: Theme.space.sm
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: model.name
                    color: "#ffffff"
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                }

                MouseArea {
                    id: tileMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onDoubleClicked: {
                        AppState.addScheduleItem({
                            title:     model.name,
                            subtitle:  (model.type || "image").toUpperCase(),
                            typeName:  model.type === "video" ? "VIDEO" : "MEDIA",
                            typeColor: model.type === "video" ? Theme.color.typeVideo : Theme.color.typeMedia,
                            data:      [{ content: model.name }]
                        })
                    }
                }
            }
        }
    }
}
