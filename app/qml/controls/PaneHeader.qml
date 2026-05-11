import QtQuick

// Section header row — eyebrow label on the left + optional action on the right.
// Used inside settings sections and similar grouped UIs.
Item {
    id: root

    property string label: ""
    property string action: ""
    signal actionClicked()

    implicitHeight: 36
    implicitWidth: 200

    Text {
        anchors.left: parent.left
        anchors.leftMargin: Theme.space.lg
        anchors.verticalCenter: parent.verticalCenter
        text: root.label.toUpperCase()
        color: Theme.color.textTertiary
        font.family: Theme.font.family
        font.pixelSize: Theme.font.microSize
        font.weight: Theme.font.weightSemiBold
        font.letterSpacing: 1.2
    }

    Text {
        id: actionText
        visible: root.action.length > 0
        anchors.right: parent.right
        anchors.rightMargin: Theme.space.lg
        anchors.verticalCenter: parent.verticalCenter
        text: root.action
        color: actionMa.containsMouse ? Theme.color.brand : Theme.color.textSecondary
        font.family: Theme.font.family
        font.pixelSize: Theme.font.smallSize
        font.weight: Theme.font.weightMedium

        Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

        MouseArea {
            id: actionMa
            anchors.fill: parent
            anchors.margins: -6
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.actionClicked()
        }
    }
}
