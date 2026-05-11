import QtQuick

// Themes tab — visual presets for projection text rendering.
// Backed by ThemeService.allThemes (QList<Theme> value-types); each tile
// previews the theme's background color + text-color sample.
//
// Tokens shape (see app/V001__init.sql):
//   { background: {color, image?}, text: {color, fontFamily, fontPixelSize,
//     fontWeight, lineHeightMultiplier, letterSpacing},
//     layout: {padding, horizontalAlignment, verticalAlignment},
//     transition: {kind, durationMs, easing} }
Item {
    id: root

    function bgColor(tokens) {
        if (tokens && tokens.background && tokens.background.color) return tokens.background.color
        return "#222"
    }
    function fgColor(tokens) {
        if (tokens && tokens.text && tokens.text.color) return tokens.text.color
        return "#f1f1f5"
    }

    EmptyState {
        anchors.fill: parent
        visible: ThemeService.allThemes.length === 0
        iconName: "palette"
        title: qsTr("No themes yet")
        body: qsTr("Create a custom theme or pick from the presets")
    }

    GridView {
        id: grid
        anchors.fill: parent
        anchors.margins: Theme.space.lg
        visible: ThemeService.allThemes.length > 0
        model: ThemeService.allThemes
        cellWidth: 220
        cellHeight: 148
        clip: true
        cacheBuffer: 400

        delegate: Item {
            width: grid.cellWidth - 10
            height: grid.cellHeight - 10

            // Resolve tokens once per delegate so we don't repeatedly walk the QVariantMap.
            readonly property color _bg: root.bgColor(modelData.tokens)
            readonly property color _fg: root.fgColor(modelData.tokens)

            Rectangle {
                id: tile
                anchors.fill: parent
                radius: Theme.radius.lg
                color: parent._bg
                border.color: themeMa.containsMouse ? Theme.color.brand : Theme.color.borderStrong
                border.width: 2

                Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }

                // Faux verse preview overlaid on the theme's background.
                Text {
                    anchors.centerIn: parent
                    width: parent.width * 0.8
                    text: qsTr("For God so loved\nthe world…")
                    color: parent.parent._fg
                    font.family: Theme.font.family
                    font.pixelSize: 14
                    font.weight: Theme.font.weightMedium
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                }

                // Theme name + kind in the corner — uses a translucent black backdrop
                // so it stays readable on both light and dark theme backgrounds.
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
                        text: modelData.name + " · " + (modelData.kind || "")
                        color: parent.parent.parent._fg
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                        font.weight: Theme.font.weightSemiBold
                    }
                }

                // "Built-in" indicator chip — top right.
                Rectangle {
                    visible: modelData.isBuiltin === true
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 8
                    width: builtinLabel.implicitWidth + Theme.space.sm * 2
                    height: 16
                    radius: 2
                    color: "#000000A0"

                    Text {
                        id: builtinLabel
                        anchors.centerIn: parent
                        text: qsTr("PRESET")
                        color: "#dddddd"
                        font.family: Theme.font.monoFamily
                        font.pixelSize: 9
                        font.weight: Theme.font.weightSemiBold
                        font.letterSpacing: 0.8
                    }
                }

                MouseArea {
                    id: themeMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onDoubleClicked: AppState.openModal("themeEditor", { themeId: modelData.id })
                }
            }
        }
    }
}
