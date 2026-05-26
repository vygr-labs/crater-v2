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

    // Local error banner for the Fonts subsection at the bottom. Lives at
    // the root so the section header / Flickable can both reach it; the
    // 5s auto-clear matches the Themes tab's pattern so feedback is
    // transient but visible.
    property string _fontError: ""
    Timer {
        id: fontErrorClearTimer
        interval: 5000
        onTriggered: root._fontError = ""
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
                        switch (OutputService.transitionStyle("primary")) {
                            case "cut":       return qsTr("Cut")
                            case "fadeBlack": return qsTr("Fade through black")
                            default:          return qsTr("Crossfade")
                        }
                    }
                    onValueSelected: function(v) {
                        if (v === qsTr("Cut"))                  OutputService.setTransitionStyle("primary", "cut")
                        else if (v === qsTr("Fade through black")) OutputService.setTransitionStyle("primary", "fadeBlack")
                        else                                    OutputService.setTransitionStyle("primary", "crossfade")
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
                        const ms = OutputService.transitionDurationMs("primary")
                        if (ms <= 0)    return qsTr("Instant")
                        if (ms <= 150)  return qsTr("Fast (150 ms)")
                        if (ms <= 280)  return qsTr("Normal (280 ms)")
                        if (ms <= 500)  return qsTr("Slow (500 ms)")
                        return qsTr("Very slow (1000 ms)")
                    }
                    onValueSelected: function(v) {
                        if (v === qsTr("Instant"))                 OutputService.setTransitionDurationMs("primary", 0)
                        else if (v === qsTr("Fast (150 ms)"))      OutputService.setTransitionDurationMs("primary", 150)
                        else if (v === qsTr("Normal (280 ms)"))    OutputService.setTransitionDurationMs("primary", 280)
                        else if (v === qsTr("Slow (500 ms)"))      OutputService.setTransitionDurationMs("primary", 500)
                        else                                       OutputService.setTransitionDurationMs("primary", 1000)
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
                        switch (OutputService.transitionStyle("ndi")) {
                            case "cut":       return qsTr("Cut")
                            case "fadeBlack": return qsTr("Fade through black")
                            default:          return qsTr("Crossfade")
                        }
                    }
                    onValueSelected: function(v) {
                        if (v === qsTr("Cut"))                  OutputService.setTransitionStyle("ndi", "cut")
                        else if (v === qsTr("Fade through black")) OutputService.setTransitionStyle("ndi", "fadeBlack")
                        else                                    OutputService.setTransitionStyle("ndi", "crossfade")
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
                        const ms = OutputService.transitionDurationMs("ndi")
                        if (ms <= 0)    return qsTr("Instant")
                        if (ms <= 150)  return qsTr("Fast (150 ms)")
                        if (ms <= 280)  return qsTr("Normal (280 ms)")
                        if (ms <= 500)  return qsTr("Slow (500 ms)")
                        return qsTr("Very slow (1000 ms)")
                    }
                    onValueSelected: function(v) {
                        if (v === qsTr("Instant"))                 OutputService.setTransitionDurationMs("ndi", 0)
                        else if (v === qsTr("Fast (150 ms)"))      OutputService.setTransitionDurationMs("ndi", 150)
                        else if (v === qsTr("Normal (280 ms)"))    OutputService.setTransitionDurationMs("ndi", 280)
                        else if (v === qsTr("Slow (500 ms)"))      OutputService.setTransitionDurationMs("ndi", 500)
                        else                                       OutputService.setTransitionDurationMs("ndi", 1000)
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

            // ── FONTS ────────────────────────────────────────────────────
            // Manage operator-imported fonts (ARCHITECTURE.md §10.5).
            // Lives in the Projection section because fonts are part of
            // what the projection output renders — moving the management
            // here keeps every output-appearance lever in one tab.
            //
            // Lists everything registered through FontService.importFontFile
            // (the button below OR a previously imported theme bundle).
            // Removing a font unregisters it from QFontDatabase and deletes
            // the on-disk file; themes that referenced it fall back to a
            // system substitute on their next render. System / QRC fonts
            // (Funnel Sans, Lucide, Arial, Calibri, …) aren't listed —
            // they're outside this service's scope by design.
            SettingsSectionHeader { title: qsTr("Fonts") }

            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 64

                // Column anchored to the import button's left edge with
                // elide on both labels — keeps the long subtitle from
                // sliding under the button at narrow widths.
                Column {
                    anchors.left: parent.left
                    anchors.right: importFontButton.left
                    anchors.rightMargin: Theme.space.md
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    ElidedText {
                        text: qsTr("Manage fonts available to themes")
                        color: Theme.color.textPrimary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.bodySize
                        font.weight: Theme.font.weightMedium
                        width: parent.width
                    }
                    ElidedText {
                        text: qsTr("Imported fonts are available in every theme's font picker "
                                   + "and can be bundled into exported themes.")
                        color: Theme.color.textTertiary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                        width: parent.width
                    }
                }

                GhostButton {
                    id: importFontButton
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Import font…")
                    iconName: "type"
                    onClicked: {
                        const path = FileDialogService.chooseOpenFile(
                            qsTr("Import Font"),
                            [qsTr("Font Files (*.ttf *.otf)"),
                             qsTr("All Files (*.*)")])
                        if (!path || path.length === 0) return

                        const font = FontService.importFontFile(path)
                        if (font.id === 0) {
                            root._fontError = FontService.lastError()
                                           || qsTr("Font import failed")
                            fontErrorClearTimer.restart()
                        }
                    }
                }
            }

            // Transient error banner for font import failures.
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: visible ? 36 : 0
                Layout.topMargin: visible ? Theme.space.sm : 0
                visible: root._fontError.length > 0
                radius: Theme.radius.md
                color: Theme.color.liveSubtle
                border.color: Theme.color.live
                border.width: 1

                Text {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Theme.space.md
                    anchors.rightMargin: Theme.space.md
                    text: root._fontError
                    color: Theme.color.textPrimary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                    elide: Text.ElideRight
                }
            }

            // Empty state when no operator-imported fonts exist yet.
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 120
                Layout.topMargin: Theme.space.md
                visible: (FontService.allFonts || []).length === 0

                Column {
                    anchors.centerIn: parent
                    spacing: Theme.space.sm

                    AppIcon {
                        anchors.horizontalCenter: parent.horizontalCenter
                        name: "type"
                        color: Theme.color.textTertiary
                        size: Theme.icon.lg
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: qsTr("No imported fonts yet")
                        color: Theme.color.textSecondary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.bodySize
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: qsTr("Import a .ttf or .otf to make it available to themes")
                        color: Theme.color.textTertiary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                    }
                }
            }

            // Imported-font rows. Family name rendered in its OWN font so a
            // failed registration shows in the fallback face — an honest
            // visual signal without a separate validity column.
            Repeater {
                model: FontService.allFonts || []
                delegate: Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 56

                    Rectangle {
                        anchors.fill: parent
                        anchors.bottomMargin: 1
                        color: rowMa.containsMouse ? Theme.color.overlay : "transparent"

                        Column {
                            anchors.left: parent.left
                            anchors.right: removeFontButton.left
                            anchors.rightMargin: Theme.space.md
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2

                            ElidedText {
                                text: modelData.family
                                color: Theme.color.textPrimary
                                font.family: modelData.family
                                font.pixelSize: Theme.font.bodySize + 2
                                font.weight: Theme.font.weightMedium
                                width: parent.width
                            }
                            ElidedText {
                                // 8-char hash prefix uniquely identifies a
                                // row at our scale (hundreds of fonts at
                                // most) without hogging the line with a
                                // 64-char hex string.
                                text: qsTr("hash %1… · added %2")
                                    .arg(modelData.hash.substring(0, 8))
                                    .arg(Qt.formatDateTime(
                                        new Date(modelData.addedAt),
                                        "yyyy-MM-dd"))
                                color: Theme.color.textTertiary
                                font.family: Theme.font.monoFamily
                                font.pixelSize: Theme.font.smallSize - 1
                                width: parent.width
                            }
                        }

                        IconButton {
                            id: removeFontButton
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            iconName: "trash"
                            iconSize: Theme.icon.sm
                            onClicked: FontService.removeFont(modelData.id)
                        }

                        MouseArea {
                            id: rowMa
                            anchors.fill: parent
                            hoverEnabled: true
                            // Hover-only for the overlay tint; the trash
                            // button above captures clicks.
                        }

                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            height: 1
                            color: Theme.color.borderSubtle
                        }
                    }
                }
            }

            Item { Layout.fillWidth: true; Layout.preferredHeight: Theme.space.xl }
        }
    }
}
