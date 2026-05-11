import QtQuick

// Settings-style "select" trigger — current value text + chevron, clicking
// opens a popover with the options. For UI-flow this just shows the chip;
// the actual dropdown is a future wire-up.
Rectangle {
    id: root

    property string label: ""
    property var    options: []    // array of { id, label }; for future popup
    signal clicked()

    implicitWidth: chipRow.implicitWidth + Theme.space.lg * 2
    implicitHeight: 30
    radius: Theme.radius.md
    color: ma.containsMouse ? Theme.color.overlay : Theme.color.canvas
    border.color: Theme.color.borderStrong
    border.width: 1

    Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

    Row {
        id: chipRow
        anchors.centerIn: parent
        spacing: Theme.space.sm

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.label
            color: Theme.color.textPrimary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.smallSize
            font.weight: Theme.font.weightMedium
        }
        AppIcon {
            anchors.verticalCenter: parent.verticalCenter
            name: "chevron-down"
            color: Theme.color.textTertiary
            size: 11
        }
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }
}
