import QtQuick
import QtQuick.Layouts

// Projection — output display, resolution, fade defaults, multi-output preview.
// Output display + Projection mode are wired to OutputService (single output
// today). Resolution is wired to SettingsService.outputResolution and
// persists; actual render-time enforcement (letterboxing / scaling to the
// chosen res) is a follow-up. Multi-output is a v1.1 preview.
Item {
    id: root

    property bool clearOnIdle: false

    // ── Transition preset helpers ────────────────────────────────────────
    // Per-output transitions are stored as a (kind, ms) pair on
    // SettingsService — the UI condenses the common combinations into
    // named presets so the operator never thinks in milliseconds. Anything
    // outside the named set (e.g. a value persisted by a future version
    // or hand-edited in the registry) round-trips as "Custom (N ms)" so
    // we never silently snap it to the nearest preset.
    readonly property var _transitionPresets: [
        qsTr("Cut (instant)"),
        qsTr("Quick (150 ms)"),
        qsTr("Standard (280 ms)"),
        qsTr("Long (500 ms)"),
        qsTr("Slow (800 ms)")
    ]

    function _presetFor(kind, ms) {
        if (kind === "cut")                       return qsTr("Cut (instant)")
        if (kind === "fade" && ms === 150)        return qsTr("Quick (150 ms)")
        if (kind === "fade" && ms === 280)        return qsTr("Standard (280 ms)")
        if (kind === "fade" && ms === 500)        return qsTr("Long (500 ms)")
        if (kind === "fade" && ms === 800)        return qsTr("Slow (800 ms)")
        return qsTr("Custom (%1 ms)").arg(ms)
    }

    function _applyPreset(output, preset) {
        var kind = "fade"
        var ms   = 280
        if      (preset === qsTr("Cut (instant)"))    { kind = "cut";  ms = 0   }
        else if (preset === qsTr("Quick (150 ms)"))   { kind = "fade"; ms = 150 }
        else if (preset === qsTr("Standard (280 ms)")){ kind = "fade"; ms = 280 }
        else if (preset === qsTr("Long (500 ms)"))    { kind = "fade"; ms = 500 }
        else if (preset === qsTr("Slow (800 ms)"))    { kind = "fade"; ms = 800 }
        else return
        if (output === "primary") {
            SettingsService.transitionForPrimary   = kind
            SettingsService.transitionMsForPrimary = ms
        } else if (output === "ndi") {
            SettingsService.transitionForNdi       = kind
            SettingsService.transitionMsForNdi     = ms
        } else if (output === "stage") {
            SettingsService.transitionForStage     = kind
            SettingsService.transitionMsForStage   = ms
        }
    }

    Flickable {
        anchors.fill: parent
        contentHeight: layout.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: layout
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Theme.space.xl
            anchors.rightMargin: Theme.space.xl
            anchors.topMargin: Theme.space.xxxl
            spacing: 0

            // ── OUTPUT ───────────────────────────────────────────────────
            SettingsSectionHeader { title: qsTr("Output"); first: true }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("Output display"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Which screen receives projection output"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
                }
                Combobox {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 240
                    searchable: false
                    options: OutputService.screens.map(function(s) {
                        return s.name + (s.isPrimary ? qsTr(" (primary)") : "")
                    })
                    value: {
                        const s = OutputService.screens[OutputService.selectedScreenIndex]
                        return s ? (s.name + (s.isPrimary ? qsTr(" (primary)") : "")) : ""
                    }
                    onValueSelected: function(v) {
                        for (let i = 0; i < OutputService.screens.length; i++) {
                            const s = OutputService.screens[i]
                            const label = s.name + (s.isPrimary ? qsTr(" (primary)") : "")
                            if (label === v) {
                                OutputService.selectedScreenIndex = i
                                return
                            }
                        }
                    }
                }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("Projection mode"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Windowed shows output in a movable preview window"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
                }
                Combobox {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 180
                    searchable: false
                    options: [qsTr("Fullscreen"), qsTr("Windowed")]
                    value: OutputService.projectionMode === OutputService.Windowed
                        ? qsTr("Windowed")
                        : qsTr("Fullscreen")
                    onValueSelected: function(v) {
                        OutputService.projectionMode = (v === qsTr("Windowed"))
                            ? OutputService.Windowed
                            : OutputService.Fullscreen
                    }
                }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            // Resolution — persisted via SettingsService.outputResolution.
            // Today the projection window always uses the destination
            // display's native geometry; a follow-up will letterbox /
            // scale theme content when this preference differs.
            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("Resolution"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Render canvas for theme content"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
                }
                Combobox {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 180
                    searchable: false
                    options: ["3840×2160", "2560×1440", "1920×1080", "1280×720", "1024×768"]
                    value: SettingsService.outputResolution
                    onValueSelected: function(v) { SettingsService.outputResolution = v }
                }
            }

            // ── MULTIPLE OUTPUTS (preview) ───────────────────────────────
            SettingsSectionHeader { title: qsTr("Multiple Outputs") }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 40
                radius: 0
                color: Theme.color.brandSubtle
                border.color: Theme.color.brand
                border.width: 1

                Row {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.space.md
                    anchors.rightMargin: Theme.space.md
                    spacing: Theme.space.sm

                    AppIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "info"
                        color: Theme.color.brand
                        size: Theme.icon.sm
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Multi-output (HDMI, NDI, stage monitor) ships in v1.1 — controls below are a preview.")
                        color: Theme.color.textSecondary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                    }
                }
            }

            // Output row — mockup. The first row mirrors the operator's
            // CURRENT single output so the layout looks live, but its
            // controls are still disabled (the configuration lives in
            // the OUTPUT section above for now). Subsequent rows are
            // entirely aspirational.
            Item {
                Layout.fillWidth: true
                Layout.topMargin: Theme.space.md
                Layout.preferredHeight: 52

                Row {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.space.md

                    AppIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "monitor"
                        color: Theme.color.textSecondary
                        size: Theme.icon.md
                    }
                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2
                        Text { text: qsTr("Primary HDMI"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                        Text {
                            text: {
                                const s = OutputService.screens[OutputService.selectedScreenIndex]
                                return s ? s.name : qsTr("No display")
                            }
                            color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize
                        }
                    }
                }
                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.space.md

                    Badge {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Live")
                        background: Theme.color.brandSubtle
                        foreground: Theme.color.brand
                    }
                }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 52

                Row {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.space.md
                    opacity: 0.45

                    AppIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "radio"
                        color: Theme.color.textSecondary
                        size: Theme.icon.md
                    }
                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2
                        Text { text: qsTr("NDI Broadcast"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                        Text { text: qsTr("Network output for OBS / streaming"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
                    }
                }
                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.space.md

                    Badge {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Soon")
                        background: Theme.color.overlay
                        foreground: Theme.color.textTertiary
                    }
                    ToggleSwitch {
                        anchors.verticalCenter: parent.verticalCenter
                        value: false
                        opacity: 0.45
                        enabled: false
                        onToggled: { }
                    }
                }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 52

                Row {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.space.md
                    opacity: 0.45

                    AppIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "tv"
                        color: Theme.color.textSecondary
                        size: Theme.icon.md
                    }
                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2
                        Text { text: qsTr("Stage Monitor"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                        Text { text: qsTr("Confidence display for worship leader"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
                    }
                }
                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.space.md

                    Badge {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Soon")
                        background: Theme.color.overlay
                        foreground: Theme.color.textTertiary
                    }
                    ToggleSwitch {
                        anchors.verticalCenter: parent.verticalCenter
                        value: false
                        opacity: 0.45
                        enabled: false
                        onToggled: { }
                    }
                }
            }

            // "Add output" affordance — disabled in v1, indicates the
            // direction the multi-output story is heading.
            Item {
                Layout.fillWidth: true
                Layout.topMargin: Theme.space.md
                Layout.preferredHeight: 36

                Row {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.space.sm
                    opacity: 0.45

                    AppIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "plus"
                        color: Theme.color.brand
                        size: Theme.icon.sm
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Add output")
                        color: Theme.color.brand
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                        font.weight: Theme.font.weightMedium
                    }
                }
            }

            // ── TRANSITIONS ──────────────────────────────────────────────
            // Per-output crossfade between live states (lyric → scripture
            // → image → logo, etc.). The audience-facing projection and
            // the NDI broadcast can carry different transitions when dual
            // output is on; in single mode NDI mirrors the projection
            // window's scene graph, so its row collapses to "inherits
            // Primary." Stage Monitor is a v1.1 multi-output slot.
            SettingsSectionHeader { title: qsTr("Transitions") }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 40
                radius: 0
                color: Theme.color.brandSubtle
                border.color: Theme.color.brand
                border.width: 1

                Row {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.space.md
                    anchors.rightMargin: Theme.space.md
                    spacing: Theme.space.sm

                    AppIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "info"
                        color: Theme.color.brand
                        size: Theme.icon.sm
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Live content crossfades between lyrics, scripture, images, and the logo overlay. Reduce Motion (Appearance) overrides every output to Cut.")
                        color: Theme.color.textSecondary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                    }
                }
            }

            // Primary HDMI row — always editable. The setting drives the
            // ProjectionScene instantiated inside ProjectionWindow.qml.
            Item { Layout.fillWidth: true; Layout.topMargin: Theme.space.md; Layout.preferredHeight: 56
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Row {
                        spacing: Theme.space.sm
                        AppIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: "monitor"; color: Theme.color.textSecondary; size: Theme.icon.sm
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: qsTr("Primary HDMI"); color: Theme.color.textPrimary
                            font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize
                            font.weight: Theme.font.weightMedium
                        }
                    }
                    Text {
                        text: qsTr("Crossfade on the audience-facing projection")
                        color: Theme.color.textTertiary
                        font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize
                    }
                }
                Combobox {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 220
                    searchable: false
                    options: root._transitionPresets
                    value: root._presetFor(SettingsService.transitionForPrimary,
                                           SettingsService.transitionMsForPrimary)
                    onValueSelected: function(v) { root._applyPreset("primary", v) }
                }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            // NDI row — editable only in dual mode. In single mode the
            // NDI scene grabs frames from the projection window's scene
            // graph, so its transitions are physically the same as
            // Primary's. We disable the picker rather than hide it so
            // the operator can see the inherited value.
            Item {
                id: ndiRow
                Layout.fillWidth: true
                Layout.preferredHeight: 56
                readonly property bool _dual: SettingsService.outputMode === "dual"

                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Row {
                        spacing: Theme.space.sm
                        opacity: ndiRow._dual ? 1.0 : 0.55
                        AppIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: "radio"; color: Theme.color.textSecondary; size: Theme.icon.sm
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: qsTr("NDI Broadcast"); color: Theme.color.textPrimary
                            font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize
                            font.weight: Theme.font.weightMedium
                        }
                    }
                    Text {
                        opacity: ndiRow._dual ? 1.0 : 0.55
                        text: ndiRow._dual
                            ? qsTr("Independent crossfade on the NDI scene")
                            : qsTr("Inherits Primary while output mode is Single")
                        color: Theme.color.textTertiary
                        font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize
                    }
                }
                Combobox {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 220
                    searchable: false
                    enabled: ndiRow._dual
                    opacity: ndiRow._dual ? 1.0 : 0.55
                    options: root._transitionPresets
                    value: ndiRow._dual
                        ? root._presetFor(SettingsService.transitionForNdi,
                                          SettingsService.transitionMsForNdi)
                        : root._presetFor(SettingsService.transitionForPrimary,
                                          SettingsService.transitionMsForPrimary)
                    onValueSelected: function(v) { root._applyPreset("ndi", v) }
                }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            // Stage Monitor row — v1.1 placeholder. Mirrors the existing
            // Multi-Output section's "Soon" badging so the operator
            // immediately recognises the parallel between the two.
            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2; opacity: 0.45
                    Row {
                        spacing: Theme.space.sm
                        AppIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: "tv"; color: Theme.color.textSecondary; size: Theme.icon.sm
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: qsTr("Stage Monitor"); color: Theme.color.textPrimary
                            font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize
                            font.weight: Theme.font.weightMedium
                        }
                    }
                    Text {
                        text: qsTr("Available with the v1.1 multi-output pipeline")
                        color: Theme.color.textTertiary
                        font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize
                    }
                }
                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.space.md

                    Badge {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Soon")
                        background: Theme.color.overlay
                        foreground: Theme.color.textTertiary
                    }
                }
            }

            // ── DEFAULTS ─────────────────────────────────────────────────
            SettingsSectionHeader { title: qsTr("Defaults") }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("Show logo by default"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Display logo when output is otherwise blank"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
                }
                ToggleSwitch { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    value: SettingsService.showLogoByDefault
                    onToggled: SettingsService.showLogoByDefault = !SettingsService.showLogoByDefault }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("Clear output when idle"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Blank text after a period of inactivity"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
                }
                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.space.md

                    Badge {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Soon")
                        background: Theme.color.overlay
                        foreground: Theme.color.textTertiary
                    }
                    ToggleSwitch {
                        anchors.verticalCenter: parent.verticalCenter
                        value: root.clearOnIdle
                        opacity: 0.45
                        enabled: false
                        onToggled: { }
                    }
                }
            }

            Item { Layout.fillWidth: true; Layout.preferredHeight: Theme.space.xl }
        }
    }
}
