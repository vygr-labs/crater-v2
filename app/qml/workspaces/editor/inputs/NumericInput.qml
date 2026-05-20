import QtQuick
import Crater

// Tight numeric input row used throughout the properties panel.
//
//   NumericInput {
//       label: "X"
//       value: node.style.x || 0
//       suffix: "%"
//       min: 0; max: 100; step: 0.1
//       onLive:   workspace.workingTheme.setNodeStyle(node.id, "x", v)   // no history
//       onCommit: workspace.saveToHistory()                              // history only
//   }
//
// Live vs commit:
//   live   ─ fires on every parseable text change AND every drag-scrub
//            pixel. Callers write the canonical model directly (no
//            history snapshot). The model's nodeStyleChanged signal
//            drives the canvas update — same path used by every
//            existing edit, no special-case rendering.
//   commit ─ fires once on focus loss / Enter / Up-Down step / drag
//            release. Callers only snapshot history. One undo step
//            per editing session, not per keystroke.
//
// This also fixes the long-standing drag-scrub history bug: the old code
// called commit per mouse-move pixel, writing N history snapshots per
// drag. live handles per-pixel updates; commit only fires on release.
Item {
    id: root
    property string label: ""
    property real   value: 0
    property string suffix: ""
    property real   min: -Infinity
    property real   max:  Infinity
    property real   step: 1
    property var    workspace          // for the selectedNodeId re-sync below

    signal live(real newValue)
    signal commit(real newValue)

    implicitWidth: parent ? parent.width : 120
    implicitHeight: 36

    // Label width is content-driven with a 36px floor — short labels (X/Y/Z)
    // keep the tight grid alignment we want across paired inputs, while longer
    // labels like "Weight" or "Max" expand to their natural width instead of
    // being clipped by the input box drawn on top.
    Text {
        id: lbl
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: root.label
        color: Theme.color.textSecondary
        font.family: Theme.font.family
        font.pixelSize: Theme.font.bodySize
        font.weight: Theme.font.weightMedium
        width: Math.max(36, implicitWidth + 6)
        visible: root.label.length > 0
    }

    Rectangle {
        id: box
        anchors.left: lbl.visible ? lbl.right : parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        height: 32
        radius: 0
        color: Theme.color.canvas
        border.color: input.activeFocus ? Theme.color.brand : Theme.color.borderStrong
        border.width: 1

        TextInput {
            id: input
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: suffixLabel.implicitWidth + 10
            verticalAlignment: TextInput.AlignVCenter
            color: Theme.color.textPrimary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.bodySize
            text: _format(root.value)
            selectByMouse: true
            inputMethodHints: Qt.ImhFormattedNumbersOnly
            validator: DoubleValidator { bottom: root.min; top: root.max; notation: DoubleValidator.StandardNotation }

            // Drag-to-scrub. Hold mouse on the input and drag horizontally
            // to nudge the value by `step` per pixel. Per-pixel updates
            // fire `live` (transient only); the canonical commit fires
            // once on release.
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
                property real _lastLive: 0
                onPressed: function(m) { _sx = m.x; _start = root.value; _dragging = false; _lastLive = root.value; m.accepted = false }
                onPositionChanged: function(m) {
                    if (!pressed) return
                    const dx = m.x - _sx
                    if (Math.abs(dx) < 4) return
                    _dragging = true
                    const newV = Math.max(root.min, Math.min(root.max,
                        Math.round((_start + dx * root.step) / root.step) * root.step))
                    _lastLive = newV
                    root.live(newV)
                    m.accepted = true
                }
                onReleased: function(m) {
                    if (_dragging) {
                        root.commit(_lastLive)
                        _dragging = false
                        m.accepted = true
                    }
                }
            }

            // Commit on blur. (Shortcut gating no longer needs a manual
            // focus flag — the workspace derives inputFocused from
            // Window.activeFocusItem.)
            onActiveFocusChanged: if (!activeFocus) _commitFromText()
            // Per-keystroke live update. Coalesced via Qt.callLater so a
            // burst of typed digits doesn't fire N setNodeStyle writes
            // within the same event-loop tick — only the last one sticks.
            // Cheap, and means a slow typer still gets per-keystroke
            // feedback while a fast typer doesn't waste cycles. Skips
            // firing when the parsed value matches what we already last
            // sent (Backspace through a typo, etc.).
            property real _lastLiveText: NaN
            onTextChanged: Qt.callLater(_fireLiveFromText)

            Keys.onReturnPressed: { _commitFromText(); root.focus = false }
            Keys.onEnterPressed:  { _commitFromText(); root.focus = false }
            Keys.onEscapePressed: { text = _format(root.value); root.focus = false }
            Keys.onUpPressed:     _bump( 1)
            Keys.onDownPressed:   _bump(-1)
        }

        Text {
            id: suffixLabel
            anchors.right: parent.right
            anchors.rightMargin: 8
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
    function _fireLiveFromText() {
        // Only fire while the input is focused — defocused changes go
        // through _commitFromText. Skip if the parsed value duplicates
        // what we already sent (avoids redundant writes when the user
        // types a separator like "5." that doesn't change the numeric
        // value).
        if (!input.activeFocus) return
        const parsed = parseFloat(input.text)
        if (!isFinite(parsed)) return
        const clamped = Math.max(root.min, Math.min(root.max, parsed))
        if (clamped === input._lastLiveText) return
        input._lastLiveText = clamped
        root.live(clamped)
    }
    function _bump(dir) {
        const newV = Math.max(root.min, Math.min(root.max, root.value + dir * root.step))
        root.commit(newV)
    }
    // Keep input.text in sync with root.value. Two cases:
    //   1. Unfocused: always resync — nothing the user is mid-typing
    //      to protect.
    //   2. Focused: resync only when an EXTERNAL change has produced a
    //      value our typed text doesn't already represent. Examples
    //      that trigger this branch: drag-scrubbing this input (live
    //      fires per pixel → root.value moves underneath the focused
    //      text), dragging the node on the canvas while an input is
    //      focused, undo/redo while editing, sibling-field writes that
    //      cascade through PropertiesPanel's _refreshTick.
    //   `!isFinite(parsed)` covers mid-typing states like "", "-", "5."
    //   where the user isn't done — we leave their text alone in those
    //   cases (no decimal-eating, no cursor jump). If their typed text
    //   parses to the same value, no resync (they're already showing
    //   what the model says).
    onValueChanged: {
        if (!input.activeFocus) {
            input.text = _format(value)
            return
        }
        const parsed = parseFloat(input.text)
        if (isFinite(parsed) && parsed !== value) {
            input.text = _format(value)
        }
    }

    // Force a text refresh when the user switches layers, bypassing the
    // focus guard above. That guard protects in-progress typing from being
    // clobbered by *same-node* external mutations (e.g. drag-resize while
    // typing in Width) — but when the bound node itself changes, the user
    // is no longer editing the same thing. Without this, the input would
    // keep displaying the previous node's number AND defocus-commit would
    // parse that stale text and write it back to the *new* node — silent
    // data corruption. Qt.callLater defers the read until the binding
    // cascade (selectedNodeId → localNode → node → value) has settled.
    Connections {
        target: root.workspace
        function onSelectedNodeIdChanged() {
            Qt.callLater(function() {
                input.text = _format(root.value)
            })
        }
    }
}
