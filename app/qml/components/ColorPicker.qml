import QtQuick
import Crater

// SV square + hue strip + alpha strip + hex input + recent swatches.
// Built without QtQuick.Dialogs (project rule). The SV square is painted
// on a Canvas — repaints only when the hue changes, so dragging the SV
// pointer is cheap (no canvas redraw, only the marker moves).
//
// Layout: tight stack — SV/hue row, alpha row (with checkerboard so the
// transparent end of the gradient is actually visible), hex row, recent
// swatches row. Total height is sized to fit content + bottom padding;
// no dead space below the controls that would let clicks fall through
// to the popover-backing surface. A root-level absorber MouseArea
// catches any residual gap presses so nothing leaks through to the
// theme-editor canvas behind the popover.
Rectangle {
    id: root
    width: 240
    height: column.implicitHeight + Theme.space.md * 2
    // Squared per brand language. Wrapped by ColorPickerPopover's chrome,
    // which carries the shadow + outer border; this inner Rectangle reads
    // as the picker surface itself.
    radius: 0
    color: Theme.color.bgMenu
    border.color: Theme.color.borderStrong
    border.width: 1

    // External value (hex, possibly with alpha). Two-way binding via signals
    // so the parent doesn't have to wire `onColorChanged` plumbing.
    property string value: "#ffffff"

    signal commit(string hex)

    // ── HSV state (internal) ─────────────────────────────────────────
    property real hue: 0          // 0..1
    property real sat: 1          // 0..1
    property real val: 1          // 0..1
    property real alpha: 1        // 0..1
    property bool _suppressUpdate: false

    function _hsvaToHex(h, s, v, a) {
        // Use Qt's native string format directly: "#rrggbb" when alpha=1,
        // "#aarrggbb" when alpha<1. This is exactly what Qt.color() /
        // QColor::fromString / QML's Rectangle.color parser all accept —
        // so the hex this picker emits roundtrips losslessly through the
        // value binding and through every renderer in the codebase.
        //
        // PREVIOUSLY: converted to "#rrggbbaa" (alpha last, CSS-style).
        // Looked tidy, but Qt's color parser doesn't accept that format
        // — so on each alpha change the roundtrip reinterpreted the
        // alpha byte as blue, drifting the color toward whatever the
        // previous alpha was. The fix is to keep Qt's native ordering;
        // emit and parse now agree.
        return Qt.hsva(h, s, v, a).toString()
    }
    function _hexToHsva(hex) {
        const c = Qt.color(hex)
        if (!c) return null
        return { h: c.hsvHue >= 0 ? c.hsvHue : 0,
                 s: c.hsvSaturation,
                 v: c.hsvValue,
                 a: c.a }
    }
    // Drive the HSV(A) state from a hex string. Does NOT touch `value` — that
    // is the EXTERNAL input, bound by the popover to the node's color
    // (targetValue). Assigning `value` here would clobber that binding, so the
    // picker would freeze on the last-edited color and show it for the NEXT
    // node you open it on (the node's swatch reads right, but the wheel is
    // stale). _emit() already pushes edits outward to the node, which
    // round-trips back through the `value` binding — the picker never needs to
    // write its own `value`.
    function _applyHsvaFromHex(hex) {
        _suppressUpdate = true
        const parsed = _hexToHsva(hex)
        if (parsed) {
            hue = parsed.h
            sat = parsed.s
            val = parsed.v
            alpha = parsed.a
        }
        _suppressUpdate = false
    }
    function _syncFromValue() { _applyHsvaFromHex(value) }
    function _emit() {
        if (_suppressUpdate) return
        commit(_hsvaToHex(hue, sat, val, alpha))
    }
    // Apply a typed/pasted hex: parse, drive the HSV state (which moves the
    // wheel + markers and repaints), and emit. No-op for anything Qt's color
    // parser rejects, so partial input mid-type (e.g. "#ff") just leaves the
    // picker on its last valid color until enough characters land.
    function _applyHex(t) {
        const c = Qt.color(t)
        if (!c || c.toString() === "") return
        // Drive HSV from the typed hex directly; never assign `value` (see
        // _applyHsvaFromHex). _emit() pushes the change out to the node.
        _applyHsvaFromHex(t)
        _emit()
    }

    Component.onCompleted: _syncFromValue()
    onValueChanged:        if (!_suppressUpdate) _syncFromValue()
    onHueChanged:   svCanvas.requestPaint()

    // ── Click absorber ───────────────────────────────────────────────
    // Declared FIRST so it sits beneath the interactive controls in
    // Qt's hit-testing stack — the SV/hue/alpha/hex MouseAreas (declared
    // later, drawn on top) receive events first; anything that falls
    // through hits this. Without it, presses in the picker's interior
    // gaps (between sections, around the recent-swatches row) pass
    // through the popover to whatever's behind it (typically the theme
    // editor canvas), where they deselect nodes or start canvas drags.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        hoverEnabled: true
        onPressed: function(m) { m.accepted = true }
        onWheel:   function(w) { w.accepted = true }
    }

    Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.leftMargin:  Theme.space.md
        anchors.rightMargin: Theme.space.md
        anchors.topMargin:   Theme.space.md
        spacing: Theme.space.sm

        // ── SV square + hue strip ────────────────────────────────────
        Item {
            width: parent.width
            height: 140

            Canvas {
                id: svCanvas
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.right: hueStrip.left
                anchors.rightMargin: 8
                renderStrategy: Canvas.Cooperative
                onPaint: {
                    const ctx = getContext("2d")
                    // Horizontal: white→hue at full V/S. Vertical: fade to black.
                    const grad = ctx.createLinearGradient(0, 0, width, 0)
                    grad.addColorStop(0, "#ffffff")
                    grad.addColorStop(1, Qt.hsva(root.hue, 1, 1, 1))
                    ctx.fillStyle = grad
                    ctx.fillRect(0, 0, width, height)
                    const fade = ctx.createLinearGradient(0, 0, 0, height)
                    fade.addColorStop(0, "rgba(0,0,0,0)")
                    fade.addColorStop(1, "rgba(0,0,0,1)")
                    ctx.fillStyle = fade
                    ctx.fillRect(0, 0, width, height)
                }
                // Marker — double-ring (black outer + white inner) so it
                // stays visible on any background, light or dark. Larger
                // than the old 10px single-ring so it's an obvious
                // crosshair instead of a faint dot.
                Item {
                    width: 14; height: 14
                    x: svCanvas.width  * root.sat - 7
                    y: svCanvas.height * (1 - root.val) - 7
                    Rectangle {
                        anchors.fill: parent
                        radius: width / 2
                        color: "transparent"
                        border.color: "#000000"
                        border.width: 3
                    }
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 2
                        radius: width / 2
                        color: "transparent"
                        border.color: "#ffffff"
                        border.width: 2
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    onPressed: _set(mouseX, mouseY)
                    onPositionChanged: if (pressed) _set(mouseX, mouseY)
                    function _set(x, y) {
                        root.sat = Math.max(0, Math.min(1, x / svCanvas.width))
                        root.val = Math.max(0, Math.min(1, 1 - y / svCanvas.height))
                        root._emit()
                    }
                }
            }

            // Hue strip
            Rectangle {
                id: hueStrip
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: 16
                radius: 0
                gradient: Gradient {
                    GradientStop { position: 0.00; color: "#ff0000" }
                    GradientStop { position: 0.17; color: "#ffff00" }
                    GradientStop { position: 0.33; color: "#00ff00" }
                    GradientStop { position: 0.50; color: "#00ffff" }
                    GradientStop { position: 0.67; color: "#0000ff" }
                    GradientStop { position: 0.83; color: "#ff00ff" }
                    GradientStop { position: 1.00; color: "#ff0000" }
                }
                // Indicator — black bar with white center stripe; wider
                // than the strip so it reads as a hard marker rather
                // than a glowing line.
                Item {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: parent.width + 8
                    height: 5
                    y: parent.height * root.hue - 2
                    Rectangle { anchors.fill: parent; color: "#000000"; radius: 0 }
                    Rectangle { anchors.fill: parent; anchors.margins: 1; color: "#ffffff"; radius: 0 }
                }
                MouseArea {
                    anchors.fill: parent
                    onPressed: _set(mouseY); onPositionChanged: if (pressed) _set(mouseY)
                    function _set(y) {
                        root.hue = Math.max(0, Math.min(1, y / hueStrip.height))
                        root._emit()
                    }
                }
            }
        }

        // ── Alpha slider ─────────────────────────────────────────────
        // Full-width bar with a checkerboard backing so the transparent
        // end of the gradient is visually obvious as "see-through" — not
        // mistaken for the picker's own bg color. The checker is painted
        // on a Canvas as 6px tiles, then the alpha gradient draws on top.
        Item {
            id: alphaRow
            width: parent.width
            height: 20

            Canvas {
                id: alphaChecker
                anchors.fill: parent
                renderStrategy: Canvas.Cooperative
                onPaint: {
                    const ctx = getContext("2d")
                    const tile = 6
                    const cols = Math.ceil(width / tile)
                    const rows = Math.ceil(height / tile)
                    for (let r = 0; r < rows; r++) {
                        for (let c = 0; c < cols; c++) {
                            ctx.fillStyle = ((r + c) % 2 === 0) ? "#3f3f46" : "#a1a1aa"
                            ctx.fillRect(c * tile, r * tile, tile, tile)
                        }
                    }
                }
            }
            // Color gradient — transparent→opaque current color. Sits on
            // top of the checker so the low-alpha end reveals it.
            Rectangle {
                anchors.fill: parent
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: Qt.hsva(root.hue, root.sat, root.val, 0) }
                    GradientStop { position: 1.0; color: Qt.hsva(root.hue, root.sat, root.val, 1) }
                }
            }
            // Indicator — same double-stripe treatment as the hue marker
            // so the picker's two sliders read as siblings.
            Item {
                width: 5
                height: parent.height + 6
                y: -3
                x: parent.width * root.alpha - 2
                Rectangle { anchors.fill: parent; color: "#000000"; radius: 0 }
                Rectangle { anchors.fill: parent; anchors.margins: 1; color: "#ffffff"; radius: 0 }
            }
            MouseArea {
                anchors.fill: parent
                onPressed: _set(mouseX); onPositionChanged: if (pressed) _set(mouseX)
                function _set(x) {
                    root.alpha = Math.max(0, Math.min(1, x / alphaRow.width))
                    root._emit()
                }
            }
        }

        // ── Hex input ────────────────────────────────────────────────
        // Full-width, properly sized, with a leading "HEX" label inside
        // the box. Reads as a labeled field instead of an anonymous text
        // entry sharing a row with a slider.
        Rectangle {
            width: parent.width
            height: 32
            radius: 0
            color: Theme.color.canvas
            border.color: hexInput.activeFocus ? Theme.color.brand : Theme.color.borderStrong
            border.width: 1

            Text {
                id: hexLabel
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("HEX")
                color: Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                font.weight: Theme.font.weightSemiBold
                font.letterSpacing: 1.0
            }
            TextInput {
                id: hexInput
                anchors.left: hexLabel.right
                anchors.leftMargin: 8
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                verticalAlignment: TextInput.AlignVCenter
                color: Theme.color.textPrimary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize
                text: root._hsvaToHex(root.hue, root.sat, root.val, root.alpha)
                selectByMouse: true
                // Live: track the typed hex on every keystroke so the wheel,
                // markers and chosen color follow along immediately — no need
                // to press Enter or blur the field (the old behavior only
                // committed on focus loss, e.g. switching windows).
                onTextEdited: root._applyHex(text)
                // Enter / blur: final commit, then re-establish the `text`
                // binding that the manual edit broke. Without this the field
                // would stop reflecting wheel/slider changes after any typed
                // entry, and the displayed value would stay non-canonical
                // (e.g. "#fff" instead of "#ffffff").
                onEditingFinished: {
                    root._applyHex(text)
                    text = Qt.binding(function() {
                        return root._hsvaToHex(root.hue, root.sat, root.val, root.alpha)
                    })
                }
            }
        }

        // ── Recent swatches ──────────────────────────────────────────
        // Always render the label + 8 slots. Empty slots show as faint
        // outlined squares so the section reads as "this is where recent
        // colors will land" rather than disappearing when the operator
        // hasn't picked anything yet. Once they pick a color it lands in
        // slot 0 (filled), the rest stay outlines until they fill up.
        Item { width: 1; height: 4 }   // micro-spacer

        Text {
            text: qsTr("RECENT")
            color: Theme.color.textTertiary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.microSize
            font.weight: Theme.font.weightSemiBold
            font.letterSpacing: 1.2
        }

        Item {
            id: swatchRow
            width: parent.width
            height: 24
            // Each cell width = (rowWidth - 7 gaps) / 8. Floor for safety
            // so the last cell doesn't overflow at sub-pixel widths.
            readonly property real _cellW: Math.floor((width - 7 * 4) / 8)

            Row {
                anchors.fill: parent
                spacing: 4
                Repeater {
                    model: 8
                    delegate: Rectangle {
                        width: swatchRow._cellW
                        height: swatchRow.height
                        radius: 0
                        readonly property string _color: {
                            const list = AppState.recentColors || []
                            return index < list.length ? list[index] : ""
                        }
                        color: _color || "transparent"
                        border.color: _color ? Theme.color.borderStrong
                                              : Theme.color.borderSubtle
                        border.width: 1

                        MouseArea {
                            anchors.fill: parent
                            visible: parent._color.length > 0
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                // Drive HSV from the recent color; never assign
                                // `value` (keeps the targetValue binding live).
                                root._applyHsvaFromHex(parent._color)
                                root._emit()
                            }
                        }
                    }
                }
            }
        }
    }
}
