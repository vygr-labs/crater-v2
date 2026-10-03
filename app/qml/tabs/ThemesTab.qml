import QtQuick
import QtQuick.Controls.Basic
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

    // Mirror of the per-kind default theme id, cached so each tile's PRIMARY
    // badge rebinds on ThemeService.defaultsChanged without polling
    // defaultFor() every paint. The per-kind default IS the primary/audience
    // theme (resolveItemTheme falls back to it), so the badge that surfaces it
    // is labelled PRIMARY and the flyout's "Primary HDMI" option writes it.
    // Also refreshed on allThemesChanged because deleting the active default
    // shifts the resolver to the next theme of that kind.
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

    // ── Multi-select ────────────────────────────────────────────────────
    // Checked themes, keyed by id (click rules in components/
    // LibrarySelection.qml). Themes have no "current" tile (a plain click
    // never did anything here), so a plain click only clears the checked
    // set and becomes the Shift+click pivot.
    LibrarySelection {
        id: selection
        tabKey:   "themes"
        items:    root.filteredThemes
        universe: ThemeService.allThemes
    }

    function _themeNoun(n) { return n === 1 ? qsTr("theme") : qsTr("themes") }

    function bulkDuplicate() {
        const rows = selection.selectedItems()
        for (let i = 0; i < rows.length; i++)
            ThemeService.duplicateTheme(rows[i].id, qsTr("%1 Copy").arg(rows[i].name))
    }

    // Presets (built-in themes) can't be deleted, same as the per-tile
    // Delete, which is disabled for them. They are left out and the dialog
    // says how many, rather than refusing the whole batch.
    function bulkDelete() {
        const rows = selection.selectedItems()
        if (rows.length === 0) return
        const deletable = rows.filter(function(t) { return !t.isBuiltin })
        const skipped = rows.length - deletable.length
        if (deletable.length === 0) {
            root._statusMessage = skipped === 1
                ? qsTr("The selected theme is a preset. Presets cannot be deleted.")
                : qsTr("All %1 selected themes are presets. Presets cannot be deleted.").arg(skipped)
            return
        }
        const ids = deletable.map(function(t) { return t.id })
        const n = ids.length
        let body = qsTr("This permanently removes %1 %2.").arg(n).arg(_themeNoun(n))
        if (skipped > 0) {
            body += " " + (skipped === 1
                ? qsTr("1 preset in the selection will be kept. Presets cannot be deleted.")
                : qsTr("%1 presets in the selection will be kept. Presets cannot be deleted.").arg(skipped))
        }
        AppState.openModal("confirm", {
            title:       qsTr("Delete %1 %2?").arg(n).arg(_themeNoun(n)),
            body:        body,
            confirmText: qsTr("Delete"),
            onConfirm:   function() {
                for (let i = 0; i < ids.length; i++) ThemeService.destroy(ids[i])
                selection.clear()
            }
        })
    }

    // Bulk export: one .craterheme bundle per theme, named after the theme,
    // into a folder the operator picks. The single-theme dialog's per-font
    // opt-outs don't scale to a batch, so every bundleable font goes in
    // (exportTheme's documented default for programmatic callers).
    function bulkExport() {
        const rows = selection.selectedItems()
        if (rows.length === 0) return
        const dir = FileDialogService.chooseDirectory(
            qsTr("Export %1 %2 to folder").arg(rows.length).arg(_themeNoun(rows.length)))
        if (!dir || dir.length === 0) return

        let used = {}
        let exported = 0
        let failed = []
        for (let i = 0; i < rows.length; i++) {
            const t = rows[i]
            // Strip characters Windows refuses in file names. Two themes
            // with the same name, or a file already in the folder, get
            // " (2)", " (3)" so nothing is ever overwritten.
            let base = String(t.name || "").replace(/[\\/:*?"<>|]/g, "_").trim()
            if (base.length === 0) base = qsTr("Theme")
            let name = base
            let k = 2
            while (used[name.toLowerCase()]
                   || FileDialogService.pathExists(dir + "/" + name + ".craterheme"))
                name = base + " (" + (k++) + ")"
            used[name.toLowerCase()] = true
            if (ThemeService.exportTheme(t.id, dir + "/" + name + ".craterheme", []))
                exported++
            else
                failed.push(t.name)
        }
        if (exported > 0)
            root._statusMessage = qsTr("Exported %1 %2 to %3")
                                      .arg(exported).arg(_themeNoun(exported)).arg(dir)
        if (failed.length > 0) {
            root._importError = qsTr("Could not export %1. %2")
                                    .arg(failed.join(", "))
                                    .arg(ThemeService.lastExportError() || "")
            errorClearTimer.restart()
        }
    }

    // Right-click on a checked tile while 2+ are checked.
    function bulkMenuItems() {
        const n = selection.count
        return [
            { label: qsTr("Duplicate"), iconName: "copy",
              action: function() { root.bulkDuplicate() } },
            { label: qsTr("Export %1 %2…").arg(n).arg(_themeNoun(n)), iconName: "download",
              action: function() { root.bulkExport() } },
            { separator: true },
            { label: qsTr("Delete"), iconName: "trash", destructive: true,
              action: function() { root.bulkDelete() } }
        ]
    }

    Connections {
        target: AppState
        function onLibrarySelectAll() {
            if (AppState.tabKeys[AppState.activeTab] !== "themes") return
            selection.selectAll()
        }
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
    // On a narrow tab the two button groups would overlap, so the right-hand
    // actions wrap to a second row beneath the filter chips. Keyed on the two
    // groups' rendered widths vs the tab width (plus the three lg gaps: left,
    // middle, right) rather than a hardcoded breakpoint — the labels are
    // translated, so only measuring the real widths is correct. Flips once at
    // the threshold without oscillating (neither width depends on the wrap).
    readonly property bool _headerWrap:
        filterRow.width + header.width + Theme.space.lg * 3 > width

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
        anchors.right: parent.right
        anchors.rightMargin: Theme.space.lg
        // Inline with the filter chips when they fit; otherwise drop to a
        // second row beneath them (see root._headerWrap).
        anchors.top: root._headerWrap ? filterRow.bottom : parent.top
        anchors.topMargin: root._headerWrap ? Theme.space.sm : Theme.space.lg
        spacing: Theme.space.sm
        z: 1

        // Select mode: shows the tile checkboxes (LibrarySelection).
        SelectModeToggle {
            anchors.verticalCenter: parent.verticalCenter
            target: selection
        }

        // Import — one dropdown collapsing the three import paths so the header
        // stays compact (esp. on narrow tabs). Each menu item keeps its own
        // file-picker + result-banner logic. Anchored bottom-right of the
        // button (dx: -menuWidth) so the menu doesn't fall off the tab's right
        // edge, matching the New-theme button.
        GhostButton {
            id: importBtn
            text: qsTr("Import")
            iconName: "upload"
            onClicked: {
                AppState.openContextMenuAt(importBtn,
                    importBtn.width, importBtn.height,
                    [
                        // Bundle (.craterheme v2) — self-contained zip that can
                        // carry media + fonts. See ARCHITECTURE.md §10.
                        { label: qsTr("Import theme…"), iconName: "upload",
                          action: function() {
                              const path = FileDialogService.chooseOpenFile(
                                  qsTr("Import Theme"),
                                  [qsTr("Crater Theme (*.craterheme)"), qsTr("All Files (*.*)")])
                              if (!path || path.length === 0) return

                              // ThemeImportReport (Q_GADGET). themeId === 0 is a
                              // catastrophic failure; warnings are best-effort
                              // issues on an otherwise-successful import.
                              const report = ThemeService.importThemeFile(path)
                              if (report.themeId === 0) {
                                  root._importError = report.errorMessage
                                                   || ThemeService.lastImportError()
                                                   || qsTr("Import failed")
                                  errorClearTimer.restart()
                                  return
                              }

                              // A bundle can carry video backgrounds. Those land
                              // via MediaService::importPathSync, which emits
                              // allMediaChanged but NOT importFinished, so the
                              // startup-wired thumbnail sweep never sees them and
                              // the clips show no poster until the next launch.
                              // Kick the sweep here (no-op for ids already done).
                              VideoThumbnailer.ensureForAllVideos()

                              if (report.mediaWarnings.length > 0
                                  || report.fontWarnings.length > 0) {
                                  const lines = report.mediaWarnings
                                                .concat(report.fontWarnings)
                                  root._statusMessage =
                                      qsTr("Import succeeded with warnings:") + "\n"
                                      + lines.join("\n")
                              }
                          } },
                        // Plain-JSON theme — gradients / colors / system fonts,
                        // no bundled assets (see qt/docs/theme-schema.md).
                        { label: qsTr("Import theme JSON…"), iconName: "file-text",
                          action: function() {
                              const path = FileDialogService.chooseOpenFile(
                                  qsTr("Import Theme JSON"),
                                  [qsTr("Theme JSON (*.json)"), qsTr("All Files (*.*)")])
                              if (!path || path.length === 0) return

                              const id = ThemeService.importThemeJsonFile(path)
                              if (id === 0) {
                                  root._importError = ThemeService.lastImportError()
                                                   || qsTr("JSON theme import failed")
                                  errorClearTimer.restart()
                                  return
                              }
                              root._statusMessage = qsTr("Imported theme from JSON")
                          } },
                        { separator: true },
                        // Font import is a deliberate, separate consent action —
                        // it adds a font from outside the QRC/system set so
                        // subsequent exports can bundle it (ARCHITECTURE.md §10.5).
                        { label: qsTr("Import font…"), iconName: "type",
                          action: function() {
                              const path = FileDialogService.chooseOpenFile(
                                  qsTr("Import Font"),
                                  [qsTr("Font Files (*.ttf *.otf)"), qsTr("All Files (*.*)")])
                              if (!path || path.length === 0) return

                              const font = FontService.importFontFile(path)
                              if (font.id === 0) {
                                  root._importError = FontService.lastError()
                                                   || qsTr("Font import failed")
                                  errorClearTimer.restart()
                                  return
                              }
                              // Sticky banner so the confirmation is noticed even
                              // if the operator looked away when the dialog closed.
                              root._statusMessage =
                                  qsTr("Imported font: %1").arg(font.family)
                          } }
                    ],
                    { dx: -220 })
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
        anchors.top: root._headerWrap ? header.bottom : filterRow.bottom
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
        anchors.top: errorBar.visible ? errorBar.bottom
                   : root._headerWrap ? header.bottom : filterRow.bottom
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
        ScrollBar.vertical: AppScrollBar {}
        anchors.top: statusBar.visible ? statusBar.bottom
                   : errorBar.visible  ? errorBar.bottom
                   : root._headerWrap  ? header.bottom
                                       : filterRow.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: selectionBar.visible ? selectionBar.top : parent.bottom
        anchors.leftMargin: Theme.space.lg
        // Run to the panel edge; the responsive cellWidth below reserves the
        // scrollbar's lane on the right so the bar never lands on a tile.
        anchors.rightMargin: 0
        anchors.bottomMargin: selectionBar.visible ? Theme.space.sm : Theme.space.lg
        anchors.topMargin: Theme.space.sm
        visible: root.filteredThemes.length > 0
        model: root.filteredThemes
        // Flex ~220px columns to fill the row, reserving the scrollbar lane on
        // the right so the bar never overlaps a tile.
        readonly property int _cols: Math.max(1, Math.floor((width - Theme.size.scrollBar) / 220))
        cellWidth: Math.floor((width - Theme.size.scrollBar) / _cols)
        cellHeight: 148
        clip: true
        cacheBuffer: 400

        delegate: Item {
            id: tileRoot
            width: grid.cellWidth - 10
            height: grid.cellHeight - 10

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
            // The per-kind default theme. Surfaced as the PRIMARY badge and
            // toggled by the flyout's "Primary HDMI" option — the default IS
            // the primary/audience theme, so there's no separate primary pin.
            readonly property bool _isActiveDefault:
                root._defaultIds[modelData.kind] === modelData.id
            readonly property bool _isNdi: {
                _outputsRev
                return OutputService.themeIdFor("ndi", modelData.kind) === modelData.id
            }
            // Theme pins for every OTHER registered output, built fresh on
            // each registry change. This was a single hardcoded "Stage
            // Monitor (Soon)" row back when "stage" was the only output that
            // could ever exist besides primary and NDI. Outputs are dynamic
            // now — a church can add an overflow screen or a foyer display —
            // so the menu enumerates them instead of naming one.
            //
            // Only outputs in "mirror" content mode appear. The presenter
            // view (StageScene) is deliberately unthemed — it is text on flat
            // colour so it stays readable from across a dark room — so
            // offering to pin a theme to a stage-mode output would be an
            // option that silently does nothing.
            // Display names of every extra output this theme is pinned to.
            // Drives the tile badge. Deliberately NOT filtered by content
            // mode, unlike _outputPinEntries below: a pin on an output that
            // has since been switched to presenter view is inert, and the
            // operator can only notice and clear it if the tile still admits
            // it exists.
            readonly property var _pinnedOutputNames: {
                _outputsRev
                const list = OutputService.outputs
                let names = []
                for (let i = 0; i < list.length; i++) {
                    const b = list[i]
                    if (b.id === "primary" || b.role === "ndi") continue
                    if (OutputService.themeIdFor(b.id, modelData.kind) === modelData.id)
                        names.push(b.displayName)
                }
                return names
            }

            readonly property var _outputPinEntries: {
                _outputsRev
                const list = OutputService.outputs
                let entries = []
                let sawStageMode = false
                for (let i = 0; i < list.length; i++) {
                    const b = list[i]
                    if (b.id === "primary" || b.role === "ndi") continue
                    if (b.contentMode !== "mirror") { sawStageMode = true; continue }
                    const pinned =
                        OutputService.themeIdFor(b.id, modelData.kind) === modelData.id
                    // Bind id + pinned per iteration: a closure over the loop
                    // variables would have every row act on the last output.
                    entries.push({
                        label: pinned ? qsTr("Unset for %1").arg(b.displayName)
                                      : qsTr("Set for %1").arg(b.displayName),
                        iconName: "tv",
                        action: (function(outId, isPinned) {
                            return function() {
                                OutputService.setThemeIdFor(
                                    outId, modelData.kind, isPinned ? 0 : modelData.id)
                            }
                        })(b.id, pinned)
                    })
                }
                if (entries.length === 0) {
                    // Say WHICH of the two reasons applies, so the operator
                    // knows whether to add an output or switch one out of
                    // presenter mode.
                    entries.push({
                        label: sawStageMode
                                 ? qsTr("Presenter-view outputs are unthemed")
                                 : qsTr("No other outputs configured"),
                        iconName: "tv",
                        enabled: false
                    })
                }
                return entries
            }

            // Checked for bulk actions (multi-select, keyed by theme id).
            readonly property bool _checked: selection.isSelected(modelData.id)
            readonly property bool _showCheck: selection.showChecks

            Rectangle {
                id: tile
                anchors.fill: parent
                radius: 0
                color: Theme.color.canvas
                // Checked tiles keep the brand border whether hovered or not,
                // same as a checked media tile.
                border.color: (tileRoot._checked || themeMa.containsMouse)
                              ? Theme.color.brand : Theme.color.borderStrong
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

                // Theme name in a full-width bottom scrim. Previously a
                // translucent chip sized to the text — which collided badly with
                // lower-third themes: their own content text sits at the bottom
                // of the preview, exactly where the chip was, and bled through
                // its 63%-opaque backdrop. A full-width vertical gradient (clear
                // top → opaque bottom) masks whatever the theme renders behind
                // the name, and the title elides instead of overflowing (then
                // clipping at) the tile edge on long names. Mirrors MediaTab's
                // title scrim, kept always-visible since the name is the tile's
                // primary label. The kind glyph lives in the top-left badge row.
                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.margins: 4
                    height: 26
                    radius: 0
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: "#00000000" }
                        GradientStop { position: 0.4; color: "#000000A6" }
                        GradientStop { position: 1.0; color: "#000000FF" }
                    }

                    Text {
                        id: nameLabel
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.leftMargin: 6
                        anchors.rightMargin: 6
                        anchors.bottomMargin: 4
                        text: modelData.name
                        color: "#ffffff"
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                        font.weight: Theme.font.weightSemiBold
                        elide: Text.ElideRight
                        // Per-glyph 1px black drop shadow — keeps the title
                        // legible even at the lighter top of the scrim and over
                        // bright theme content.
                        style: Text.Raised
                        styleColor: "#000000"
                    }
                }

                // Top-left badge row — stacks per-kind DEFAULT and the
                // per-output assignment chips horizontally. Each badge is
                // independently visible; multiple can co-occur (e.g. a
                // theme can be both the song-kind default AND the Primary
                // HDMI output theme).
                Row {
                    // Steps right of the multi-select checkbox while it shows.
                    anchors.left: tileRoot._showCheck ? tileCheck.right : parent.left
                    anchors.leftMargin: tileRoot._showCheck ? 4 : 8
                    anchors.top: parent.top
                    anchors.topMargin: 8
                    spacing: 4

                    // Kind badge — square chip tinted with Theme.scheduleColor
                    // for that kind (typeSong / typeScripture / typeSermon /
                    // …). Same color vocabulary the schedule sidebar uses,
                    // so operators scan "what kind is this theme" with the
                    // same hue→meaning mapping they already learned. Sits
                    // first in the row so the eye reads kind → role
                    // (DEFAULT / PRIMARY / NDI) left-to-right. Icon glyph
                    // uses near-black ink so the colored chip carries the
                    // signal and the icon reads as a label on top of it
                    // rather than competing with the chip color — same
                    // dark-on-color polarity brandInk uses elsewhere.
                    Rectangle {
                        visible: !!modelData.kind
                        width: 16
                        height: 16
                        radius: 2
                        color: Theme.scheduleColor(modelData.kind || "")

                        AppIcon {
                            anchors.centerIn: parent
                            name: Theme.scheduleKindIcon(modelData.kind || "")
                            // Black ink — WCAG contrast on every kind color
                            // sits in 5.2:1-7.5:1; white would drop below
                            // 3:1 and fail. Lucide is single-weight outline
                            // only (no filled variants exist for music /
                            // book-2 / presentation / video / image / file-
                            // text), so we can't switch to fills without
                            // changing the icon font itself.
                            color: "#0b0b0b"
                            size: 13
                        }
                    }

                    // PRIMARY = the audience-facing live output AND the
                    // de-facto default theme: resolveItemTheme checks the
                    // Primary pin before any per-kind fallback, so whatever is
                    // pinned here is what the audience sees by default. (The
                    // former separate DEFAULT badge said the same thing in a
                    // different word — it was folded into this one when the
                    // "Set as default" menu collapsed into the Primary pin.)
                    // Painted in live-red so the badge sits in the same
                    // semantic family as LivePanel's LIVE indicator and the
                    // schedule's live row glow — "PRIMARY" and "LIVE" should
                    // read as the same idea at a glance.
                    Rectangle {
                        visible: tileRoot._isActiveDefault
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
                    // One badge covering every extra output, rather than one
                    // badge per output: a tile is 200-odd px wide and a church
                    // with three extra screens would push the theme name off
                    // it. Names the output when there is exactly one, counts
                    // them otherwise.
                    Rectangle {
                        visible: tileRoot._pinnedOutputNames.length > 0
                        width: stageLabel.implicitWidth + Theme.space.sm * 2
                        height: 16
                        radius: 2
                        color: Theme.color.overlay
                        border.color: Theme.color.borderStrong
                        border.width: 1

                        Text {
                            id: stageLabel
                            anchors.centerIn: parent
                            text: tileRoot._pinnedOutputNames.length === 1
                                    ? tileRoot._pinnedOutputNames[0].toUpperCase()
                                    : qsTr("%1 OUTPUTS").arg(tileRoot._pinnedOutputNames.length)
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
                    // Plain click only clears the checked set (it did
                    // nothing before multi-select); Ctrl / Shift build it.
                    onLeftClicked: function(mouse) {
                        AppState.setActiveFocus("library")
                        selection.handleClick(mouse, modelData.id)
                    }
                    // Runs before the menu resolves: a right-click on a
                    // checked tile with 2+ checked gets the bulk menu.
                    property bool _bulk: false
                    onRightClicked: function(mouse) {
                        AppState.setActiveFocus("library")
                        _bulk = selection.handleRightClick(modelData.id)
                    }
                    menuItems: function() {
                        return themeMa._bulk ? root.bulkMenuItems() : [
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
                        // One parent row that opens a hover-flyout of the three
                        // outputs, collapsing the former four "Set …" rows.
                        // "Primary HDMI" IS the default: it writes the per-kind
                        // default (ThemeService.setDefaultFor), which is what
                        // resolveItemTheme falls back to for the primary/audience
                        // output and what the PRIMARY badge reflects. NDI / Stage
                        // are per-output pins that auto-route by the theme's kind
                        // into that output's slot. NDI is live only in dual
                        // output mode (disabled + annotated otherwise, and an
                        // already-set pin stays clearable). Every other
                        // registered output that renders a themed scene is
                        // appended from _outputPinEntries.
                        { label: qsTr("Set as default %1 theme").arg(modelData.kind),
                          iconName: "star",
                          submenu: [
                              { label: tileRoot._isActiveDefault
                                      ? qsTr("Unset for Primary HDMI")
                                      : qsTr("Set for Primary HDMI"),
                                iconName: "monitor",
                                action: () => {
                                    // The default owns the primary output now,
                                    // so retire any per-output primary pin first
                                    // — otherwise a pin set in an earlier build
                                    // (resolution tier 2) would shadow the
                                    // default (tier 3) we set here.
                                    OutputService.setThemeIdFor("primary", modelData.kind, 0)
                                    ThemeService.setDefaultFor(modelData.kind,
                                        tileRoot._isActiveDefault ? 0 : modelData.id)
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
                          ].concat(tileRoot._outputPinEntries) },
                        { separator: true },
                        { label: qsTr("Delete"),     iconName: "trash",
                          destructive: true,
                          enabled: !modelData.isBuiltin,
                          action: () => ThemeService.destroy(modelData.id) }
                        ]
                    }
                }

                // Multi-select checkbox, top-left. Declared after themeMa so
                // it sits above it and gets its own clicks.
                SelectCheck {
                    id: tileCheck
                    visible: tileRoot._showCheck
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.margins: 8
                    onImage: true
                    checked: tileRoot._checked
                    onToggled: {
                        AppState.setActiveFocus("library")
                        selection.toggle(modelData.id)
                    }
                }
            }
        }
    }

    // Bulk-action bar while themes are checked.
    SelectionBar {
        id: selectionBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: selection.active
        count: selection.count
        hiddenCount: selection.hiddenCount
        canSelectAll: !selection.allVisibleSelected
        onSelectAllClicked: selection.selectAll()
        onClearClicked: selection.clear()
        actions: [
            { label: qsTr("Duplicate"), iconName: "copy",
              action: function() { root.bulkDuplicate() } },
            { label: qsTr("Export"), iconName: "download",
              action: function() { root.bulkExport() } },
            { label: qsTr("Delete"), iconName: "trash", destructive: true,
              action: function() { root.bulkDelete() } }
        ]
    }
}
