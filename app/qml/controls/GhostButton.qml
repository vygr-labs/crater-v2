import QtQuick

// Bordered text button — ghost style.
// Used in TopBar for "Logo" and "Clear" affordances.
Rectangle {
    id: root

    property string iconName: ""
    property color  iconColor: Theme.color.textSecondary
    property string text: ""
    property bool   active: false       // toggled state — different visual

    // `enabled` is inherited from Item — Item.enabled = false disables the
    // MouseArea via propagation; we use it for visual styling below.

    signal clicked()

    implicitHeight: 34
    implicitWidth: contentRow.implicitWidth + Theme.space.lg * 2

    radius: Theme.radius.md
    color: !root.enabled    ? "transparent"
         : root.active      ? Theme.color.brandSubtle
         : ma.containsMouse ? Theme.color.overlay
                             : "transparent"
    border.color: root.active ? Theme.color.brand : Theme.color.borderStrong
    border.width: 1
    opacity: root.enabled ? 1.0 : 0.5

    Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
    Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }

    Row {
        id: contentRow
        anchors.centerIn: parent
        spacing: Theme.space.sm

        AppIcon {
            visible: root.iconName.length > 0
            anchors.verticalCenter: parent.verticalCenter
            name: root.iconName
            color: root.iconColor
            size: Theme.icon.md
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.text
            color: Theme.color.textPrimary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.bodySize
            font.weight: Theme.font.weightMedium
        }
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: root.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: root.clicked()
    }
}
