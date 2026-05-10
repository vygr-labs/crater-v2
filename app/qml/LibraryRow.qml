import QtQuick

Item {
    id: root

    property string label: ""
    property string symbol: ""
    property int    count: 0
    property bool   active: false

    signal clicked()

    implicitHeight: 34
    implicitWidth: 200

    Rectangle {
        anchors.fill: parent
        anchors.leftMargin: Theme.space.sm
        anchors.rightMargin: Theme.space.sm
        radius: Theme.radius.md
        color: root.active        ? Theme.color.brandSubtle
             : ma.containsMouse   ? Theme.color.overlay
                                  : "transparent"

        Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
    }

    // Active accent bar
    Rectangle {
        visible: root.active
        anchors.left: parent.left
        anchors.leftMargin: Theme.space.sm
        anchors.verticalCenter: parent.verticalCenter
        width: 2
        height: 16
        radius: 1
        color: Theme.color.brand
    }

    Row {
        anchors.left: parent.left
        anchors.leftMargin: Theme.space.lg
        anchors.right: countLabel.left
        anchors.rightMargin: Theme.space.sm
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.space.md

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.symbol
            color: root.active ? Theme.color.brand : Theme.color.textTertiary
            font.family: Theme.font.family
            font.pixelSize: 13
            width: 16
            horizontalAlignment: Text.AlignHCenter

            Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.label
            color: root.active ? Theme.color.textPrimary : Theme.color.textSecondary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.bodySize
            font.weight: root.active ? Theme.font.weightMedium : Theme.font.weightRegular

            Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
        }
    }

    Text {
        id: countLabel
        anchors.right: parent.right
        anchors.rightMargin: Theme.space.lg
        anchors.verticalCenter: parent.verticalCenter
        text: root.count > 0 ? root.count.toLocaleString(Qt.locale(), "f", 0) : ""
        color: Theme.color.textTertiary
        font.family: Theme.font.monoFamily
        font.pixelSize: Theme.font.smallSize
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }
}
