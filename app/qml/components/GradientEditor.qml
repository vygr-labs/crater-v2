import QtQuick
import QtQuick.Layouts
import Crater

// GradientEditor — the friendly, "no color-theory required" gradient tool.
// Composes: a curated preset gallery (one-click professional gradients), a big
// live preview, the draggable GradientBar, a selected-stop color/delete row, a
// Glossy/Matte finish toggle, a style + direction picker, and a harmony helper
// (pick one color → a tasteful multi-stop gradient). Reusable; the overlay
// style editor embeds it.
//
// Owns the working `spec` and emits `changed` (live) + `committed` (undo point).
// Follows the GradientBar live/commit contract: a pin *position* drag updates
// only the preview (never reassigns `spec`, which feeds the bar's pin model and
// would rebuild the dragged pin); every other edit commits `spec` directly.
Item {
    id: editor

    property var spec: GradientPresets.presets[0].spec
    signal changed(var spec)
    signal committed()

    readonly property var _n: GradientPresets.normalize(spec)
    property int  selectedStop: 0
    property var  _preview: spec
    property string harmonyBase: "#3b82f6"
    property string harmonyMode: "analogous"

    onSpecChanged: {
        _preview = spec
        var n = GradientPresets.normalize(spec)
        if (selectedStop >= n.stops.length) selectedStop = n.stops.length - 1
        if (selectedStop < 0) selectedStop = 0
    }

    readonly property bool _hasAngle: _n.style === "linear" || _n.style === "reflected"
                                    || _n.style === "conic"

    // Commit a whole new spec (structural change) and notify + snapshot undo.
    function _commit(newSpec) {
        editor.spec = newSpec
        editor.changed(newSpec)
        editor.committed()
    }
    function _setField(key, val) {
        var s = GradientPresets.cloneSpec(editor.spec)
        s[key] = val
        _commit(s)
    }

    implicitHeight: col.implicitHeight

    ColumnLayout {
        id: col
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Theme.space.md

        // ── Preset gallery ──────────────────────────────────────────────
        Text {
            text: qsTr("Presets")
            color: Theme.color.textSecondary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.smallSize
            font.weight: Theme.font.weightMedium
        }
        ListView {
            Layout.fillWidth: true
            Layout.preferredHeight: 62
            orientation: ListView.Horizontal
            spacing: Theme.space.sm
            clip: true
            model: GradientPresets.presets
            boundsBehavior: Flickable.StopAtBounds
            delegate: Column {
                required property var modelData
                width: 76
                spacing: 3
                Rectangle {
                    width: 76; height: 40
                    radius: Theme.radius.sm
                    clip: true
                    color: "transparent"
                    border.color: Theme.color.borderStrong
                    border.width: 1
                    GradientFill {
                        anchors.fill: parent
                        anchors.margins: 1
                        spec: parent.modelData.spec
                        animate: false
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            editor.selectedStop = 0
                            editor._commit(GradientPresets.cloneSpec(parent.modelData.spec))
                        }
                    }
                }
                Text {
                    width: 76
                    text: parent.modelData.name
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.microSize
                    elide: Text.ElideRight
                    horizontalAlignment: Text.AlignHCenter
                }
            }
        }

        // ── Big preview ─────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 84
            radius: Theme.radius.sm
            clip: true
            color: "transparent"
            border.color: Theme.color.borderStrong
            border.width: 1
            GradientFill {
                anchors.fill: parent
                anchors.margins: 1
                spec: editor._preview
                animate: !SettingsService.reduceMotion
            }
        }

        // ── Draggable stop bar ──────────────────────────────────────────
        GradientBar {
            Layout.fillWidth: true
            stops: editor._n.stops
            selectedIndex: editor.selectedStop
            onSelected: function(i) { editor.selectedStop = i }
            onChanged: function(stops, commit) {
                var s = GradientPresets.cloneSpec(editor.spec)
                s.stops = stops
                if (commit) {
                    editor._commit(s)
                } else {
                    editor._preview = s      // live drag: preview only, keep pins stable
                    editor.changed(s)
                }
            }
        }
        Text {
            Layout.fillWidth: true
            text: qsTr("Drag pins to move · click the bar to add · drag a pin down to remove")
            color: Theme.color.textTertiary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.microSize
            wrapMode: Text.Wrap
        }

        // ── Selected-stop color + delete ────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space.sm
            ColorSwatchInput {
                Layout.fillWidth: true
                label: qsTr("Color")
                value: (editor._n.stops[editor.selectedStop]
                        ? editor._n.stops[editor.selectedStop].color : "#ffffff")
                onColorPicked: function(hex) {
                    var s = GradientPresets.cloneSpec(editor.spec)
                    if (editor.selectedStop < s.stops.length)
                        s.stops[editor.selectedStop].color = hex
                    editor.spec = s          // safe live: no pin drag active
                    editor.changed(s)
                }
                onCommitted: function(hex) { editor.committed() }
            }
            IconButton {
                iconName: "trash"
                enabled: editor._n.stops.length > 2
                onClicked: {
                    var s = GradientPresets.cloneSpec(editor.spec)
                    if (s.stops.length > 2 && editor.selectedStop < s.stops.length) {
                        s.stops.splice(editor.selectedStop, 1)
                        editor.selectedStop = Math.max(0, editor.selectedStop - 1)
                        editor._commit(s)
                    }
                }
            }
        }

        // ── Finish ──────────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space.md
            Text {
                text: qsTr("Finish")
                Layout.preferredWidth: 60
                color: Theme.color.textSecondary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                font.weight: Theme.font.weightMedium
            }
            SegmentedControl {
                Layout.fillWidth: true
                options: GradientPresets.finishes
                current: editor._n.finish
                onChanged: function(v) { editor._setField("finish", v) }
            }
        }

        // ── Style ───────────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space.md
            Text {
                text: qsTr("Style")
                Layout.preferredWidth: 60
                color: Theme.color.textSecondary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                font.weight: Theme.font.weightMedium
            }
            SegmentedControl {
                Layout.fillWidth: true
                options: GradientPresets.styles
                current: editor._n.style
                onChanged: function(v) { editor._setField("style", v) }
            }
        }

        // ── Direction (friendlier than a 0–360° dial) ───────────────────
        RowLayout {
            Layout.fillWidth: true
            visible: editor._hasAngle
            spacing: Theme.space.md
            Text {
                text: qsTr("Direction")
                Layout.preferredWidth: 60
                color: Theme.color.textSecondary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                font.weight: Theme.font.weightMedium
            }
            SegmentedControl {
                Layout.fillWidth: true
                options: [
                    { value: 90,  label: qsTr("Down") },
                    { value: 0,   label: qsTr("Across") },
                    { value: 45,  label: "↘" },
                    { value: 135, label: "↙" }
                ]
                current: editor._n.angle
                onChanged: function(v) { editor._setField("angle", v) }
            }
        }

        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

        // ── Harmony helper: one color → a matching gradient ─────────────
        Text {
            text: qsTr("Auto from one color")
            color: Theme.color.textSecondary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.smallSize
            font.weight: Theme.font.weightMedium
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space.sm
            ColorSwatchInput {
                Layout.fillWidth: true
                label: qsTr("Base")
                value: editor.harmonyBase
                onColorPicked: function(hex) { editor.harmonyBase = hex }
                onCommitted: function(hex) { editor.harmonyBase = hex }
            }
            Combobox {
                Layout.preferredWidth: 150
                searchable: false
                options: GradientPresets.harmonyModes
                value: {
                    var m = GradientPresets.harmonyModes
                    for (var i = 0; i < m.length; ++i)
                        if (m[i].value === editor.harmonyMode) return m[i].label
                    return m[0].label
                }
                onValueSelected: function(v) { editor.harmonyMode = v }
            }
        }
        PrimaryButton {
            Layout.fillWidth: true
            variant: "brand"
            iconName: "sparkles"
            text: qsTr("Generate gradient")
            onClicked: {
                editor.selectedStop = 0
                editor._commit(GradientPresets.harmony(editor.harmonyBase, editor.harmonyMode))
            }
        }
    }
}
