import QtQuick
import Crater

// Themes tab — visual presets for projection text rendering.
// Backed by ThemeService.allThemes (QList<Theme> value-types); each tile
// previews the theme's node graph via ThemePreview.
//
// Tokens shape (v2): see qt/core/src/db/migrations/app/V003__theme_nodes.sql.
Item {
    id: root

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

    // ── Import error surface ────────────────────────────────────────────
    property string _importError: ""

    Timer {
        id: errorClearTimer
        interval: 5000
        onTriggered: root._importError = ""
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

        GhostButton {
            text: qsTr("Import theme")
            iconName: "upload"
            onClicked: {
                const path = FileDialogService.chooseOpenFile(
                    qsTr("Import Theme"),
                    [qsTr("Crater Theme (*.craterheme)"), qsTr("All Files (*.*)")])
                if (path && path.length > 0) {
                    const id = ThemeService.importThemeFile(path)
                    if (id === 0) {
                        root._importError = ThemeService.lastImportError()
                                         || qsTr("Import failed")
                        errorClearTimer.restart()
                    }
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
        anchors.top: errorBar.bottom
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
            // Per-output assignment flags. Primary HDMI's slot actually
            // drives rendering (via AppState.resolveItemTheme); NDI / Stage
            // persist for the v1.1 multi-output pipeline.
            readonly property bool _isPrimary: SettingsService.themeIdForPrimary === modelData.id
            readonly property bool _isNdi:     SettingsService.themeIdForNdi     === modelData.id
            readonly property bool _isStage:   SettingsService.themeIdForStage   === modelData.id

            Rectangle {
                id: tile
                anchors.fill: parent
                radius: Theme.radius.lg
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

                // Theme name + kind in the corner — translucent black
                // backdrop so it stays readable over any theme background.
                Rectangle {
                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                    anchors.margins: 8
                    width: nameLabel.implicitWidth + Theme.space.md * 2
                    height: 22
                    radius: 3
                    color: "#000000A0"

                    Text {
                        id: nameLabel
                        anchors.centerIn: parent
                        text: modelData.name + " · " + (modelData.kind || "")
                        color: "#ffffff"
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                        font.weight: Theme.font.weightSemiBold
                        // Black 1px drop shadow under each glyph — keeps the
                        // title legible even when a theme's background pushes
                        // through the translucent chip on a light scene.
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
                    Rectangle {
                        visible: tileRoot._isPrimary
                        width: primaryLabel.implicitWidth + Theme.space.sm * 2
                        height: 16
                        radius: 2
                        color: Theme.color.preview

                        Text {
                            id: primaryLabel
                            anchors.centerIn: parent
                            text: qsTr("PRIMARY")
                            color: Theme.color.previewSubtle
                            font.family: Theme.font.monoFamily
                            font.pixelSize: 11
                            font.weight: Theme.font.weightSemiBold
                            font.letterSpacing: 0.8
                        }
                    }
                    Rectangle {
                        visible: tileRoot._isNdi
                        width: ndiLabel.implicitWidth + Theme.space.sm * 2
                        height: 16
                        radius: 2
                        color: Theme.color.overlay
                        border.color: Theme.color.borderStrong
                        border.width: 1

                        Text {
                            id: ndiLabel
                            anchors.centerIn: parent
                            text: qsTr("NDI")
                            color: Theme.color.textSecondary
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
                              const path = FileDialogService.chooseSaveFile(
                                  qsTr("Export Theme"),
                                  modelData.name + ".craterheme",
                                  [qsTr("Crater Theme (*.craterheme)")])
                              if (path && path.length > 0)
                                  ThemeService.exportTheme(modelData.id, path)
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
                        { label: tileRoot._isPrimary
                                ? qsTr("Unset for Primary HDMI")
                                : qsTr("Set for Primary HDMI"),
                          iconName: "monitor",
                          action: () => {
                              SettingsService.themeIdForPrimary =
                                  tileRoot._isPrimary ? 0 : modelData.id
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
                              SettingsService.themeIdForNdi =
                                  tileRoot._isNdi ? 0 : modelData.id
                          } },
                        { label: tileRoot._isStage
                                ? qsTr("Unset for Stage Monitor (Soon)")
                                : qsTr("Set for Stage Monitor (Soon)"),
                          iconName: "tv",
                          action: () => {
                              SettingsService.themeIdForStage =
                                  tileRoot._isStage ? 0 : modelData.id
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
