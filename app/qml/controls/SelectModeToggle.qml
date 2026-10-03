import QtQuick
import QtQuick.Controls.Basic

// The Select toggle in a library tab's top bar. On, the tab's rows show
// checkboxes and a plain click ticks a row (see LibrarySelection). Off
// drops the ticks. Drawn like IconButton, with a brand wash while on.
Item {
    id: root

    // The tab's LibrarySelection.
    property var target: null
    readonly property bool on: !!target && target.selectMode

    implicitWidth: Theme.d(30)
    implicitHeight: Theme.d(30)

    ToolTip.visible: ma.containsMouse
    ToolTip.text: root.on ? qsTr("Stop selecting") : qsTr("Select items")
    ToolTip.delay: 400

    Rectangle {
        anchors.fill: parent
        radius: 0
        color: root.on ? Theme.color.brandSubtle
             : ma.containsMouse ? Theme.color.overlay : "transparent"
        border.color: root.on ? Theme.color.brand : "transparent"
        border.width: 1
        Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
    }

    AppIcon {
        anchors.centerIn: parent
        name: "list-checks"
        size: Theme.icon.sm
        color: root.on ? Theme.color.brand
             : ma.containsMouse ? Theme.color.textPrimary : Theme.color.textSecondary
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: if (root.target) root.target.setSelectMode(!root.on)
    }
}
