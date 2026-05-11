import QtQuick

// Row used in the bottom-left library sidebar (groups, collections, Bible versions, etc.).
// Two icon paths: pass `iconName` for a Lucide glyph (preferred) or `symbol` for
// a literal character. iconName takes precedence.
Item {
    id: root

    property string iconName: ""
    property string symbol: ""
    property string label: ""
    property int    count: 0
    property bool   active: false

    signal clicked()

    implicitHeight: 32
    implicitWidth: 220

    Rectangle {
        anchors.fill: parent
        anchors.leftMargin: Theme.space.sm
        anchors.rightMargin: Theme.space.sm
        radius: Theme.radius.md
        color: root.active        ? Theme.color.brandSubtle
             : ma.containsMouse   ? Theme.color.overlay
                                  : "transparent"

        Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
    }

    Row {
        anchors.left: parent.left
        anchors.leftMargin: Theme.space.lg
        anchors.right: countLabel.visible ? countLabel.left : parent.right
        anchors.rightMargin: Theme.space.sm
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.space.md

        AppIcon {
            visible: root.iconName.length > 0
            anchors.verticalCenter: parent.verticalCenter
            name: root.iconName
            color: root.active ? Theme.color.brand : Theme.color.textTertiary
            size: 13
        }
        Text {
            visible: root.iconName.length === 0 && root.symbol.length > 0
            anchors.verticalCenter: parent.verticalCenter
            text: root.symbol
            color: root.active ? Theme.color.brand : Theme.color.textTertiary
            font.family: Theme.font.family
            font.pixelSize: 13
            width: 16
            horizontalAlignment: Text.AlignHCenter
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.label
            color: root.active ? Theme.color.textPrimary : Theme.color.textSecondary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.bodySize
            font.weight: root.active ? Theme.font.weightMedium : Theme.font.weightRegular

            Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
        }
    }

    Text {
        id: countLabel
        visible: root.count > 0
        anchors.right: parent.right
        anchors.rightMargin: Theme.space.lg
        anchors.verticalCenter: parent.verticalCenter
        text: root.count.toLocaleString(Qt.locale(), "f", 0)
        color: Theme.color.textTertiary
        font.family: Theme.font.monoFamily
        font.pixelSize: Theme.font.smallSize
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }
}
