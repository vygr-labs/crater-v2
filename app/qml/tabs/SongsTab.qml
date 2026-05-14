import QtQuick

// Songs tab — full library experience matching the Electron desktop app:
//
//   • Search bar lives in the sidebar (TabSearchBar) with a mode dropdown
//     (title / lyrics / author / recent / oldest / newest). FTS5 is used
//     for the lyrics mode via SongService.search.
//   • Top action bar inside this tab carries the song count, the "+" button
//     to create a new song, and a gear menu (sort, refresh, etc.).
//   • Single click on a row sets fluid focus and pushes the song to the
//     Preview pane (no schedule mutation).
//   • Double-click or Enter pushes the song Live (also no schedule mutation).
//   • Up / Down keys move fluid focus while keeping the search input focused.
//   • Right-click opens the standard context menu (Add to Schedule, Edit,
//     Duplicate, Favorite, Add to Collection, Delete).
//   • A small "LIVE" pill appears next to the row currently on the projection.
Item {
    id: root

    readonly property string tabKey: "songs"

    // Right-pane background — sits a touch darker than `canvas`, matching
    // electron's `bg="gray.950/30"` on the content side. Mirrors the
    // ScriptureTab so the two tabs share the same right-pane backdrop.
    Rectangle {
        anchors.fill: parent
        color: Theme.color.bgContent
        z: -1
    }

    readonly property string query:  (AppState.searchText.songs || "").toLowerCase()
    readonly property string mode:   AppState.librarySearchMode.songs || "lyrics"
    // Sort dimension is independent of filter mode — picking "Sort by Newest"
    // from the gear no longer changes the input placeholder. "none" means
    // natural ordering (title-COLLATE-NOCASE as returned by SongService).
    readonly property string sortMode: AppState.librarySortMode.songs || "none"
    readonly property string group:  AppState.activeLibraryGroup.songs

    // ── Filtered + sorted song list ─────────────────────────────────────
    // Filter mode (drives the search input):
    //   title  ─ substring match against title
    //   lyrics ─ FTS5 trigram search across title+author+lyrics
    //   author ─ substring against author
    // Sort mode (independent of filter, set from the gear menu):
    //   none   ─ keep base ordering (title COLLATE NOCASE from the service)
    //   recent ─ updated_at DESC
    //   newest ─ created_at DESC
    //   oldest ─ created_at ASC
    //
    // Group filter ("favorites") is applied LAST so it intersects both filter
    // and sort. Previously this branch skipped FTS hits — a bug where searching
    // in lyrics mode while restricted to favorites returned non-favorite songs.
    readonly property var filteredSongs: {
        const all   = SongService.allSongs    // tracked for reactivity
        const grp   = root.group
        const m     = root.mode
        const sort  = root.sortMode
        const q     = root.query

        // Step 1 — choose the base set. Lyrics-FTS produces its own list from
        // the index; everything else starts from the full library.
        let result = []
        if (m === "lyrics" && q.length > 0) {
            result = SongService.search(AppState.searchText.songs || "")
        } else if (m === "title" && q.length > 0) {
            result = all.filter(function(s) {
                return s && (s.title || "").toLowerCase().indexOf(q) !== -1
            })
        } else if (m === "author" && q.length > 0) {
            result = all.filter(function(s) {
                return s && (s.author || "").toLowerCase().indexOf(q) !== -1
            })
        } else {
            result = all.slice()
        }

        // Step 2 — apply group filter to the (possibly FTS-filtered) set.
        // This is the lyrics-FTS bug fix: hits used to skip this filter.
        if (grp === "favorites") {
            result = result.filter(function(s) { return s && s.isFavorite })
        } else if (grp === "collections") {
            // CollectionService deferred; render empty until it lands.
            result = []
        }

        // Step 3 — sort. Skipped when sort === "none" so we keep SongService's
        // natural title order. Real timestamps now that Song carries them.
        if (sort === "recent") {
            result = result.slice().sort(function(a, b) { return (b.updatedAt | 0) - (a.updatedAt | 0) })
        } else if (sort === "newest") {
            result = result.slice().sort(function(a, b) { return (b.createdAt | 0) - (a.createdAt | 0) })
        } else if (sort === "oldest") {
            result = result.slice().sort(function(a, b) { return (a.createdAt | 0) - (b.createdAt | 0) })
        }

        // Project to a render-friendly shape so the delegate doesn't re-bind
        // into the Song value type. themeId rides along so buildItemFromSong's
        // theme-override path has a value even before fetchSong refreshes it.
        let out = []
        for (let j = 0; j < result.length; j++) {
            const s = result[j]
            out.push({
                id:         s.id,
                title:      s.title,
                author:     s.author || "",
                isFavorite: s.isFavorite,
                ccli:       s.ccli || "",
                themeId:    s.themeId || 0
            })
        }
        return out
    }

    readonly property int fluidIndex: AppState.libraryFluidIndex.songs

    // Bounds-clamp fluid index when the list shrinks (e.g. query change).
    // Only push preview when this tab is the active one — otherwise we'd
    // override a preview the operator deliberately set from another tab.
    onFilteredSongsChanged: {
        const n = filteredSongs.length
        if (n === 0) {
            if (fluidIndex !== -1) AppState.setLibraryFluid(tabKey, -1)
            return
        }
        const idx = (fluidIndex >= 0 && fluidIndex < n) ? fluidIndex : 0
        if (idx !== fluidIndex) AppState.setLibraryFluid(tabKey, idx)
        if (AppState.tabKeys[AppState.activeTab] === tabKey) pushPreviewFor(idx)
    }

    // When the operator switches into this tab, restore the preview to the
    // currently-focused row so the Preview pane matches the highlighted item.
    Connections {
        target: AppState
        function onActiveTabChanged() {
            if (AppState.tabKeys[AppState.activeTab] !== root.tabKey) return
            if (root.fluidIndex >= 0) root.pushPreviewFor(root.fluidIndex)
        }
    }

    // ── Helpers ─────────────────────────────────────────────────────────

    // Build the canonical schedule-item shape from a full Song record.
    function buildItemFromSong(song) {
        if (!song || !song.id) return null
        let pages = []
        for (let i = 0; i < song.sections.length; i++) {
            const sec = song.sections[i]
            pages.push({
                label:   sec.label || "",
                content: (sec.lines && sec.lines.length > 0) ? sec.lines.join("\n") : ""
            })
        }
        if (pages.length === 0) {
            pages = [{ label: "", content: song.title + (song.author ? "\n" + song.author : "") }]
        }
        return {
            kind:     "song",
            title:    song.title,
            subtitle: song.author + (song.ccli ? " · CCLI " + song.ccli : ""),
            pages:    pages,
            songId:   song.id,
            // Carried through to AppState.resolveItemTheme() so Go Live honors
            // the per-song theme override (set via the editor). 0 means "use
            // the user's default for kind=song" — the fallback case.
            themeId:  song.themeId || 0
        }
    }

    function songItemAt(idx) {
        if (idx < 0 || idx >= filteredSongs.length) return null
        const row = filteredSongs[idx]
        const full = SongService.fetchSong(row.id)
        return buildItemFromSong(full)
    }

    function pushPreviewFor(idx) {
        // Skip when the tab isn't active to avoid hijacking a schedule selection
        // the operator made elsewhere.
        if (AppState.tabKeys[AppState.activeTab] !== tabKey) return
        const item = songItemAt(idx)
        if (item) AppState.pushLibraryPreview(item)
        else      AppState.clearLibraryPreview()
    }

    function pushLiveFor(idx) {
        const item = songItemAt(idx)
        if (item) AppState.pushLibraryLive(item)
    }

    function addToScheduleFor(idx) {
        const item = songItemAt(idx)
        if (item) AppState.addItemToSchedule(item)
    }

    // ── Top action bar ──────────────────────────────────────────────────
    // Layout mirrors electron's MainActionBarMenu: [+] [⚙] clustered on the
    // right, song count centered. Both triggers are borderless — hover
    // recolors the icon to textPrimary and the background to raised, matching
    // electron's `_hover={{ color: 'white', bg: 'gray.600' }}` treatment.
    Rectangle {
        id: actionBar
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 32
        color: "transparent"

        // Center: song count
        Text {
            id: countLabel
            anchors.centerIn: parent
            text: {
                const n = root.filteredSongs.length
                const noun = n === 1 ? qsTr("song") : qsTr("songs")
                const q = AppState.searchText.songs || ""
                return n + " " + noun + (q.length > 0 ? qsTr(" matching \"") + q + "\"" : "")
            }
            color: Theme.color.textTertiary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.smallSize
        }

        // Right cluster: + (add) | ⚙ (gear menu). Adjacent in a Row so they
        // read as a related pair — same pattern as electron's MainActionBarMenu.
        Row {
            id: actionCluster
            anchors.right: parent.right
            anchors.rightMargin: Theme.space.md
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            // + (new song)
            Rectangle {
                id: addBtn
                width: 28; height: 22
                radius: 4
                color: addMa.containsMouse ? Theme.color.raised : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

                AppIcon {
                    anchors.centerIn: parent
                    name: "plus"
                    color: addMa.containsMouse ? Theme.color.textPrimary : Theme.color.textSecondary
                    size: 13
                    Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
                }

                MouseArea {
                    id: addMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: AppState.openModal("naming", {
                        title:       qsTr("Create new song"),
                        placeholder: qsTr("Song title"),
                        confirmText: qsTr("Create"),
                        onConfirm:   function(name) {
                            if (name && name.length > 0) SongService.create(name, "", "")
                        }
                    })
                }
            }

            // ⚙ + chevron — opens the gear menu (sort, refresh, edit/delete current).
            Rectangle {
                id: gearBtn
                width: 36; height: 22
                radius: 4
                color: gearMa.containsMouse ? Theme.color.raised : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

                Row {
                    anchors.centerIn: parent
                    spacing: 2
                    AppIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "settings"
                        color: gearMa.containsMouse ? Theme.color.textPrimary : Theme.color.textSecondary
                        size: 13
                        Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
                    }
                    AppIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "chevron-down"
                        color: Theme.color.textSecondary
                        size: 9
                    }
                }

                MouseArea {
                    id: gearMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        const focus = root.fluidIndex
                        const haveFocus = focus >= 0 && focus < root.filteredSongs.length
                        const focusedSong = haveFocus ? root.filteredSongs[focus] : null

                        let items = []
                        if (focusedSong) {
                            items.push({ label: qsTr("Edit Song"), iconName: "edit", kbd: "E",
                                action: function() {
                                    AppState.openModal("songEditor", { songId: focusedSong.id })
                                }})
                            items.push({ label: qsTr("Duplicate Song"), iconName: "copy",
                                action: function() { SongService.duplicate(focusedSong.id) }})
                            items.push({ separator: true })
                            items.push({ label: qsTr("Delete Song"), iconName: "trash", kbd: "Del",
                                destructive: true,
                                action: function() {
                                    AppState.openModal("confirm", {
                                        title:       qsTr("Delete song?"),
                                        body:        qsTr("This permanently removes \"") + focusedSong.title + "\".",
                                        confirmText: qsTr("Delete"),
                                        onConfirm:   function() { SongService.destroy(focusedSong.id) }
                                    })
                                }})
                            items.push({ separator: true })
                        }
                        // Sort items target librarySortMode (independent of the search
                        // input's mode). The ✓ tick follows the active sort so the
                        // operator sees which dimension is in effect.
                        const cur = AppState.librarySortMode.songs || "none"
                        items.push({ label: qsTr("Sort by Name"),        iconName: "arrow-down-az",
                            detail: cur === "none" ? "✓" : "",
                            action: function() { AppState.setLibrarySortMode("songs", "none") }})
                        items.push({ label: qsTr("Sort by Most Recent"), iconName: "clock",
                            detail: cur === "recent" ? "✓" : "",
                            action: function() { AppState.setLibrarySortMode("songs", "recent") }})
                        items.push({ label: qsTr("Sort by Newest"),      iconName: "sort-desc",
                            detail: cur === "newest" ? "✓" : "",
                            action: function() { AppState.setLibrarySortMode("songs", "newest") }})
                        items.push({ label: qsTr("Sort by Oldest"),      iconName: "sort-asc",
                            detail: cur === "oldest" ? "✓" : "",
                            action: function() { AppState.setLibrarySortMode("songs", "oldest") }})
                        items.push({ separator: true })
                        items.push({ label: qsTr("Refresh"), iconName: "refresh-cw" })

                        AppState.openContextMenuAt(gearBtn,
                            gearBtn.width, gearBtn.height + 4,
                            items, { menuWidth: 200, dx: -200 })
                    }
                }
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

    // ── Empty states ────────────────────────────────────────────────────
    EmptyState {
        anchors.top: actionBar.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        visible: SongService.allSongs.length === 0
        iconName: "music"
        title: qsTr("No songs yet")
        body: qsTr("Import songs from a file or create them manually to get started")
    }
    Item {
        anchors.top: actionBar.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        visible: SongService.allSongs.length === 0

        PrimaryButton {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.verticalCenter
            anchors.topMargin: 64
            variant: "brand"
            iconName: "plus"
            text: qsTr("Add your first song")
            onClicked: AppState.openModal("naming", {
                title:       qsTr("Create new song"),
                placeholder: qsTr("Song title"),
                confirmText: qsTr("Create"),
                onConfirm:   function(name) {
                    if (name && name.length > 0) SongService.create(name, "", "")
                }
            })
        }
    }

    EmptyState {
        anchors.top: actionBar.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        visible: SongService.allSongs.length > 0 && root.filteredSongs.length === 0
        iconName: "search-x"
        title: qsTr("No songs found")
        body: AppState.searchText.songs && AppState.searchText.songs.length > 0
              ? qsTr("No songs match \"") + AppState.searchText.songs + "\""
              : qsTr("Try a different search or switch group")
    }

    // "× Clear search" pill below the no-results state. Only shown when the
    // operator has a non-empty query — otherwise there's nothing to clear.
    // Layout follows the "Add your first song" overlay pattern further up:
    // sibling Item filling the same area, button anchored just below center.
    Item {
        anchors.top: actionBar.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        visible: SongService.allSongs.length > 0
              && root.filteredSongs.length === 0
              && AppState.searchText.songs && AppState.searchText.songs.length > 0

        Rectangle {
            id: clearPill
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.verticalCenter
            anchors.topMargin: 56
            implicitWidth: clearRow.width + 20
            implicitHeight: 28
            radius: Theme.radius.md
            color: clearPillMa.containsMouse ? Theme.color.raised : Theme.color.elevated
            Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

            Row {
                id: clearRow
                anchors.centerIn: parent
                spacing: Theme.space.sm
                AppIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "x"
                    color: Theme.color.textSecondary
                    size: 12
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Clear search")
                    color: Theme.color.textSecondary
                    font.family: Theme.font.family
                    font.pixelSize: 12
                }
            }

            MouseArea {
                id: clearPillMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: AppState.setSearch("songs", "")
            }
        }
    }

    // ── Songs list ──────────────────────────────────────────────────────
    ListView {
        id: list
        anchors.top: actionBar.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: Theme.space.sm
        anchors.bottomMargin: Theme.space.md
        visible: root.filteredSongs.length > 0
        model: root.filteredSongs
        clip: true
        cacheBuffer: 400
        spacing: 0
        boundsBehavior: Flickable.StopAtBounds
        currentIndex: root.fluidIndex

        // Keep currentIndex visible when fluid focus moves via keyboard.
        onCurrentIndexChanged: {
            if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
        }

        delegate: Item {
            id: songRow
            width: list.width
            // 36px matches electron's virtualizer row height (estimateSize: 36
            // + py-2 padding). Title at 14px + author at 12px fit because the
            // Column is verticalCenter-anchored and Qt's font metrics leave
            // ~3px of slack each side.
            height: 36

            readonly property bool _selected: list.currentIndex === index
            // True when *this row's song* is the one currently on the projector.
            // currentItem is a QVariantMap; its songId field is only present
            // when contentKind === "song", so guarding on contentKind keeps the
            // comparison meaningful even when projection is showing scripture
            // or media. Re-evaluates on ProjectionService.stateChanged (bundled
            // NOTIFY on the Q_PROPERTYs).
            readonly property bool _isLive:
                ProjectionService.contentKind === "song"
                && ProjectionService.currentItem
                && ProjectionService.currentItem.songId === modelData.id

            // Edge-to-edge background — no border, no radius. Mirrors the
            // electron song row: full-width band, gray.800 selected wash, and
            // a brand-tinted hover (electron's `bg=${defaultPalette}.900/30`,
            // i.e. brand.900 at 30% opacity layered over canvas).
            Rectangle {
                anchors.fill: parent
                radius: 0
                color: songRow._selected ? Theme.color.raised
                     : rowMa.containsMouse ? Theme.color.rowHoverBrand
                                           : "transparent"
                Behavior on color { ColorAnimation { duration: 150 } }
            }

            AppIcon {
                id: leadIcon
                anchors.left: parent.left
                anchors.leftMargin: Theme.space.md
                anchors.verticalCenter: parent.verticalCenter
                name: modelData.isFavorite ? "heart" : "music"
                color: modelData.isFavorite ? Theme.color.brand
                     : songRow._selected   ? Theme.color.textTitle
                                           : Theme.color.textTertiary
                size: 16
            }

            // LIVE pill — anchored right; visible only when this row is on
            // the projector. Re-uses the broadcast `live` color so it reads
            // the same as the global LIVE indicators elsewhere in the UI.
            Rectangle {
                id: livePill
                visible: songRow._isLive
                anchors.right: parent.right
                anchors.rightMargin: Theme.space.md
                anchors.verticalCenter: parent.verticalCenter
                implicitWidth: liveText.implicitWidth + 10
                implicitHeight: 14
                radius: 3
                color: Theme.color.live

                Text {
                    id: liveText
                    anchors.centerIn: parent
                    text: "LIVE"
                    color: Theme.color.brandInk
                    font.family: Theme.font.monoFamily
                    font.pixelSize: 9
                    font.weight: Theme.font.weightBold
                }
            }

            Column {
                anchors.left: leadIcon.right
                anchors.leftMargin: Theme.space.md
                anchors.right: parent.right
                // Give the title room when the LIVE pill is present; without
                // the dynamic margin the elided "…" would sit under the pill.
                anchors.rightMargin: livePill.visible
                                   ? (livePill.width + Theme.space.md + Theme.space.sm)
                                   : Theme.space.md
                anchors.verticalCenter: parent.verticalCenter
                spacing: 0

                Text {
                    text: modelData.title
                    color: songRow._selected ? Theme.color.textPrimary
                                             : Theme.color.textTitle
                    font.family: Theme.font.family
                    font.pixelSize: 14
                    font.weight: songRow._selected ? Theme.font.weightMedium
                                                   : Theme.font.weightRegular
                    elide: Text.ElideRight
                    width: parent.width
                }
                Text {
                    visible: modelData.author && modelData.author.length > 0
                    text: modelData.author
                    color: songRow._selected ? Theme.color.textSecondary
                                             : Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: 12
                    elide: Text.ElideRight
                    width: parent.width
                }
            }

            RightClickArea {
                id: rowMa
                anchors.fill: parent
                menuItems: [
                    { label: qsTr("Add to Schedule"), iconName: "plus",
                      action: function() { root.addToScheduleFor(index) } },
                    { label: qsTr("Push to Live"),    iconName: "play",
                      action: function() { root.pushLiveFor(index) } },
                    { separator: true },
                    { label: qsTr("Edit Song"), iconName: "edit", kbd: "E",
                      action: function() {
                          AppState.openModal("songEditor", { songId: modelData.id })
                      } },
                    { label: qsTr("Duplicate Song"), iconName: "copy",
                      action: function() { SongService.duplicate(modelData.id) } },
                    { separator: true },
                    { label: modelData.isFavorite
                            ? qsTr("Remove from Favorites")
                            : qsTr("Add to Favorites"),
                      iconName: modelData.isFavorite ? "heart-off" : "heart",
                      action: function() { SongService.toggleFavorite(modelData.id) } },
                    // No action — collections are deferred until CollectionService
                    // lands. Leaving the row in place preserves discoverability
                    // + electron parity.
                    { label: qsTr("Add to Collection…"), iconName: "folder" },
                    { separator: true },
                    { label: qsTr("Delete Song"), iconName: "trash", kbd: "Del", destructive: true,
                      action: function() {
                          AppState.openModal("confirm", {
                              title:       qsTr("Delete song?"),
                              body:        qsTr("This permanently removes \"") + modelData.title + "\".",
                              confirmText: qsTr("Delete"),
                              onConfirm:   function() { SongService.destroy(modelData.id) }
                          })
                      } }
                ]

                function _focus() {
                    AppState.setLibraryFluid(root.tabKey, index)
                    root.pushPreviewFor(index)
                }
                onLeftClicked:  _focus()
                onRightClicked: _focus()
                onDoubleClicked: {
                    AppState.setLibraryFluid(root.tabKey, index)
                    root.pushLiveFor(index)
                }
            }
        }
    }

    // ── Keyboard navigation from the search input ───────────────────────
    // The TabSearchBar in the sidebar consumes the keypress (so it never
    // collides with Main.qml's schedule shortcuts) and emits these signals.
    Connections {
        target: AppState
        function onLibraryNavigateDown() {
            if (AppState.tabKeys[AppState.activeTab] !== root.tabKey) return
            if (root.filteredSongs.length === 0) return
            const next = Math.min((root.fluidIndex < 0 ? -1 : root.fluidIndex) + 1,
                                  root.filteredSongs.length - 1)
            AppState.setLibraryFluid(root.tabKey, next)
            root.pushPreviewFor(next)
        }
        function onLibraryNavigateUp() {
            if (AppState.tabKeys[AppState.activeTab] !== root.tabKey) return
            if (root.filteredSongs.length === 0) return
            const next = Math.max(root.fluidIndex - 1, 0)
            AppState.setLibraryFluid(root.tabKey, next)
            root.pushPreviewFor(next)
        }
        function onLibraryActivate() {
            if (AppState.tabKeys[AppState.activeTab] !== root.tabKey) return
            if (root.fluidIndex >= 0) root.pushLiveFor(root.fluidIndex)
        }
        function onLibraryAddToSchedule() {
            if (AppState.tabKeys[AppState.activeTab] !== root.tabKey) return
            if (root.fluidIndex >= 0) root.addToScheduleFor(root.fluidIndex)
        }
        // Schedule → library sync. When the operator clicks a song row in the
        // schedule pane, scroll the library to that song so what's selected in
        // both panes agrees. Skipped in lyrics-FTS mode because the active
        // query may filter the song out of view — chasing it would be confusing
        // (and electron skips for the same reason — SongSelection.tsx:427).
        function onSyncSongFromSchedule(songId) {
            if (AppState.tabKeys[AppState.activeTab] !== root.tabKey) return
            if (root.mode === "lyrics" && root.query.length > 0) return
            if (!songId) return
            for (let i = 0; i < root.filteredSongs.length; i++) {
                if (root.filteredSongs[i].id === songId) {
                    list.positionViewAtIndex(i, ListView.Contain)
                    AppState.setLibraryFluid(root.tabKey, i)
                    break
                }
            }
        }
    }
}
