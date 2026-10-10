import QtQuick
import QtQuick.Controls.Basic

// The thin strip left where a hidden console panel was (Main.qml). Clicking
// it brings the panel back. `chevron` points the way the panel will open.
Rectangle {
    id: root

    property string label: ""          // "Show schedule"
    property string chevron: "chevron-right"
    signal clicked()

    color: ma.containsMouse ? Theme.color.overlay : Theme.color.elevated
    Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

    // Hairlines on both long sides, so the rail reads as its own column
    // whichever panels end up beside it.
    Rectangle { anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
                width: 1; color: Theme.color.borderSubtle }
    Rectangle { anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom
                width: 1; color: Theme.color.borderSubtle }

    AppIcon {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: Theme.space.md
        name: root.chevron
        size: Theme.icon.sm
        color: ma.containsMouse ? Theme.color.textPrimary : Theme.color.textSecondary
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }

    ToolTip.visible: ma.containsMouse && root.label.length > 0
    ToolTip.text: root.label
    ToolTip.delay: 400
}
