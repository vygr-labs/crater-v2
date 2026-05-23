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

            // ── TRANSITIONS ──────────────────────────────────────────────
            // Per-output transition between live items + between pages of the
            // same item. Style and duration are independently settable for
            // Primary and (in dual output mode) NDI — matching the per-output
            // theme pin pattern. SettingsService.reduceMotion remains the
            // global override; when on, every output collapses to "cut"
            // regardless of these picks.
            SettingsSectionHeader { title: qsTr("Transitions") }

            // ── Primary output: style ────────────────────────────────────
            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("Primary output style"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("How the audience screen moves between items"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
                }
                Combobox {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 220
                    searchable: false
                    options: [qsTr("Cut"), qsTr("Crossfade"), qsTr("Fade through black")]
                    // Map canonical token → display label. Anything unknown
                    // collapses to Crossfade so the picker never shows
                    // empty after a registry hand-edit.
                    value: {
                        switch (SettingsService.transitionStyleForPrimary) {
                            case "cut":       return qsTr("Cut")
                            case "fadeBlack": return qsTr("Fade through black")
                            default:          return qsTr("Crossfade")
                        }
                    }
                    onValueSelected: function(v) {
                        if (v === qsTr("Cut"))                  SettingsService.transitionStyleForPrimary = "cut"
                        else if (v === qsTr("Fade through black")) SettingsService.transitionStyleForPrimary = "fadeBlack"
                        else                                    SettingsService.transitionStyleForPrimary = "crossfade"
                    }
                }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            // ── Primary output: duration ─────────────────────────────────
            // Named presets rather than a numeric input: operators pick
            // "feel" not arithmetic, and the SettingsService setter clamps
            // to 0..1500 so any future hand-edit can't escape sanity.
            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("Primary output duration"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("How long each transition takes"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
                }
                Combobox {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 220
                    searchable: false
                    options: [qsTr("Instant"),
                              qsTr("Fast (150 ms)"),
                              qsTr("Normal (280 ms)"),
                              qsTr("Slow (500 ms)"),
                              qsTr("Very slow (1000 ms)")]
                    value: {
                        const ms = SettingsService.transitionDurationMsForPrimary
                        if (ms <= 0)    return qsTr("Instant")
                        if (ms <= 150)  return qsTr("Fast (150 ms)")
                        if (ms <= 280)  return qsTr("Normal (280 ms)")
                        if (ms <= 500)  return qsTr("Slow (500 ms)")
                        return qsTr("Very slow (1000 ms)")
                    }
                    onValueSelected: function(v) {
                        if (v === qsTr("Instant"))                 SettingsService.transitionDurationMsForPrimary = 0
                        else if (v === qsTr("Fast (150 ms)"))      SettingsService.transitionDurationMsForPrimary = 150
                        else if (v === qsTr("Normal (280 ms)"))    SettingsService.transitionDurationMsForPrimary = 280
                        else if (v === qsTr("Slow (500 ms)"))      SettingsService.transitionDurationMsForPrimary = 500
                        else                                       SettingsService.transitionDurationMsForPrimary = 1000
                    }
                }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            // ── NDI output: style (visible only in dual output mode) ────
            // Single mode means NDI grabs frames from the projection
            // window's scene — there is no separate NDI scene to apply a
            // distinct transition to, so the controls would be lying. Hide
            // entirely in single mode; the QtQuick.Layouts column collapses
            // the hidden Items automatically.
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 56
                visible: SettingsService.outputMode === "dual"
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("NDI output style"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Independent transition for the NDI broadcast"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
                }
                Combobox {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 220
                    searchable: false
                    options: [qsTr("Cut"), qsTr("Crossfade"), qsTr("Fade through black")]
                    value: {
                        switch (SettingsService.transitionStyleForNdi) {
                            case "cut":       return qsTr("Cut")
                            case "fadeBlack": return qsTr("Fade through black")
                            default:          return qsTr("Crossfade")
                        }
                    }
                    onValueSelected: function(v) {
                        if (v === qsTr("Cut"))                  SettingsService.transitionStyleForNdi = "cut"
                        else if (v === qsTr("Fade through black")) SettingsService.transitionStyleForNdi = "fadeBlack"
                        else                                    SettingsService.transitionStyleForNdi = "crossfade"
                    }
                }
            }
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Theme.color.borderSubtle
                visible: SettingsService.outputMode === "dual"
            }

            // ── NDI output: duration (visible only in dual output mode) ─
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 56
                visible: SettingsService.outputMode === "dual"
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("NDI output duration"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("How long the NDI transition takes"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
                }
                Combobox {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 220
                    searchable: false
                    options: [qsTr("Instant"),
                              qsTr("Fast (150 ms)"),
                              qsTr("Normal (280 ms)"),
                              qsTr("Slow (500 ms)"),
                              qsTr("Very slow (1000 ms)")]
                    value: {
                        const ms = SettingsService.transitionDurationMsForNdi
                        if (ms <= 0)    return qsTr("Instant")
                        if (ms <= 150)  return qsTr("Fast (150 ms)")
                        if (ms <= 280)  return qsTr("Normal (280 ms)")
                        if (ms <= 500)  return qsTr("Slow (500 ms)")
                        return qsTr("Very slow (1000 ms)")
                    }
                    onValueSelected: function(v) {
                        if (v === qsTr("Instant"))                 SettingsService.transitionDurationMsForNdi = 0
                        else if (v === qsTr("Fast (150 ms)"))      SettingsService.transitionDurationMsForNdi = 150
                        else if (v === qsTr("Normal (280 ms)"))    SettingsService.transitionDurationMsForNdi = 280
                        else if (v === qsTr("Slow (500 ms)"))      SettingsService.transitionDurationMsForNdi = 500
                        else                                       SettingsService.transitionDurationMsForNdi = 1000
                    }
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
