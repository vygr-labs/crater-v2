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
    property real   iconSize: Theme.icon.xl
    property real   maxBodyWidth: 320

    // Buttons or links that belong under the text (e.g. "Add Your First
    // Song"). They flow in the same column, so a body that wraps onto more
    // lines pushes them down instead of running underneath them.
    default property alias actions: actionSlot.data
    // Hide the actions without removing them (e.g. "Clear search" only
    // when there is a query).
    property bool showActions: true

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

        Item {
            id: actionSlot
            visible: root.showActions && children.length > 0
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: Theme.space.md
            implicitWidth:  childrenRect.width
            implicitHeight: childrenRect.height
        }
    }
}
