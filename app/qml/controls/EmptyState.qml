import QtQuick
import QtQuick.Layouts

// Centered empty-state pattern: icon over title over body.
// Used wherever a panel has no content to show yet.
//
// Accepts EITHER a Lucide icon (iconName) or a literal glyph (symbol).
// iconName takes precedence — it renders an AppIcon. Falls back to
// the legacy `symbol` text path for cases where there's no Lucide
// equivalent (the old EmptyState used arbitrary unicode glyphs).
Item {
    id: root

    property string iconName: ""              // Lucide name, e.g. "music"
    property string symbol: ""                // legacy literal glyph
    property string title: ""
    property string body: ""
    property color  iconColor: Theme.color.textTertiary
    property real   iconSize: 32
    property real   maxBodyWidth: 320

    ColumnLayout {
        anchors.centerIn: parent
        spacing: Theme.space.sm
        width: Math.min(root.width - Theme.space.xl * 2, root.maxBodyWidth)

        AppIcon {
            visible: root.iconName.length > 0
            Layout.alignment: Qt.AlignHCenter
            Layout.bottomMargin: Theme.space.xs
            name: root.iconName
            color: root.iconColor
            size: root.iconSize
            opacity: 0.7
        }

        Text {
            visible: root.iconName.length === 0 && root.symbol.length > 0
            Layout.alignment: Qt.AlignHCenter
            Layout.bottomMargin: Theme.space.xs
            text: root.symbol
            color: root.iconColor
            font.family: Theme.font.family
            font.pixelSize: root.iconSize
            opacity: 0.7
        }

        Text {
            visible: root.title.length > 0
            Layout.alignment: Qt.AlignHCenter
            text: root.title
            color: Theme.color.textSecondary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.bodySize + 2
            font.weight: Theme.font.weightMedium
            horizontalAlignment: Text.AlignHCenter
        }

        Text {
            visible: root.body.length > 0
            Layout.alignment: Qt.AlignHCenter
            Layout.fillWidth: true
            text: root.body
            color: Theme.color.textTertiary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.smallSize
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            lineHeight: 1.4
        }
    }
}
