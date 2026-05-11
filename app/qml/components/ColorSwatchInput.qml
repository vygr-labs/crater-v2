import QtQuick
import Crater

// One row in the properties panel: label + 24px swatch + hex value. Clicking
// the swatch opens a ColorPicker popover anchored under it.
//
//   ColorSwatchInput { label: "Fill"; value: "#ffaa00"; onColorPicked: ... }
Item {
    id: root
    property string label: ""
    property string value: "#ffffff"

    signal colorPicked(string hex)

    implicitHeight: 28

    Text {
        id: lbl
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: root.label
        color: Theme.color.textTertiary
        font.family: Theme.font.family
        font.pixelSize: Theme.font.smallSize
        width: 36
        visible: root.label.length > 0
    }

    // Swatch + hex
    Rectangle {
        id: row
        anchors.left: lbl.visible ? lbl.right : parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        height: 24
        radius: Theme.radius.sm
        color: Theme.color.canvas
        border.color: rowMa.containsMouse ? Theme.color.brand : Theme.color.borderStrong
        border.width: 1

        Rectangle {
            id: swatch
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 4
            width: 20; height: 16
            radius: 2
            color: root.value
            border.color: Theme.color.borderSubtle
            border.width: 1
        }
        Text {
            anchors.left: swatch.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 6
            text: root.value
            color: Theme.color.textPrimary
            font.family: Theme.font.monoFamily
            font.pixelSize: Theme.font.smallSize
        }

        MouseArea {
            id: rowMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: popover.openAt(row)
        }
    }

    // Popover — anchored to the parent of root so it doesn't clip.
    ColorPickerPopover {
        id: popover
        targetValue: root.value
        onColorChosen: function(c) {
            root.value = c
            root.colorPicked(c)
            AppState.pushRecentColor(c)
        }
    }
}
