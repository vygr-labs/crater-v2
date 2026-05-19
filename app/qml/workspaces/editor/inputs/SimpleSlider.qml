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
    implicitHeight: 40

    Text {
        id: lbl
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: root.label
        color: Theme.color.textSecondary
        font.family: Theme.font.family
        font.pixelSize: Theme.font.bodySize
        font.weight: Theme.font.weightMedium
        width: 72
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
        height: 6
        radius: 0
        color: Theme.color.canvas

        readonly property real _frac: Math.max(0, Math.min(1, (root.value - root.min) / (root.max - root.min)))

        Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: parent.width * track._frac
            radius: 0
            color: Theme.color.brand
        }

        // Squared brand chip thumb — matches the rest of the editor's
        // architectural language. Slightly larger than the track so it
        // remains an obvious hit target on a 6px-tall track.
        Rectangle {
            id: thumb
            width: 14; height: 14; radius: 0
            color: Theme.color.brand
            border.color: "#ffffff"
            border.width: 2
            x: track.width * track._frac - 7
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
        color: Theme.color.textPrimary
        font.family: Theme.font.family
        font.pixelSize: Theme.font.bodySize
        width: 42
        horizontalAlignment: Text.AlignRight
    }
}
