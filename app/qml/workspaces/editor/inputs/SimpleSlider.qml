import QtQuick
import Crater

// Minimal slider with optional value label on the right.
//   SimpleSlider {
//       label: "Opacity"
//       value: node.style.opacity; min: 0; max: 1; step: 0.05
//       onCommit: workspace.setNodeStyle(...)
//   }
Item {
    id: root
    property string label: ""
    property real value: 0
    property real min: 0
    property real max: 1
    property real step: 0.01

    signal commit(real v)

    implicitWidth: parent ? parent.width : 280
    implicitHeight: 32

    Text {
        id: lbl
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: root.label
        color: Theme.color.textTertiary
        font.family: Theme.font.family
        font.pixelSize: Theme.font.smallSize
        width: 64
        elide: Text.ElideRight
        visible: root.label.length > 0
    }

    Rectangle {
        id: track
        anchors.left: lbl.visible ? lbl.right : parent.left
        anchors.right: valueLabel.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Theme.space.sm
        anchors.rightMargin: Theme.space.sm
        height: 4
        radius: 2
        color: Theme.color.canvas

        readonly property real _frac: Math.max(0, Math.min(1, (root.value - root.min) / (root.max - root.min)))

        Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: parent.width * track._frac
            radius: parent.radius
            color: Theme.color.brand
        }

        Rectangle {
            id: thumb
            width: 12; height: 12; radius: 6
            color: "#ffffff"
            border.color: Theme.color.brand
            border.width: 2
            x: track.width * track._frac - 6
            anchors.verticalCenter: parent.verticalCenter
        }

        MouseArea {
            anchors.fill: parent
            anchors.margins: -6
            cursorShape: Qt.PointingHandCursor
            onPressed: _set(mouseX)
            onPositionChanged: if (pressed) _set(mouseX)
            function _set(px) {
                const frac = Math.max(0, Math.min(1, px / track.width))
                const raw  = root.min + frac * (root.max - root.min)
                const snapped = Math.round(raw / root.step) * root.step
                if (snapped !== root.value) root.commit(snapped)
            }
        }
    }

    Text {
        id: valueLabel
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: Number.isInteger(root.value) ? root.value.toString() : root.value.toFixed(2)
        color: Theme.color.textSecondary
        font.family: Theme.font.monoFamily
        font.pixelSize: Theme.font.smallSize
        width: 36
        horizontalAlignment: Text.AlignRight
    }
}
