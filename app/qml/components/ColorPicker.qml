import QtQuick
import Crater

// SV square + hue strip + alpha strip + hex input + recent swatches.
// Built without QtQuick.Dialogs (project rule). The SV square is painted
// on a Canvas — repaints only when the hue changes, so dragging the SV
// pointer is cheap (no canvas redraw, only the marker moves).
Rectangle {
    id: root
    width: 240
    height: 320
    radius: Theme.radius.md
    color: Theme.color.elevated
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
        const c = Qt.hsva(h, s, v, a)
        // toString returns "#aarrggbb" — convert to "#rrggbbaa" canonical.
        const str = c.toString()
        if (str.length === 9) {
            return "#" + str.substring(3) + str.substring(1, 3)
        }
        return str   // already "#rrggbb"
    }
    function _hexToHsva(hex) {
        const c = Qt.color(hex)
        if (!c) return null
        return { h: c.hsvHue >= 0 ? c.hsvHue : 0,
                 s: c.hsvSaturation,
                 v: c.hsvValue,
                 a: c.a }
    }
    function _syncFromValue() {
        _suppressUpdate = true
        const parsed = _hexToHsva(value)
        if (parsed) {
            hue = parsed.h
            sat = parsed.s
            val = parsed.v
            alpha = parsed.a
        }
        _suppressUpdate = false
    }
    function _emit() {
        if (_suppressUpdate) return
        commit(_hsvaToHex(hue, sat, val, alpha))
    }

    Component.onCompleted: _syncFromValue()
    onValueChanged:        if (!_suppressUpdate) _syncFromValue()
    onHueChanged:   svCanvas.requestPaint()

    Column {
        anchors.fill: parent
        anchors.margins: Theme.space.md
        spacing: Theme.space.sm

        // SV square (200 × 160)
        Item {
            width: parent.width
            height: 140
            Canvas {
                id: svCanvas
                width: parent.width - 24
                height: parent.height
                renderStrategy: Canvas.Cooperative
                onPaint: {
                    const ctx = getContext("2d")
                    // Horizontal: hue at full V/S along x; vertical fades to black.
                    // Bake into a single fill so we don't pay for two gradients.
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
                // Marker
                Rectangle {
                    width: 10; height: 10; radius: 5
                    color: "transparent"
                    border.color: "#ffffff"; border.width: 2
                    x: svCanvas.width * root.sat - 5
                    y: svCanvas.height * (1 - root.val) - 5
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
                radius: 2
                gradient: Gradient {
                    GradientStop { position: 0.00; color: "#ff0000" }
                    GradientStop { position: 0.17; color: "#ffff00" }
                    GradientStop { position: 0.33; color: "#00ff00" }
                    GradientStop { position: 0.50; color: "#00ffff" }
                    GradientStop { position: 0.67; color: "#0000ff" }
                    GradientStop { position: 0.83; color: "#ff00ff" }
                    GradientStop { position: 1.00; color: "#ff0000" }
                }
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: parent.width + 6; height: 3
                    y: parent.height * root.hue - 1
                    color: "#ffffff"; radius: 1
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

        // Alpha strip + hex input
        Item {
            width: parent.width
            height: 28
            Rectangle {
                id: alphaStrip
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 110
                height: 16
                radius: 2
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: Qt.hsva(root.hue, root.sat, root.val, 0) }
                    GradientStop { position: 1.0; color: Qt.hsva(root.hue, root.sat, root.val, 1) }
                }
                Rectangle {
                    width: 3; height: parent.height + 6
                    y: -3
                    x: parent.width * root.alpha - 1
                    color: "#ffffff"; radius: 1
                }
                MouseArea {
                    anchors.fill: parent
                    onPressed: _set(mouseX); onPositionChanged: if (pressed) _set(mouseX)
                    function _set(x) {
                        root.alpha = Math.max(0, Math.min(1, x / alphaStrip.width))
                        root._emit()
                    }
                }
            }
            Rectangle {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: 96; height: 22
                radius: Theme.radius.sm
                color: Theme.color.canvas
                border.color: hexInput.activeFocus ? Theme.color.brand : Theme.color.borderStrong
                border.width: 1
                TextInput {
                    id: hexInput
                    anchors.fill: parent
                    anchors.leftMargin: 4
                    verticalAlignment: TextInput.AlignVCenter
                    color: Theme.color.textPrimary
                    font.family: Theme.font.monoFamily
                    font.pixelSize: Theme.font.smallSize
                    text: root._hsvaToHex(root.hue, root.sat, root.val, root.alpha)
                    selectByMouse: true
                    onEditingFinished: {
                        const c = Qt.color(text)
                        if (c && c.toString() !== "") {
                            root.value = text
                            root._syncFromValue()
                            root._emit()
                        }
                    }
                }
            }
        }

        // Recent swatches
        Row {
            width: parent.width
            spacing: 4
            Repeater {
                model: AppState.recentColors
                delegate: Rectangle {
                    width: 22; height: 22; radius: 3
                    color: modelData
                    border.color: Theme.color.borderStrong
                    border.width: 1
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.value = modelData
                            root._syncFromValue()
                            root._emit()
                        }
                    }
                }
            }
        }
    }
}
