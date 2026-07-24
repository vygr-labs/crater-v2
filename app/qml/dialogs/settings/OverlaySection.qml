import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic

// Settings ▸ Overlay — the friendly per-type theme editor for the live overlay
// (timers / clock / messages). Pick a type, choose a curated preset or
// customize it: font, text fill (solid or a gradient built with the friendly
// GradientEditor), effect, and background. Changes preview live and persist via
// LiveOverlayStyles → SettingsService (a JSON blob; no theme-table row).
//
// The two GradientEditors OWN their spec, so we push into them imperatively
// (_syncEditors) rather than binding — a binding would fight the editor's own
// assignments. Discrete controls persist immediately; a gradient persists only
// on its committed() (never per drag tick, which would thrash QSettings).
Item {
    id: root

    property string _type: "countdown"
    property var    _style: LiveOverlayStyles.styleFor("countdown")
    property double _sampleTarget: 0

    Component.onCompleted: {
        _sampleTarget = Date.now() + 5 * 60 * 1000
        _syncEditors()
    }

    function _syncEditors() {
        textGradEd.spec = _style.textGradient
        bgGradEd.spec = _style.backgroundGradient
    }
    function _selectType(t) {
        _type = t
        _style = LiveOverlayStyles.styleFor(t)
        _syncEditors()
    }
    function _applyPreset(id) {
        _style = LiveOverlayStyles.presetStyle(id)
        LiveOverlayStyles.applyPreset(_type, id)
        _syncEditors()
    }
    function _reset() {
        LiveOverlayStyles.resetType(_type)
        _style = LiveOverlayStyles.styleFor(_type)
        _syncEditors()
    }
    // Manual edit → mark custom. persist=false for live gradient drags; the
    // editor's committed() then calls _persist().
    function _set(key, val, persist) {
        var s = LiveOverlayStyles.cloneStyle(_style)
        s[key] = val
        s.presetId = ""
        _style = s
        if (persist) LiveOverlayStyles.setStyleFor(_type, s)
    }
    function _persist() { LiveOverlayStyles.setStyleFor(_type, _style) }

    readonly property bool _textGradient: _style.textFillType === "gradient"
    readonly property bool _bgGradient: _style.background === "gradient"
    readonly property bool _effectOn: _style.effect !== "none"

    Flickable {
        anchors.fill: parent
        contentHeight: layout.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: AppScrollBar {}

        ColumnLayout {
            id: layout
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Theme.space.xl
            anchors.rightMargin: Theme.space.xl + Theme.size.scrollBar
            anchors.topMargin: Theme.space.xxxl
            spacing: Theme.space.sm

            // ── Type + preview ───────────────────────────────────────────
            SegmentedControl {
                Layout.fillWidth: true
                options: [
                    { value: "countdown", label: qsTr("Countdown") },
                    { value: "countup",   label: qsTr("Count-up") },
                    { value: "clock",     label: qsTr("Clock") },
                    { value: "message",   label: qsTr("Message") }
                ]
                current: root._type
                onChanged: function(v) { root._selectType(v) }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: width * 9 / 16
                color: "#26262b"
                border.color: Theme.color.borderStrong
                border.width: 1
                clip: true
                LiveOverlayLayer {
                    anchors.fill: parent
                    mode: root._type
                    style: root._style
                    position: "center"
                    message: qsTr("Please silence your phones")
                    caption: qsTr("Service begins")
                    countdownTargetMs: root._sampleTarget
                    countupAccumMs: 92000
                    countupRunning: false
                    clock24h: LiveMessages.clock24h
                    clockShowSeconds: LiveMessages.clockShowSeconds
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.space.sm
                Combobox {
                    Layout.fillWidth: true
                    searchable: false
                    options: LiveOverlayStyles.presetOptions
                    value: root._style.presetId
                           ? LiveOverlayStyles.presetName(root._style.presetId)
                           : qsTr("Custom")
                    onValueSelected: function(v) { root._applyPreset(v) }
                }
                GhostButton {
                    text: qsTr("Reset")
                    iconName: "rotate-ccw"
                    onClicked: root._reset()
                }
            }

            // ── Text ─────────────────────────────────────────────────────
            SettingsSectionHeader { title: qsTr("Text") }

            LabeledRow {
                label: qsTr("Fill")
                SegmentedControl {
                    Layout.fillWidth: true
                    options: [
                        { value: "solid",    label: qsTr("Solid") },
                        { value: "gradient", label: qsTr("Gradient") }
                    ]
                    current: root._style.textFillType
                    onChanged: function(v) { root._set("textFillType", v, true) }
                }
            }
            LabeledRow {
                visible: !root._textGradient
                label: qsTr("Color")
                ColorSwatchInput {
                    Layout.fillWidth: true
                    value: root._style.textColor
                    onColorPicked: function(hex) { root._set("textColor", hex, false) }
                    onCommitted:   function(hex) { root._set("textColor", hex, true) }
                }
            }
            GradientEditor {
                id: textGradEd
                Layout.fillWidth: true
                visible: root._textGradient
                onChanged:   function(spec) { root._set("textGradient", spec, false) }
                onCommitted: root._persist()
            }

            LabeledRow {
                label: qsTr("Weight")
                SegmentedControl {
                    Layout.fillWidth: true
                    options: [
                        { value: 400, label: qsTr("Regular") },
                        { value: 500, label: qsTr("Medium") },
                        { value: 600, label: qsTr("Semibold") },
                        { value: 700, label: qsTr("Bold") }
                    ]
                    current: root._style.fontWeight
                    onChanged: function(v) { root._set("fontWeight", v, true) }
                }
            }
            LabeledRow {
                label: qsTr("Spacing")
                SegmentedControl {
                    Layout.fillWidth: true
                    options: [
                        { value: 0, label: qsTr("None") },
                        { value: 2, label: qsTr("Normal") },
                        { value: 4, label: qsTr("Wide") }
                    ]
                    current: root._style.letterSpacing
                    onChanged: function(v) { root._set("letterSpacing", v, true) }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: 40
                Text {
                    Layout.fillWidth: true
                    text: qsTr("Uppercase")
                    color: Theme.color.textSecondary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize
                    font.weight: Theme.font.weightMedium
                }
                ToggleSwitch {
                    value: root._style.uppercase
                    onToggled: root._set("uppercase", !root._style.uppercase, true)
                }
            }
            LabeledRow {
                label: qsTr("Effect")
                SegmentedControl {
                    Layout.fillWidth: true
                    options: [
                        { value: "none",   label: qsTr("None") },
                        { value: "shadow", label: qsTr("Shadow") },
                        { value: "glow",   label: qsTr("Glow") }
                    ]
                    current: root._style.effect
                    onChanged: function(v) { root._set("effect", v, true) }
                }
            }
            LabeledRow {
                visible: root._effectOn
                label: qsTr("Effect color")
                ColorSwatchInput {
                    Layout.fillWidth: true
                    value: root._style.effectColor
                    onColorPicked: function(hex) { root._set("effectColor", hex, false) }
                    onCommitted:   function(hex) { root._set("effectColor", hex, true) }
                }
            }

            // ── Background ───────────────────────────────────────────────
            SettingsSectionHeader { title: qsTr("Background") }

            LabeledRow {
                label: qsTr("Style")
                SegmentedControl {
                    Layout.fillWidth: true
                    options: [
                        { value: "none",     label: qsTr("None") },
                        { value: "dim",      label: qsTr("Dim") },
                        { value: "solid",    label: qsTr("Solid") },
                        { value: "gradient", label: qsTr("Gradient") }
                    ]
                    current: root._style.background
                    onChanged: function(v) { root._set("background", v, true) }
                }
            }
            LabeledRow {
                visible: root._style.background === "solid"
                label: qsTr("Color")
                ColorSwatchInput {
                    Layout.fillWidth: true
                    value: root._style.backgroundColor
                    onColorPicked: function(hex) { root._set("backgroundColor", hex, false) }
                    onCommitted:   function(hex) { root._set("backgroundColor", hex, true) }
                }
            }
            GradientEditor {
                id: bgGradEd
                Layout.fillWidth: true
                visible: root._bgGradient
                onChanged:   function(spec) { root._set("backgroundGradient", spec, false) }
                onCommitted: root._persist()
            }

            Item { Layout.fillWidth: true; Layout.preferredHeight: Theme.space.xl }
        }
    }

    // Small labeled control row — a fixed-width label + the slotted control(s)
    // appended as further RowLayout children (so Layout.fillWidth works on them).
    component LabeledRow: RowLayout {
        property string label: ""
        Layout.fillWidth: true
        Layout.preferredHeight: 40
        spacing: Theme.space.md
        Text {
            Layout.preferredWidth: 96
            text: parent.label
            color: Theme.color.textSecondary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.bodySize
            font.weight: Theme.font.weightMedium
        }
    }
}
