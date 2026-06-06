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

    // Display value. It tracks `value` (the bound node color) but the live
    // picker drives it directly during a drag — WITHOUT ever assigning to
    // `value` itself, which would clobber the parent's
    // `value: node.style.backgroundColor` binding. That clobber is a real bug:
    // the properties panel REUSES one ContainerPropertiesContent across
    // container selections, so a frozen `value` keeps painting the last-edited
    // color onto the next node you click. onValueChanged re-syncs `_shown`
    // whenever the bound node changes, so switching layers always shows the
    // newly-selected node's own color.
    property string _shown: value
    onValueChanged: _shown = value

    signal colorPicked(string hex)   // live, every drag tick (no history)
    signal committed(string hex)     // once, on close — snapshot one undo step

    implicitHeight: 36

    Text {
        id: lbl
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: root.label
        color: Theme.color.textSecondary
        font.family: Theme.font.family
        font.pixelSize: Theme.font.bodySize
        font.weight: Theme.font.weightMedium
        width: 44
        visible: root.label.length > 0
    }

    // Swatch + hex
    Rectangle {
        id: row
        anchors.left: lbl.visible ? lbl.right : parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        height: 32
        radius: 0
        color: Theme.color.canvas
        border.color: rowMa.containsMouse ? Theme.color.brand : Theme.color.borderStrong
        border.width: 1

        Rectangle {
            id: swatch
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 6
            width: 26; height: 22
            radius: 0
            color: root._shown
            border.color: Theme.color.borderSubtle
            border.width: 1
        }
        Text {
            anchors.left: swatch.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 8
            text: root._shown
            color: Theme.color.textPrimary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.bodySize
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
        targetValue: root._shown
        // Live tick: update the swatch and let the handler drive the node, with
        // no history churn during the drag. Drive `_shown`, NOT `value` — see
        // the `_shown` note above for why touching `value` here leaks color to
        // the next-selected node.
        onColorChosen: function(c) {
            root._shown = c
            root.colorPicked(c)
        }
        // Close: record the FINAL color in recents (not every drag
        // intermediate) and let the handler snapshot a single undo step.
        onCommitted: function(c) {
            AppState.pushRecentColor(c)
            root.committed(c)
        }
    }
}
