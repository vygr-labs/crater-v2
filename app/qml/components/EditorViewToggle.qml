import QtQuick
import Crater

// Two-segment "Structured | Raw text" switch for the lyric editors. Flat
// radii to match the editor dialogs. Clicking the inactive segment emits
// modeRequested; the dialog owns the actual mode so it can commit edits
// before flipping.
Rectangle {
    id: root

    property string mode: "structured"   // "structured" | "raw"
    signal modeRequested(string mode)

    width: 180
    height: 32
    radius: 0
    color: Theme.color.canvas
    border.color: Theme.color.borderStrong
    border.width: 1

    component Segment: Rectangle {
        id: seg
        property string value: ""
        property string label: ""
        readonly property bool selected: root.mode === value

        width: parent.width / 2
        height: parent.height
        radius: 0
        color: selected ? Theme.color.raised : "transparent"
        Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

        Text {
            anchors.centerIn: parent
            text: seg.label
            color: seg.selected ? Theme.color.textPrimary : Theme.color.textSecondary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.smallSize
            font.weight: Theme.font.weightMedium
        }
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: if (!seg.selected) root.modeRequested(seg.value)
        }
    }

    Row {
        anchors.fill: parent
        anchors.margins: 2
        spacing: 0

        Segment { value: "structured"; label: qsTr("Structured") }
        Segment { value: "raw";        label: qsTr("Raw text") }
    }
}
