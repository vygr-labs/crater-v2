import QtQuick

// Square hover-highlight button with a Lucide icon.
// Usage: IconButton { iconName: "settings"; iconSize: 14 }
Item {
    id: root

    property string iconName: ""
    property color  tint: Theme.color.textSecondary
    property color  tintHover: Theme.color.textPrimary
    property real   iconSize: 14

    signal clicked()

    implicitWidth: 30
    implicitHeight: 30

    Rectangle {
        anchors.fill: parent
        radius: Theme.radius.md
        color: ma.containsMouse ? Theme.color.overlay : "transparent"

        Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
    }

    AppIcon {
        anchors.centerIn: parent
        name: root.iconName
        color: ma.containsMouse ? root.tintHover : root.tint
        size: root.iconSize

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
