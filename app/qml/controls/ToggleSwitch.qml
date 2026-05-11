import QtQuick

// iOS-style toggle. Used in settings, but generic enough to use anywhere
// a boolean is being collected without checkboxes.
Item {
    id: root

    property bool value: false
    signal toggled()

    implicitWidth: 40
    implicitHeight: 24

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: root.value ? Theme.color.brand : Theme.color.overlay
        border.color: root.value ? Theme.color.brand : Theme.color.borderStrong
        border.width: 1

        Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
        Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }
    }

    Rectangle {
        width: parent.height - 6
        height: width
        radius: width / 2
        y: 3
        x: root.value ? parent.width - width - 3 : 3
        color: "#ffffff"

        Behavior on x { NumberAnimation { duration: Theme.motion.instant; easing.type: Easing.OutQuad } }
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggled()
    }
}
