import QtQuick
import QtQuick.Controls.Basic

// Square hover-highlight button with a Lucide icon.
// Usage: IconButton { iconName: "settings"; iconSize: Theme.icon.md }
Item {
    id: root

    property string iconName: ""
    property color  tint: Theme.color.textSecondary
    property color  tintHover: Theme.color.textPrimary
    property real   iconSize: Theme.icon.md
    // Optional hover hint. Empty (the default) shows nothing, so existing
    // icon buttons are unchanged. 400 ms delay, same as ElidedText.
    property string tooltip: ""

    ToolTip.visible: tooltip.length > 0 && ma.containsMouse
    ToolTip.text:    tooltip
    ToolTip.delay:   400

    // `enabled` is inherited from Item — setting it false on the caller side
    // propagates to all descendants (including the MouseArea below), so we
    // don't redeclare it here.

    signal clicked()

    implicitWidth: Theme.d(30)
    implicitHeight: Theme.d(30)

    opacity: enabled ? 1.0 : 0.4

    Rectangle {
        anchors.fill: parent
        // Squared hover background — matches the other button atoms.
        radius: 0
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
        cursorShape: root.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: root.clicked()
    }
}
