import QtQuick
import Crater

// Themes tab — visual presets for projection text rendering.
// Backed by ThemeService.allThemes (QList<Theme> value-types); each tile
// previews the theme's node graph via ThemePreview.
//
// Tokens shape (v2): see qt/core/src/db/migrations/app/V003__theme_nodes.sql.
Item {
    id: root

    // Right-pane background — same `bgContent` as ScriptureTab / SongsTab
    // so the tab area reads consistently across the library.
    Rectangle {
        anchors.fill: parent
        color: Theme.color.bgContent
        z: -1
    }

    // ── Filter + defaults state ─────────────────────────────────────────
    // kindFilter narrows the grid to a single kind ("song" | "scripture" |
    // "presentation") or shows everything ("all"). Local to the tab; resets
    // on app restart.
    property string kindFilter: "all"

    // Mirror of the user-selected default theme id per kind. Updated on
    // ThemeService.defaultsChanged so each tile's DEFAULT badge rebinds
    // without polling defaultFor() on every paint.
    // Also refreshed on allThemesChanged because deleting the active default
    // shifts the resolver to the first built-in of that kind.
    property var _defaultIds: ({ song: 0, scripture: 0, presentation: 0 })

    function _refreshDefaults() {
        _defaultIds = {
            song:         ThemeService.defaultFor("song").id         || 0,
            scripture:    ThemeService.defaultFor("scripture").id    || 0,
            presentation: ThemeService.defaultFor("presentation").id || 0
        }
    }

    Component.onCompleted: _refreshDefaults()

    Connections {
        target: ThemeService
        function onDefaultsChanged()  { root._refreshDefaults() }
        function onAllThemesChanged() { root._refreshDefaults() }
    }

    // Composes the sidebar search query (TabSearchBar writes to
    // AppState.searchText.themes) with the kind chip filter. Name matching is
    // case-insensitive substring — same shape as the songs/scripture tabs.
    readonly property string _searchQuery:
        (AppState.searchText.themes || "").toLowerCase().trim()

    readonly property var filteredThemes: {
        const all  = ThemeService.allThemes
        const q    = _searchQuery
        const kind = kindFilter
        return all.filter(function(t) {
            if (kind !== "all" && t.kind !== kind) return false
            if (q.length > 0 && t.name.toLowerCase().indexOf(q) < 0) return false
            return true
        })
    }

    // ── Import / export feedback surface ────────────────────────────────
    // Two parallel banners:
    //   _importError — red, transient (5s). Catastrophic failures: import
    //                  refused, export failed, font file rejected.
    //   _statusMessage — neutral, sticky until dismissed. Free-form text.
    //                    Used for two cases that share the same surface:
    //                    (a) per-asset warnings on a best-effort theme
    //                    import; (b) "imported font: X" confirmations
    //                    that would otherwise leave the user wondering
    //                    whether the click did anything.
    property string _importError: ""
    property string _statusMessage: ""

    Timer {
        id: errorClearTimer
        interval: 5000
        onTriggered: root._importError = ""
    }

    // Watch AppState for export-failure messages from ExportThemeDialog.
    // The dialog stashes them there because it doesn't own a banner of
    // its own — keeps the error surface concentrated in this tab.
    Connections {
        target: AppState
        function onLastThemeExportErrorChanged() {
            if (AppState.lastThemeExportError.length > 0) {
                root._importError = AppState.lastThemeExportError
                AppState.lastThemeExportError = ""
                errorClearTimer.restart()
            }
        }
    }

    // ── Header: filter chips (left) + Import / New theme (right) ────────
    Row {
        id: filterRow
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.margins: Theme.space.lg
        spacing: Theme.space.sm
        z: 1

        GhostButton {
            text: qsTr("All")
            active: root.kindFilter === "all"
            onClicked: root.kindFilter = "all"
        }
        GhostButton {
            text: qsTr("Songs")
            iconName: Theme.scheduleKindIcon("song")
            active: root.kindFilter === "song"
            onClicked: root.kindFilter = "song"
        }
        GhostButton {
            text: qsTr("Scriptures")
            iconName: Theme.scheduleKindIcon("scripture")
            active: root.kindFilter === "scripture"
            onClicked: root.kindFilter = "scripture"
        }
        GhostButton {
            text: qsTr("Presentations")
            iconName: Theme.scheduleKindIcon("presentation")
            active: root.kindFilter === "presentation"
            onClicked: root.kindFilter = "presentation"
        }
    }

    Row {
        id: header
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: Theme.space.lg
        spacing: Theme.space.sm
        z: 1

        // Import a redistributable font file (.ttf / .otf) so subsequent
        // theme exports can bundle it. See ARCHITECTURE.md §10.5 + the
        // FontService re-registration model. Bypasses the bundle path —
        // this is the operator's deliberate consent to add a font from
        // outside the QRC/system set.
        GhostButton {
            text: qsTr("Import font")
            iconName: "type"
            onClicked: {
                const path = FileDialogService.chooseOpenFile(
                    qsTr("Import Font"),
                    [qsTr("Font Files (*.ttf *.otf)"),
                     qsTr("All Files (*.*)")])
                if (!path || path.length === 0) return

                const font = FontService.importFontFile(path)
                if (font.id === 0) {
                    root._importError = FontService.lastError()
                                     || qsTr("Font import failed")
                    errorClearTimer.restart()
                    return
                }
                // Success — give visible confirmation. Sticky banner so
                // the operator notices even if they were looking
                // elsewhere when the dialog closed.
                root._statusMessage =
                    qsTr("Imported font: %1").arg(font.family)
            }
        }
        GhostButton {
            text: qsTr("Import theme")
            iconName: "upload"
            onClicked: {
                const path = FileDialogService.chooseOpenFile(
                    qsTr("Import Theme"),
                    [qsTr("Crater Theme (*.craterheme)"), qsTr("All Files (*.*)")])
                if (!path || path.length === 0) return

                // Returns a ThemeImportReport (Q_GADGET). themeId === 0 is
                // a catastrophic failure; warnings are best-effort issues
                // on a successful import (e.g., one bundled font failed).
                const report = ThemeService.importThemeFile(path)
                if (report.themeId === 0) {
                    root._importError = report.errorMessage
                                     || ThemeService.lastImportError()
                                     || qsTr("Import failed")
                    errorClearTimer.restart()
                    return
                }
                if (report.mediaWarnings.length > 0
                    || report.fontWarnings.length > 0) {
                    const lines = report.mediaWarnings
                                  .concat(report.fontWarnings)
                    root._statusMessage =
                        qsTr("Import succeeded with warnings:") + "\n"
                        + lines.join("\n")
                }
            }
        }
        GhostButton {
            id: newThemeBtn
            text: qsTr("New theme")
            iconName: "plus"
            // Kind picker — opens a context menu offering one entry per kind.
            // Anchored bottom-right of the button (dx: -menuWidth) so the menu
            // doesn't fall off the right edge of the tab.
            onClicked: {
                AppState.openContextMenuAt(newThemeBtn,
                    newThemeBtn.width, newThemeBtn.height,
                    [
                        { label: qsTr("Song theme"),
                          iconName: Theme.scheduleKindIcon("song"),
                          action: function() { AppState.openThemeEditor(-1, "song") } },
                        { label: qsTr("Scripture theme"),
                          iconName: Theme.scheduleKindIcon("scripture"),
                          action: function() { AppState.openThemeEditor(-1, "scripture") } },
                        { label: qsTr("Presentation theme"),
                          iconName: Theme.scheduleKindIcon("presentation"),
                          action: function() { AppState.openThemeEditor(-1, "presentation") } }
                    ],
                    { dx: -220 })
            }
        }
    }

    // ── Import error bar (between header rows and grid) ─────────────────
    // Height collapses to 0 when no error so the grid sits flush against
    // filterRow.bottom in the common case.
    Rectangle {
        id: errorBar
        anchors.top: filterRow.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Theme.space.lg
        anchors.rightMargin: Theme.space.lg
        anchors.topMargin: visible ? Theme.space.sm : 0
        height: visible ? 36 : 0
        visible: root._importError.length > 0
        radius: Theme.radius.md
        color: Theme.color.liveSubtle
        border.color: Theme.color.live
        border.width: 1
        z: 1

        Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Theme.space.md
            spacing: Theme.space.sm

            AppIcon {
                name: "alert-triangle"
                color: Theme.color.live
                size: Theme.icon.sm
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                text: root._importError
                color: Theme.color.textPrimary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        IconButton {
            iconName: "x"
            iconSize: Theme.icon.sm
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.rightMargin: Theme.space.sm
            onClicked: root._importError = ""
        }
    }

    // ── Status banner (warnings + neutral confirmations) ────────────────
    // Sticky — persists until dismissed, so partial-failure warnings
    // don't disappear before they're read and font-import confirmations
    // stay visible for the operator to notice.
    Rectangle {
        id: statusBar
        anchors.top: errorBar.visible ? errorBar.bottom : filterRow.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Theme.space.lg
        anchors.rightMargin: Theme.space.lg
        anchors.topMargin: visible ? Theme.space.sm : 0
        height: visible ? Math.min(120, statusText.implicitHeight + Theme.space.md * 2) : 0
        visible: root._statusMessage.length > 0
        radius: Theme.radius.md
        color: Theme.color.overlay
        border.color: Theme.color.borderStrong
        border.width: 1
        z: 1

        Row {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.leftMargin: Theme.space.md
            anchors.topMargin: Theme.space.md
            spacing: Theme.space.sm
            width: parent.width - Theme.space.md - Theme.space.xl

            AppIcon {
                name: "info"
                color: Theme.color.textSecondary
                size: Theme.icon.sm
            }
            Text {
                id: statusText
                width: parent.width - Theme.icon.sm - Theme.space.sm
                text: root._statusMessage
                color: Theme.color.textSecondary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                wrapMode: Text.WordWrap
                lineHeight: 1.35
            }
        }

        IconButton {
            iconName: "x"
            iconSize: Theme.icon.sm
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.rightMargin: Theme.space.sm
            anchors.topMargin: Theme.space.sm
            onClicked: root._statusMessage = ""
        }
    }

    // ── Empty states ────────────────────────────────────────────────────
    // Two variants: "no themes at all" vs "nothing in this filter". The
    // second is recoverable (switch filter), the first needs creation.
    // Three empty-state variants depending on what's narrowing the grid:
    //   1. DB has no themes        → "No themes yet"
    //   2. Search has no matches   → "No themes match \"…\""
    //   3. Kind filter has no rows → "No <kind> themes"
    EmptyState {
        anchors.fill: parent
        visible: root.filteredThemes.length === 0
        iconName: "palette"
        title: {
            if (ThemeService.allThemes.length === 0) return qsTr("No themes yet")
            if (root._searchQuery.length > 0)
                return qsTr("No themes match \"%1\"").arg(root._searchQuery)
            return qsTr("No %1 themes").arg(root.kindFilter)
        }
        body: {
            if (ThemeService.allThemes.length === 0)
                return qsTr("Create a custom theme or import one from a file")
            if (root._searchQuery.length > 0)
                return qsTr("Try a different search term, or clear it from the sidebar")
            return qsTr("Create a new one, or switch the filter to All")
        }
    }

    // ── Grid ────────────────────────────────────────────────────────────
    GridView {
        id: grid
        anchors.top: statusBar.visible ? statusBar.bottom
                   : errorBar.visible  ? errorBar.bottom
                                       : filterRow.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: Theme.space.lg
        anchors.rightMargin: Theme.space.lg
        anchors.bottomMargin: Theme.space.lg
        anchors.topMargin: Theme.space.sm
        visible: root.filteredThemes.length > 0
        model: root.filteredThemes
        cellWidth: 220
        cellHeight: 148
        clip: true
        cacheBuffer: 400

        delegate: Item {
            id: tileRoot
            width: grid.cellWidth - 10
            height: grid.cellHeight - 10

            readonly property bool _isActiveDefault:
                root._defaultIds[modelData.kind] === modelData.id
            // Per-output assignment flags. With the registry refactor each
            // output owns its own per-kind theme slots — a theme is "set
            // for X" when X's slot matching this theme's kind equals this
            // theme's id. Because a theme has a single kind, only one of
            // the three kind slots on a given output can hold its id,
            // so this predicate is unambiguous. _outputsRev makes the
            // bindings reactive to registry mutations.
            property int _outputsRev: 0
            Connections {
                target: OutputService
                function onOutputsChanged() { tileRoot._outputsRev++ }
            }
            readonly property bool _isPrimary: {
                _outputsRev
                return OutputService.themeIdFor("primary", modelData.kind) === modelData.id
            }
            readonly property bool _isNdi: {
                _outputsRev
                return OutputService.themeIdFor("ndi", modelData.kind) === modelData.id
            }
            readonly property bool _isStage: {
                _outputsRev
                return OutputService.themeIdFor("stage", modelData.kind) === modelData.id
            }

            Rectangle {
                id: tile
                anchors.fill: parent
                radius: 0
                color: Theme.color.canvas
                border.color: themeMa.containsMouse ? Theme.color.brand : Theme.color.borderStrong
                border.width: 2
                clip: true

                Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }

                // Live theme preview rendered via the same NodeRenderer the
                // projection window uses — what you see is what you'll get.
                // autoPlayVideos off because dozens of preview tiles each
                // running a video would melt the GPU.
                ThemePreview {
                    anchors.fill: parent
                    anchors.margins: 4
                    theme: modelData
                    autoPlayVideos: false
                }

                // Theme name + kind glyph in the corner — translucent black
                // backdrop so it stays readable over any theme background.
                // Kind is rendered as the same icon the schedule sidebar
                // uses for that kind (Theme.scheduleKindIcon) instead of a
                // trailing " · scripture" string — the icon is fixed-width
                // regardless of translation, doesn't compete with the
                // theme's name for tile-corner real estate, and reuses
                // vocabulary the operator already learned in the schedule.
                Rectangle {
                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                    anchors.margins: 8
                    width: kindRow.implicitWidth + Theme.space.md * 2
                    height: 22
                    radius: 3
                    color: "#000000A0"

                    Row {
                        id: kindRow
                        anchors.centerIn: parent
                        spacing: 6

                        AppIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: !!modelData.kind
                            name: Theme.scheduleKindIcon(modelData.kind || "")
                            color: "#ffffff"
                            size: 12
                        }
                        Text {
                            id: nameLabel
                            anchors.verticalCenter: parent.verticalCenter
                            text: modelData.name
                            color: "#ffffff"
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.smallSize
                            font.weight: Theme.font.weightSemiBold
                            // Black 1px drop shadow under each glyph — keeps
                            // the title legible even when a theme background
                            // pushes through the translucent chip on a light
                            // scene.
                            style: Text.Raised
                            styleColor: "#000000"
                        }
                    }
                }

                // Top-left badge row — stacks per-kind DEFAULT and the
                // per-output assignment chips horizontally. Each badge is
                // independently visible; multiple can co-occur (e.g. a
                // theme can be both the song-kind default AND the Primary
                // HDMI output theme).
                Row {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.margins: 8
                    spacing: 4

                    Rectangle {
                        visible: tileRoot._isActiveDefault
                        width: defaultLabel.implicitWidth + Theme.space.sm * 2
                        height: 16
                        radius: 2
                        color: Theme.color.brand

                        Text {
                            id: defaultLabel
                            anchors.centerIn: parent
                            text: qsTr("DEFAULT")
                            color: Theme.color.brandInk
                            font.family: Theme.font.monoFamily
                            font.pixelSize: 11
                            font.weight: Theme.font.weightSemiBold
                            font.letterSpacing: 0.8
                        }
                    }
                    // PRIMARY = the audience-facing live output. Painted in
                    // live-red so the badge sits in the same semantic family
                    // as LivePanel's LIVE indicator and the schedule's live
                    // row glow — "PRIMARY" and "LIVE" should read as the
                    // same idea at a glance.
                    Rectangle {
                        visible: tileRoot._isPrimary
                        width: primaryLabel.implicitWidth + Theme.space.sm * 2
                        height: 16
                        radius: 2
                        color: Theme.color.live

                        Text {
                            id: primaryLabel
                            anchors.centerIn: parent
                            text: qsTr("PRIMARY")
                            color: "#ffffff"
                            font.family: Theme.font.monoFamily
                            font.pixelSize: 11
                            font.weight: Theme.font.weightSemiBold
                            font.letterSpacing: 0.8
                        }
                    }
                    // NDI badge in the same bright mixer-cyan we use on the
                    // TopBar's NDI hide chip and the status pill. Three
                    // surfaces, one color — the operator scans the cyan and
                    // knows "that's the broadcast story" regardless of which
                    // surface they're looking at.
                    Rectangle {
                        visible: tileRoot._isNdi
                        width: ndiLabel.implicitWidth + Theme.space.sm * 2
                        height: 16
                        radius: 2
                        color: Theme.color.brandHover

                        Text {
                            id: ndiLabel
                            anchors.centerIn: parent
                            text: qsTr("NDI")
                            color: Theme.color.brandInk
                            font.family: Theme.font.monoFamily
                            font.pixelSize: 11
                            font.weight: Theme.font.weightSemiBold
                            font.letterSpacing: 0.8
                        }
                    }
                    Rectangle {
                        visible: tileRoot._isStage
                        width: stageLabel.implicitWidth + Theme.space.sm * 2
                        height: 16
                        radius: 2
                        color: Theme.color.overlay
                        border.color: Theme.color.borderStrong
                        border.width: 1

                        Text {
                            id: stageLabel
                            anchors.centerIn: parent
                            text: qsTr("STAGE")
                            color: Theme.color.textSecondary
                            font.family: Theme.font.monoFamily
                            font.pixelSize: 11
                            font.weight: Theme.font.weightSemiBold
                            font.letterSpacing: 0.8
                        }
                    }
                }

                // "Built-in" indicator chip — top right.
                Rectangle {
                    visible: modelData.isBuiltin === true
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 8
                    width: builtinLabel.implicitWidth + Theme.space.sm * 2
                    height: 16
                    radius: 2
                    color: "#000000A0"

                    Text {
                        id: builtinLabel
                        anchors.centerIn: parent
                        text: qsTr("PRESET")
                        color: "#dddddd"
                        font.family: Theme.font.monoFamily
                        font.pixelSize: 11
                        font.weight: Theme.font.weightSemiBold
                        font.letterSpacing: 0.8
                    }
                }

                RightClickArea {
                    id: themeMa
                    anchors.fill: parent
                    onDoubleClicked: AppState.openThemeEditor(modelData.id, modelData.kind)
                    menuItems: [
                        { label: qsTr("Edit"),       iconName: "edit",
                          action: () => AppState.openThemeEditor(modelData.id, modelData.kind) },
                        { label: qsTr("Duplicate"),  iconName: "copy",
                          action: () => ThemeService.duplicateTheme(modelData.id,
                                           qsTr("%1 Copy").arg(modelData.name)) },
                        { label: qsTr("Export…"),    iconName: "download",
                          action: () => {
                              const plan = ThemeService.resolveExportPlan(modelData.id)
                              AppState.openModal("exportTheme", {
                                  themeId:   modelData.id,
                                  themeName: modelData.name,
                                  themeKind: modelData.kind,
                                  plan:      plan
                              })
                          } },
                        { label: qsTr("Set as default"),
                          iconName: "star",
                          enabled: !tileRoot._isActiveDefault,
                          action: () => ThemeService.setDefaultFor(modelData.kind, modelData.id) },
                        { separator: true },
                        // Per-output assignment. Primary HDMI is always
                        // live. NDI is live only in dual output mode —
                        // when single, the menu item is disabled and
                        // labelled with the dependency so the operator
                        // knows what to flip. An already-set NDI pin
                        // remains unsettable from single mode so the
                        // operator isn't stuck with a stale assignment
                        // they can't clear. Stage stays Soon until
                        // multi-output activation lands in v1.1.
                        // Per-output assignment auto-routes by this
                        // theme's kind: a song-kind theme lands in the
                        // output's song slot, scripture into scripture,
                        // presentation into presentation. The operator
                        // picks "Set for X" and never thinks about which
                        // slot — the theme's own kind decides.
                        { label: tileRoot._isPrimary
                                ? qsTr("Unset for Primary HDMI")
                                : qsTr("Set for Primary HDMI"),
                          iconName: "monitor",
                          action: () => {
                              OutputService.setThemeIdFor(
                                  "primary", modelData.kind,
                                  tileRoot._isPrimary ? 0 : modelData.id)
                          } },
                        { label: tileRoot._isNdi
                                ? qsTr("Unset for NDI Broadcast")
                                : (SettingsService.outputMode === "dual"
                                    ? qsTr("Set for NDI Broadcast")
                                    : qsTr("Set for NDI Broadcast (requires Dual output mode)")),
                          iconName: "radio",
                          enabled: SettingsService.outputMode === "dual"
                                || tileRoot._isNdi,
                          action: () => {
                              OutputService.setThemeIdFor(
                                  "ndi", modelData.kind,
                                  tileRoot._isNdi ? 0 : modelData.id)
                          } },
                        { label: tileRoot._isStage
                                ? qsTr("Unset for Stage Monitor (Soon)")
                                : qsTr("Set for Stage Monitor (Soon)"),
                          iconName: "tv",
                          action: () => {
                              OutputService.setThemeIdFor(
                                  "stage", modelData.kind,
                                  tileRoot._isStage ? 0 : modelData.id)
                          } },
                        { separator: true },
                        { label: qsTr("Delete"),     iconName: "trash",
                          destructive: true,
                          enabled: !modelData.isBuiltin,
                          action: () => ThemeService.destroy(modelData.id) }
                    ]
                }
            }
        }
    }
}
