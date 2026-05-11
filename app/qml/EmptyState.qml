import QtQuick
import QtQuick.Layouts

// Centered empty-state pattern: icon over title over body.
// Used wherever a panel has no content to show yet.
Item {
    id: root

    property string symbol: ""
    property string title: ""
    property string body: ""
    property color  symbolColor: Theme.color.textTertiary
    property real   symbolSize: 28
    property real   maxBodyWidth: 280

    ColumnLayout {
        anchors.centerIn: parent
        spacing: Theme.space.sm
        width: Math.min(root.width - Theme.space.xl * 2, root.maxBodyWidth)

        Text {
            visible: root.symbol.length > 0
            Layout.alignment: Qt.AlignHCenter
            Layout.bottomMargin: Theme.space.xs
            text: root.symbol
            color: root.symbolColor
            font.family: Theme.font.family
            font.pixelSize: root.symbolSize
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
