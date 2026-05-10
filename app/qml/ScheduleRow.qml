import QtQuick

Item {
    id: root

    property int    rowIndex: 0
    property string title: ""
    property string subtitle: ""
    property string typeName: ""
    property color  typeColor: Theme.color.textTertiary
    property bool   isLive: false
    property bool   isQueued: false

    signal clicked()
    signal doubleClicked()

    implicitHeight: Theme.size.scheduleRowHeight
    implicitWidth: 400

    Rectangle {
        id: card

        anchors.fill: parent
        anchors.leftMargin: Theme.space.lg
        anchors.rightMargin: Theme.space.lg
        anchors.topMargin: 3
        anchors.bottomMargin: 3
        radius: Theme.radius.lg
        color: root.isLive       ? Theme.color.liveSubtle
             : root.isQueued     ? Theme.color.previewSubtle
             : ma.containsMouse  ? Theme.color.raised
                                 : Theme.color.elevated
        border.width: (root.isLive || root.isQueued) ? 1 : 0
        border.color: root.isLive   ? Theme.color.live
                    : root.isQueued ? Theme.color.preview
                                    : "transparent"

        Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

        // Position number
        Text {
            id: indexLabel
            anchors.left: parent.left
            anchors.leftMargin: Theme.space.lg
            anchors.verticalCenter: parent.verticalCenter
            text: ("0" + root.rowIndex).slice(-2)
            color: Theme.color.textTertiary
            font.family: Theme.font.monoFamily
            font.pixelSize: Theme.font.smallSize
        }

        // Type badge
        Badge {
            id: typeBadge
            anchors.left: indexLabel.right
            anchors.leftMargin: Theme.space.lg
            anchors.verticalCenter: parent.verticalCenter
            text: root.typeName
            background: Qt.darker(root.typeColor, 4.0)
            foreground: root.typeColor
        }

        // Title + subtitle
        Column {
            anchors.left: typeBadge.right
            anchors.leftMargin: Theme.space.lg
            anchors.right: statusRow.left
            anchors.rightMargin: Theme.space.md
            anchors.verticalCenter: parent.verticalCenter
            spacing: 3

            Text {
                text: root.title
                color: Theme.color.textPrimary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize + 1
                font.weight: Theme.font.weightMedium
                elide: Text.ElideRight
                width: parent.width
            }
            Text {
                visible: root.subtitle.length > 0
                text: root.subtitle
                color: Theme.color.textSecondary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                elide: Text.ElideRight
                width: parent.width
            }
        }

        // Status badges (LIVE / PREVIEW)
        Row {
            id: statusRow
            anchors.right: parent.right
            anchors.rightMargin: Theme.space.lg
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.space.sm

            Badge {
                visible: root.isLive
                text: qsTr("Live")
                background: Theme.color.live
                foreground: "#ffffff"
                pulse: true
            }
            Badge {
                visible: root.isQueued && !root.isLive
                text: qsTr("Preview")
                background: Theme.color.preview
                foreground: "#ffffff"
            }
        }

        MouseArea {
            id: ma
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.clicked()
            onDoubleClicked: root.doubleClicked()
        }
    }
}
