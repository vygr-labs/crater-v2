import QtQuick

Item {
    id: root

    property string symbol: ""
    property color tint: Theme.color.textSecondary
    property color tintHover: Theme.color.textPrimary
    property real symbolSize: 14

    signal clicked()

    implicitWidth: 32
    implicitHeight: 32

    Rectangle {
        anchors.fill: parent
        radius: Theme.radius.md
        color: ma.containsMouse ? Theme.color.overlay : "transparent"

        Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
    }

    Text {
        anchors.centerIn: parent
        text: root.symbol
        color: ma.containsMouse ? root.tintHover : root.tint
        font.family: Theme.font.family
        font.pixelSize: root.symbolSize

        Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }
}
