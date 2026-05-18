import QtQuick

// Hover-tinted button without a border.
// Used in TopBar for "Schedule" and "Import" — labels that double as
// dropdown triggers and modal openers.
Rectangle {
    id: root

    property string iconName: ""
    property color  iconColor: Theme.color.textSecondary
    property string text: ""
    property bool   hasChevron: false
    property bool   active: false

    signal clicked()

    implicitHeight: 34
    implicitWidth: contentRow.implicitWidth + Theme.space.lg * 2

    // Squared — see PrimaryButton.qml. The "Pill" in this component's name
    // is legacy from the earlier rounded design; we kept it to avoid a
    // rename across every TopBar call site.
    radius: 0
    color: root.active      ? Theme.color.overlay
         : ma.containsMouse ? Theme.color.overlay
                             : "transparent"

    Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

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
        AppIcon {
            visible: root.hasChevron
            anchors.verticalCenter: parent.verticalCenter
            name: "chevron-down"
            color: Theme.color.textTertiary
            size: Theme.icon.sm
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
