import QtQuick
import Crater

// Tight numeric input row used throughout the properties panel.
//
//   NumericInput {
//       label: "X"
//       value: node.style.x
//       suffix: "%"
//       min: 0; max: 100; step: 0.1
//       onCommit: workspace.setNodeStyle(...)
//   }
//
// onCommit fires when the user defocuses or presses Enter — drag-while-typing
// would generate one history entry per character, which is awful.
Item {
    id: root
    property string label: ""
    property real   value: 0
    property string suffix: ""
    property real   min: -Infinity
    property real   max:  Infinity
    property real   step: 1
    property var    workspace          // for inputFocused tracking

    signal commit(real newValue)

    implicitWidth: parent ? parent.width : 120
    implicitHeight: 28

    Text {
        id: lbl
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: root.label
        color: Theme.color.textTertiary
        font.family: Theme.font.family
        font.pixelSize: Theme.font.smallSize
        width: 30
        visible: root.label.length > 0
    }

    Rectangle {
        id: box
        anchors.left: lbl.visible ? lbl.right : parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        height: 24
        radius: Theme.radius.sm
        color: Theme.color.canvas
        border.color: input.activeFocus ? Theme.color.brand : Theme.color.borderStrong
        border.width: 1

        TextInput {
            id: input
            anchors.fill: parent
            anchors.leftMargin: 6
            anchors.rightMargin: suffixLabel.implicitWidth + 8
            verticalAlignment: TextInput.AlignVCenter
            color: Theme.color.textPrimary
            font.family: Theme.font.monoFamily
            font.pixelSize: Theme.font.smallSize
            text: _format(root.value)
            selectByMouse: true
            inputMethodHints: Qt.ImhFormattedNumbersOnly
            validator: DoubleValidator { bottom: root.min; top: root.max; notation: DoubleValidator.StandardNotation }

            // Drag-to-scrub. Hold mouse on the input and drag horizontally
            // to nudge the value by `step` per pixel.
            MouseArea {
                anchors.fill: parent
                // Don't steal clicks from the TextInput — only activates when
                // the user drags more than 4 pixels.
                cursorShape: pressed ? Qt.SizeHorCursor : Qt.IBeamCursor
                acceptedButtons: Qt.LeftButton
                propagateComposedEvents: true
                property real _sx: 0
                property real _start: 0
                property bool _dragging: false
                onPressed: function(m) { _sx = m.x; _start = root.value; _dragging = false; m.accepted = false }
                onPositionChanged: function(m) {
                    if (!pressed) return
                    const dx = m.x - _sx
                    if (Math.abs(dx) < 4) return
                    _dragging = true
                    const newV = Math.max(root.min, Math.min(root.max,
                        Math.round((_start + dx * root.step) / root.step) * root.step))
                    root.commit(newV)
                    m.accepted = true
                }
                onReleased: function(m) { if (_dragging) m.accepted = true }
            }

            onActiveFocusChanged: {
                if (root.workspace) root.workspace.inputFocused = activeFocus
                if (!activeFocus) _commitFromText()
            }
            Keys.onReturnPressed: { _commitFromText(); root.focus = false }
            Keys.onEnterPressed:  { _commitFromText(); root.focus = false }
            Keys.onEscapePressed: { text = _format(root.value); root.focus = false }
            Keys.onUpPressed:     _bump( 1)
            Keys.onDownPressed:   _bump(-1)
        }

        Text {
            id: suffixLabel
            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            text: root.suffix
            color: Theme.color.textTertiary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.smallSize
            visible: root.suffix.length > 0
        }
    }

    function _format(v) {
        // Display ints as ints; floats with 1 decimal (matches our 0.1% snap).
        const r = Math.round(v * 10) / 10
        return Number.isInteger(r) ? r.toString() : r.toFixed(1)
    }
    function _commitFromText() {
        const parsed = parseFloat(input.text)
        if (!isFinite(parsed)) { input.text = _format(root.value); return }
        const clamped = Math.max(root.min, Math.min(root.max, parsed))
        if (clamped !== root.value) root.commit(clamped)
        input.text = _format(clamped)
    }
    function _bump(dir) {
        const newV = Math.max(root.min, Math.min(root.max, root.value + dir * root.step))
        root.commit(newV)
    }
    onValueChanged: if (!input.activeFocus) input.text = _format(value)
}
