import QtQuick
import QtQuick.Layouts

// Projection — output display, fade defaults, multi-output.
// Output display + Projection mode are wired to OutputService.
//
// There is no Resolution row. SettingsService.outputResolution still
// persists, but nothing renders at it: the projection always uses the
// display's native geometry. A control that changed nothing read as broken,
// so it stays out of the UI until render-time scaling exists (issue #18).
Item {
    id: root

    property bool clearOnIdle: false

    // ── Multi-output helpers ────────────────────────────────────────────
    // Every output that owns a window and is not the audience projector.
    // NDI is excluded because it renders to a network stream, not a display,
    // and is configured on its own settings page; primary is excluded
    // because the Output section at the top of this page already owns it.
    //
    // Bound straight to OutputService.outputs — a Q_PROPERTY with a NOTIFY —
    // so every row re-reads on any registry change without a bump counter.
    // Safe here (and not in Main.qml, where the same binding would rebuild
    // live output windows) because rebuilding a settings row costs nothing.
    readonly property var _extraOutputs: {
        const list = OutputService.outputs
        let out = []
        for (let i = 0; i < list.length; i++) {
            const b = list[i]
            if (b.id === "primary" || b.role === "ndi") continue
            out.push(b)
        }
        return out
    }

    readonly property int _screenCount: OutputService.screens.length

    function _screenLabel(i) {
        const list = OutputService.screens
        if (i < 0 || i >= list.length) return qsTr("Not assigned")
        const s = list[i]
        return s.name + (s.isPrimary ? qsTr(" (primary)") : "")
    }

    // "Not assigned" is a real, selectable choice, not just an empty state:
    // it parks an output without deleting it, so a stage monitor used only
    // at Christmas keeps its theme pins and transition tuning through the
    // rest of the year.
    readonly property var _screenOptions: {
        let out = [{ label: qsTr("Not assigned"), value: "-1" }]
        const list = OutputService.screens
        for (let i = 0; i < list.length; i++) {
            out.push({ label: list[i].name + (list[i].isPrimary ? qsTr(" (primary)") : ""),
                       value: String(i) })
        }
        return out
    }


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

            SettingRow {
                title: qsTr("Output display")
                description: qsTr("Which screen receives projection output")
                Combobox {
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

            SettingRow {
                title: qsTr("Projection mode")
                description: qsTr("Windowed shows output in a movable preview window")
                Combobox {
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

            // Taskbar / Alt-Tab presence for the projection window. Off routes
            // it through Qt.Tool so a fixed projector stops showing up in the
            // switcher — at the cost of the single-screen "click the taskbar
            // entry to surface it" route, hence the honest subtitle.
            SettingRow {
                title: qsTr("Show projection in Alt-Tab")
                description: qsTr("Also gives the projection a taskbar button; off hides it from both")
                ToggleSwitch {
                    value: SettingsService.projectionInAltTab
                    onToggled: SettingsService.projectionInAltTab = !SettingsService.projectionInAltTab }
            }

            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            // Picks between the two arrangements for an output that shares
            // the console's display: the corner preview on top (off) and the
            // EasyWorship 7 style full-size output stacked directly under the
            // console (on). Applies with one display, or with several when the
            // output display above is the console's own screen. Not dimmed on
            // a desk where the output has its own screen: an operator
            // configuring this there is usually preparing for a one-monitor
            // venue. The subtitle explains the way back, the part people get
            // stuck on.
            SettingRow {
                title: qsTr("Same screen as the console: show output behind it")
                description: qsTr("The output fills the screen behind the console and shows wherever the console does not cover it. Click the output to bring it to the front. Click it again or press Esc to go back to the console. Off shows a small preview in the corner instead.")
                ToggleSwitch {
                    value: SettingsService.projectionBehindConsole
                    onToggled: SettingsService.projectionBehindConsole = !SettingsService.projectionBehindConsole }
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
            SettingRow {
                title: qsTr("Primary output style")
                description: qsTr("How the audience screen moves between items")
                Combobox {
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
            SettingRow {
                title: qsTr("Primary output duration")
                description: qsTr("How long each transition takes")
                Combobox {
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
            SettingRow {
                visible: SettingsService.outputMode === "dual"
                title: qsTr("NDI output style")
                description: qsTr("Independent transition for the NDI broadcast")
                Combobox {
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
            SettingRow {
                visible: SettingsService.outputMode === "dual"
                title: qsTr("NDI output duration")
                description: qsTr("How long the NDI transition takes")
                Combobox {
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

            // ── MULTIPLE OUTPUTS ─────────────────────────────────────────
            // Was a set of disabled mockups labelled "v1.1 preview". The
            // registry behind them (OutputService) was always real; what was
            // missing was a per-output DISPLAY assignment, so no second
            // window had anywhere to go. Now that each OutputBinding carries
            // its own screen, enabled flag and content mode, these rows drive
            // the registry directly and Main.qml instantiates a window per
            // enabled row.
            SettingsSectionHeader { title: qsTr("Multiple Outputs") }

            // Single-display machines can still configure outputs — an
            // operator sets the church up on a laptop midweek — they just
            // cannot USE them, so say so once here rather than leaving every
            // row to look broken.
            Rectangle {
                visible: root._screenCount <= 1
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
                        width: parent.width - Theme.icon.sm - Theme.space.sm * 2
                        text: qsTr("Only one display is connected. Extra outputs show as a small corner preview until a second screen is plugged in.")
                        color: Theme.color.textSecondary
                        elide: Text.ElideRight
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                    }
                }
            }

            // Primary — listed for completeness so this section answers
            // "what is Crater driving right now?" in one place, but not
            // editable here: its screen and window mode are the Output
            // section at the top of this page, and duplicating those
            // controls would give the operator two places to change one
            // thing.
            Item {
                Layout.fillWidth: true
                Layout.topMargin: Theme.space.md
                Layout.preferredHeight: Math.max(primaryIdentity.implicitHeight, primaryScreenLabel.implicitHeight)
                                        + Theme.space.sm * 2

                Row {
                    id: primaryIdentity
                    anchors.left: parent.left
                    anchors.right: primaryScreenLabel.left
                    anchors.rightMargin: Theme.space.lg
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.space.md

                    AppIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "monitor"
                        color: Theme.color.brand
                        size: Theme.icon.md
                    }
                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - Theme.icon.md - parent.spacing
                        spacing: 2
                        Text {
                            width: parent.width
                            wrapMode: Text.WordWrap
                            text: qsTr("Primary Output")
                            color: Theme.color.textPrimary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.bodySize
                            font.weight: Theme.font.weightMedium
                        }
                        Text {
                            width: parent.width
                            wrapMode: Text.WordWrap
                            text: qsTr("Audience screen — configured under Output above")
                            color: Theme.color.textTertiary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.smallSize
                        }
                    }
                }

                Text {
                    id: primaryScreenLabel
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: root._screenLabel(OutputService.selectedScreenIndex)
                    color: Theme.color.textSecondary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            // ── One row per extra output ─────────────────────────────────
            Repeater {
                model: root._extraOutputs

                delegate: Item {
                    id: outRow
                    Layout.fillWidth: true
                    // Height follows the content: the identity column wraps
                    // beside the controls, plus the warning line when shown.
                    Layout.preferredHeight: Theme.space.sm
                                            + Math.max(outIdentity.implicitHeight, outControls.implicitHeight)
                                            + (outRow._warning.length > 0
                                               ? Theme.space.sm + outWarning.implicitHeight : 0)
                                            + Theme.space.sm + 1

                    readonly property string _id: modelData.id
                    readonly property bool   _isStageMode: modelData.contentMode === "stage"
                    // Built-ins cannot be unregistered (OutputService refuses),
                    // so the row must not offer it.
                    readonly property bool   _removable: modelData.id !== "stage"

                    // One warning line, most-actionable first. Order matters:
                    // an output on the console screen is a worse problem than
                    // an unassigned one, because the unassigned output is
                    // simply dark whereas the console one covers the controls.
                    readonly property string _warning: {
                        if (!modelData.enabled) return ""
                        const idx = modelData.screenIndex
                        if (idx < 0) {
                            return modelData.screenName.length > 0
                                ? qsTr("Display \"%1\" is not connected — this output is dark until it returns.")
                                      .arg(modelData.screenName)
                                : qsTr("No display assigned — pick one for this output to appear.")
                        }
                        const screens = OutputService.screens
                        if (idx < screens.length && screens[idx].isPrimary
                            && root._screenCount > 1) {
                            return qsTr("This is the screen the console is on. The output will stay behind the console rather than cover it.")
                        }
                        if (OutputService.screenIsContested(modelData.id, idx)) {
                            return qsTr("Another output is already using this display.")
                        }
                        return ""
                    }

                    Row {
                        id: outIdentity
                        anchors.left: parent.left
                        anchors.right: outControls.left
                        anchors.rightMargin: Theme.space.lg
                        anchors.top: parent.top
                        anchors.topMargin: Theme.space.sm
                        spacing: Theme.space.md

                        AppIcon {
                            anchors.verticalCenter: outName.verticalCenter
                            name: outRow._isStageMode ? "tv" : "monitor"
                            color: modelData.enabled ? Theme.color.textSecondary
                                                     : Theme.color.textTertiary
                            size: Theme.icon.md
                        }

                        Column {
                            id: outName
                            spacing: 2
                            width: parent.width - Theme.icon.md - Theme.space.md

                            // Editable in place rather than behind a rename
                            // dialog: a second modal opened from inside the
                            // settings modal would replace it (AppState holds
                            // one activeModal), closing the page the operator
                            // is working on.
                            TextInput {
                                id: nameInput
                                width: parent.width
                                clip: true
                                text: modelData.displayName
                                color: Theme.color.textPrimary
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.bodySize
                                font.weight: Theme.font.weightMedium
                                selectByMouse: true
                                onEditingFinished: OutputService.setDisplayName(outRow._id, text)
                            }
                            Text {
                                width: parent.width
                                wrapMode: Text.WordWrap
                                text: outRow._isStageMode
                                        ? qsTr("Presenter view — live text, speaker notes, what is next")
                                        : qsTr("Mirrors the audience render, with its own theme and transition")
                                color: Theme.color.textTertiary
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.smallSize
                            }
                        }
                    }

                    Row {
                        id: outControls
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.topMargin: Theme.space.sm
                        spacing: Theme.space.sm

                        SegmentedControl {
                            anchors.verticalCenter: screenPicker.verticalCenter
                            width: 130
                            height: 28
                            options: [
                                { value: "mirror", label: qsTr("Mirror") },
                                { value: "stage",  label: qsTr("Stage")  }
                            ]
                            current: modelData.contentMode
                            onChanged: function(v) { OutputService.setContentMode(outRow._id, v) }
                        }

                        Combobox {
                            id: screenPicker
                            width: 200
                            searchable: false
                            options: root._screenOptions
                            value: root._screenLabel(modelData.screenIndex)
                            onValueSelected: function(v) {
                                const n = parseInt(v, 10)
                                OutputService.setScreenIndexFor(outRow._id, isNaN(n) ? -1 : n)
                            }
                        }

                        ToggleSwitch {
                            anchors.verticalCenter: screenPicker.verticalCenter
                            value: modelData.enabled
                            onToggled: OutputService.setOutputEnabled(outRow._id, !modelData.enabled)
                        }

                        Rectangle {
                            anchors.verticalCenter: screenPicker.verticalCenter
                            visible: outRow._removable
                            width: 28; height: 28
                            radius: 0
                            // live / liveSubtle is the app-wide destructive
                            // pair (see MenuRow) -- there is no separate
                            // danger token.
                            color: removeMa.containsMouse ? Theme.color.liveSubtle : "transparent"
                            Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

                            AppIcon {
                                anchors.centerIn: parent
                                name: "trash"
                                color: removeMa.containsMouse ? Theme.color.live
                                                              : Theme.color.textTertiary
                                size: Theme.icon.sm
                            }
                            MouseArea {
                                id: removeMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: OutputService.unregisterOutput(outRow._id)
                            }
                        }
                    }

                    Row {
                        id: outWarning
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: Theme.space.sm
                        spacing: Theme.space.sm
                        visible: outRow._warning.length > 0

                        AppIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: "info"
                            color: Theme.color.warning
                            size: Theme.icon.sm
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - Theme.icon.sm - Theme.space.sm
                            text: outRow._warning
                            color: Theme.color.textTertiary
                            elide: Text.ElideRight
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.smallSize
                        }
                    }

                    Rectangle {
                        anchors.bottom: parent.bottom
                        anchors.left: parent.left
                        anchors.right: parent.right
                        height: 1
                        color: Theme.color.borderSubtle
                    }
                }
            }

            // ── Add output ───────────────────────────────────────────────
            // Registers immediately with a generated name and no display,
            // rather than asking for a name first: AppState holds a single
            // activeModal, so a naming dialog opened from here would replace
            // the settings page the operator is standing on. The new row
            // arrives with its name editable in place and no screen assigned,
            // so nothing appears anywhere until they choose one.
            Item {
                Layout.fillWidth: true
                Layout.topMargin: Theme.space.md
                Layout.preferredHeight: 36

                Row {
                    id: addRow
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.space.sm

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

                MouseArea {
                    anchors.left: addRow.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: addRow.width
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        OutputService.registerOutput(
                            "projection",
                            qsTr("Output %1").arg(root._extraOutputs.length + 2))
                    }
                }
            }

            // ── DEFAULTS ─────────────────────────────────────────────────
            SettingsSectionHeader { title: qsTr("Defaults") }

            SettingRow {
                title: qsTr("Show logo by default")
                description: qsTr("Display logo when output is otherwise blank")
                ToggleSwitch {
                    value: SettingsService.showLogoByDefault
                    onToggled: SettingsService.showLogoByDefault = !SettingsService.showLogoByDefault }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            SettingRow {
                title: qsTr("Clear output when idle")
                description: qsTr("Blank text after a period of inactivity")
                Row {
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

            SettingRow {
                title: qsTr("Manage fonts available to themes")
                description: qsTr("Imported fonts are available in every theme's font picker "
                                  + "and can be bundled into exported themes.")

                GhostButton {
                    id: importFontButton
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
