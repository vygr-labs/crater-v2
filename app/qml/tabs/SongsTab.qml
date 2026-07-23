import QtQuick
import QtQuick.Controls.Basic

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

    // Debounced shadow of query — coalesces fast typing into one
    // settle-then-search per ~120ms. The expensive cascade reads this
    // (filteredSongs → SongService.search FTS5 + in-memory filter sweep;
    // onFilteredSongsChanged → SongService.fetchSong (second SQL) →
    // pushLibraryPreview → PreviewPanel + ThemedMonitor re-render).
    // The TabSearchBar input itself still updates per-keystroke, so
    // typing stays instant; the consequence loop just waits a moment.
    property string _debouncedQuery: query
    Timer {
        id: queryDebounce
        interval: 120
        onTriggered: root._debouncedQuery = root.query
    }
    onQueryChanged: queryDebounce.restart()

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
        // Debounced — see `_debouncedQuery` above. Reading `root.query`
        // here would re-run FTS5 + fetchSong + preview-push per keystroke.
        const q     = root._debouncedQuery

        // Step 1 — choose the base set. Lyrics-FTS produces its own list from
        // the index; everything else starts from the full library.
        let result = []
        if (m === "lyrics" && q.length > 0) {
            // FTS5 (unicode61 tokenizer) is case-insensitive, so the
            // lowercased debounced query yields the same matches as the
            // raw input did.
            result = SongService.search(q)
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
        } else if (grp.indexOf("collection:") === 0) {
            // A specific collection is selected (id encoded in the group string).
            // Reading CollectionService.collections here registers the reactive
            // dependency so membership edits (add/remove) re-run this filter; the
            // actual member set comes from songIdsFor.
            void CollectionService.collections   // touch → reactive on collectionsChanged
            const collId = parseInt(grp.substring("collection:".length))
            const ids = CollectionService.songIdsFor(collId)
            let inColl = {}
            for (let k = 0; k < ids.length; k++) inColl[ids[k]] = true
            result = result.filter(function(s) { return s && inColl[s.id] })
        } else if (grp === "collections") {
            // The "My Collections" container row isn't itself a filter (the
            // sidebar doesn't set it), but guard defensively — show nothing
            // rather than the whole library.
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
        // Subtitle composition is gated by the operator's Song > Show
        // author / Show CCLI number toggles (SettingsService). Each part
        // is independently suppressible, joined by " · " for any
        // surviving pairs. Empty when both toggles are off — ProjectionWindow
        // renders an empty subtitle cleanly.
        let subtitleParts = []
        if (SettingsService.showSongAuthor && song.author)
            subtitleParts.push(song.author)
        if (SettingsService.showSongCcli && song.ccli)
            subtitleParts.push("CCLI " + song.ccli)
        return {
            kind:     "song",
            title:    song.title,
            subtitle: subtitleParts.join(" · "),
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

    // Submenu for the "Add to Collection…" context-menu item: one row per
    // collection (adds this song) plus a "New collection…" row that creates one
    // and drops the song into it. Rebuilt reactively — reading
    // CollectionService.collections ties the parent menuItems binding to
    // collectionsChanged so the list stays current.
    function _collectionSubmenu(songId) {
        const colls = CollectionService.collections
        let items = []
        for (let i = 0; i < colls.length; i++) {
            const cid = colls[i].id   // per-iteration binding — captured correctly
            items.push({ label: colls[i].name, iconName: "folder",
                         action: function() { CollectionService.addSong(cid, songId) } })
        }
        if (colls.length > 0) items.push({ separator: true })
        items.push({ label: qsTr("New collection…"), iconName: "plus",
                     action: function() {
                         AppState.openModal("naming", {
                             title:       qsTr("New collection"),
                             placeholder: qsTr("Collection name"),
                             confirmText: qsTr("Create"),
                             onConfirm:   function(name) {
                                 const id = CollectionService.create(name)
                                 if (id > 0) CollectionService.addSong(id, songId)
                             }
                         })
                     } })
        return items
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
                radius: 0
                color: addMa.containsMouse ? Theme.color.raised : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

                AppIcon {
                    anchors.centerIn: parent
                    name: "plus"
                    color: addMa.containsMouse ? Theme.color.textPrimary : Theme.color.textSecondary
                    size: Theme.icon.sm
                    Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
                }

                MouseArea {
                    id: addMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    // Open the full editor directly (matches electron's "+"
                    // entry point). Omitting songId puts the editor in
                    // create mode; Save persists via createWithSections.
                    onClicked: AppState.openModal("songEditor", {})
                }
            }

            // Import from EasyWorship — opens the import dialog.
            Rectangle {
                id: importBtn
                width: 28; height: 22
                radius: 0
                color: importMa.containsMouse ? Theme.color.raised : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

                AppIcon {
                    anchors.centerIn: parent
                    name: "download"
                    color: importMa.containsMouse ? Theme.color.textPrimary : Theme.color.textSecondary
                    size: Theme.icon.sm
                    Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
                }

                MouseArea {
                    id: importMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: AppState.openModal("import", {})
                }
            }

            // ⚙ + chevron — opens the gear menu (sort, refresh, edit/delete current).
            Rectangle {
                id: gearBtn
                width: 36; height: 22
                radius: 0
                color: gearMa.containsMouse ? Theme.color.raised : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

                Row {
                    anchors.centerIn: parent
                    spacing: 2
                    AppIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "settings"
                        color: gearMa.containsMouse ? Theme.color.textPrimary : Theme.color.textSecondary
                        size: Theme.icon.sm
                        Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
                    }
                    AppIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "chevron-down"
                        color: Theme.color.textSecondary
                        size: Theme.icon.tiny
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
        // music-off (a slashed music note) would read more clearly as
        // "empty library" than the standard music glyph — but it isn't in
        // the bundled lucide.ttf. Fall back to plain music until the font
        // is refreshed.
        iconName: "music"
        title: qsTr("No Songs Yet")
        body: qsTr("Import songs from a file or create them manually to get started")
    }
    // Borderless "Add Your First Song" CTA. Sits just below vertical center
    // so it lines up with the EmptyState above it. We don't reuse
    // PrimaryButton here because a filled brand chip competes with the
    // empty-state's centered icon+title — the design wants the CTA to read
    // as a quiet text link, not a primary action button.
    Item {
        anchors.top: actionBar.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        visible: SongService.allSongs.length === 0

        Item {
            id: addFirstCta
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.verticalCenter
            anchors.topMargin: Theme.space.xl
            implicitWidth: ctaRow.implicitWidth + Theme.space.lg * 2
            implicitHeight: 36

            Row {
                id: ctaRow
                anchors.centerIn: parent
                spacing: Theme.space.md

                AppIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "plus"
                    color: ctaMa.containsMouse ? Theme.color.textPrimary
                                               : Theme.color.textSecondary
                    size: Theme.icon.md
                    Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Add Your First Song")
                    color: ctaMa.containsMouse ? Theme.color.textPrimary
                                               : Theme.color.textSecondary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize
                    font.weight: Theme.font.weightMedium
                    Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
                }
            }

            MouseArea {
                id: ctaMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                // Open the editor directly so the empty library funnel matches
                // electron's first-run flow (title + lyrics + theme in one step).
                onClicked: AppState.openModal("songEditor", {})
            }
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
            radius: 0
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
                    size: Theme.icon.sm
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Clear search")
                    color: Theme.color.textSecondary
                    font.family: Theme.font.family
                    font.pixelSize: 14
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
        ScrollBar.vertical: AppScrollBar {}
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
            width: list.width - Theme.size.scrollBar   // leave the scrollbar its lane
            // 36px matches electron's virtualizer row height (estimateSize: 36
            // + py-2 padding). Title at 14px + author at 12px fit because the
            // Column is verticalCenter-anchored and Qt's font metrics leave
            // ~3px of slack each side.
            height: 36

            readonly property bool _selected: list.currentIndex === index
            // True while the library pane owns keyboard focus. When focus
            // moves to Schedule / Preview / Live, the selected row wash
            // mutes to neutral gray (matches ScriptureTab convention).
            readonly property bool _paneFocused: AppState.activeFocusPanel === "library"
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

            // Edge-to-edge background — no border, no radius. Selected wash
            // is brand-tinted (deep cyan) when library focused, neutral gray
            // when not — matches ScriptureTab convention so all library tabs
            // share the same focus-mute semantics. Hover wash is the same
            // brand-rgba regardless of focus (transient state, doesn't need
            // to mute).
            Rectangle {
                anchors.fill: parent
                radius: 0
                color: songRow._selected
                       ? (songRow._paneFocused ? Theme.color.brandSubtle
                                               : Theme.color.selectionUnfocused)
                     : rowMa.containsMouse ? Theme.color.rowHoverBrand
                                           : "transparent"
                // No Behavior on color — same reason ScriptureTab's row
                // dropped its 150ms ColorAnimation: rapid arrow-key
                // navigation through dense library lists left a trail of
                // mid-fade rows in different opacities at the same time,
                // reading as a smear. Snap-to-color is the cleaner
                // navigation feel.
            }

            // The redundant "music" lead icon was dropped — the tab itself
            // already announces "this list is songs," so a glyph repeating
            // it on every row was just chrome. The favorite affordance
            // (previously folded into this same lead icon) moves to the
            // right side as a heart, matching the MediaTab list pattern.
            //
            // Brand-accent bar on the left replaces the icon's other job
            // ("this row is the focus") — same treatment ScriptureTab
            // uses post-icon-removal so all library tabs share one
            // selection-anchor language.
            Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: 2
                color: Theme.color.brand
                visible: songRow._selected
                opacity: songRow._paneFocused ? 1.0 : 0.5
            }

            // Right-side cluster — favorite heart (when applicable) +
            // LIVE pill (when applicable), in that reading order. Single
            // Row keeps spacing consistent and lets the title's right
            // edge anchor to the cluster's left.
            Row {
                id: rowRight
                anchors.right: parent.right
                anchors.rightMargin: Theme.space.md
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.space.xs

                AppIcon {
                    visible: modelData.isFavorite
                    anchors.verticalCenter: parent.verticalCenter
                    name: "heart"
                    size: Theme.icon.sm
                    color: Theme.color.brand
                }

                // LIVE pill — visible only when this row is on the
                // projector. Re-uses the broadcast `live` color so it
                // reads the same as the global LIVE indicators elsewhere.
                Rectangle {
                    id: livePill
                    visible: songRow._isLive
                    anchors.verticalCenter: parent.verticalCenter
                    implicitWidth: liveText.implicitWidth + 10
                    implicitHeight: 14
                    radius: 0
                    color: Theme.color.live

                    Text {
                        id: liveText
                        anchors.centerIn: parent
                        text: "LIVE"
                        // White on the crimson `live` pill — matches the
                        // LivePanel LIVE indicator. (Was `brandInk`, dark
                        // navy → only ~2.5:1 on red in every theme.)
                        color: "#ffffff"
                        font.family: Theme.font.monoFamily
                        font.pixelSize: 11
                        font.weight: Theme.font.weightBold
                    }
                }
            }

            Column {
                // Anchored to the row's left edge with Theme.space.lg
                // padding — slightly more generous than the old icon's
                // leftMargin so the title breathes against the wash edge
                // and doesn't sit directly against the 2 px accent bar
                // when a row is selected. Same pattern ScriptureTab uses.
                anchors.left: parent.left
                anchors.leftMargin: Theme.space.lg
                anchors.right: rowRight.left
                anchors.rightMargin: Theme.space.sm
                anchors.verticalCenter: parent.verticalCenter
                spacing: 0

                Text {
                    text: modelData.title
                    color: songRow._selected ? Theme.color.textPrimary
                                             : Theme.color.textTitle
                    font.family: Theme.font.family
                    font.pixelSize: 16
                    font.weight: songRow._selected ? Theme.font.weightMedium
                                                   : Theme.font.weightRegular
                    elide: Text.ElideRight
                    width: parent.width
                }
                Text {
                    // Combined author + CCLI subtitle. Each part is
                    // independently suppressible via Appearance settings;
                    // " · " separator only appears when both survive.
                    visible: text.length > 0
                    text: {
                        const parts = []
                        if (modelData.author && modelData.author.length > 0)
                            parts.push(modelData.author)
                        if (SettingsService.showCcli
                            && modelData.ccli && modelData.ccli.length > 0)
                            parts.push("CCLI " + modelData.ccli)
                        return parts.join(" · ")
                    }
                    color: songRow._selected ? Theme.color.textSecondary
                                             : Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: 14
                    elide: Text.ElideRight
                    width: parent.width
                }
            }

            RightClickArea {
                id: rowMa
                anchors.fill: parent
                // Group order: row-edit actions first (Edit / Duplicate),
                // then projection actions (Add to Schedule / Push to Live),
                // then library-organization (Favorite / Collection), then
                // destructive (Delete). Edit-first matches the most common
                // right-click intent on a song row ("I want to change this
                // song") and parks the destructive option at the bottom
                // where slip-clicks are least likely.
                menuItems: [
                    { label: qsTr("Edit Song"), iconName: "edit", kbd: "E",
                      action: function() {
                          AppState.openModal("songEditor", { songId: modelData.id })
                      } },
                    { label: qsTr("Duplicate Song"), iconName: "copy",
                      action: function() { SongService.duplicate(modelData.id) } },
                    { separator: true },
                    { label: qsTr("Add to Schedule"), iconName: "plus",
                      action: function() { root.addToScheduleFor(index) } },
                    { label: qsTr("Push to Live"),    iconName: "play",
                      action: function() { root.pushLiveFor(index) } },
                    { separator: true },
                    { label: modelData.isFavorite
                            ? qsTr("Remove from Favorites")
                            : qsTr("Add to Favorites"),
                      iconName: modelData.isFavorite ? "heart-off" : "heart",
                      action: function() { SongService.toggleFavorite(modelData.id) } },
                    { label: qsTr("Add to Collection…"), iconName: "folder",
                      submenu: root._collectionSubmenu(modelData.id) },
                    // Only when viewing a specific collection: let the operator
                    // pull this song back out of it.
                    ...(root.group.indexOf("collection:") === 0 ? [{
                        label: qsTr("Remove from Collection"), iconName: "x",
                        action: function() {
                            const cid = parseInt(root.group.substring("collection:".length))
                            CollectionService.removeSong(cid, modelData.id)
                        }
                    }] : []),
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
                    // See ScriptureTab._focus for why we also claim the
                    // library focus here — row click → arrow keys should
                    // walk this list, not the preview/live cards.
                    AppState.setActiveFocus("library")
                    root.pushPreviewFor(index)
                }
                onLeftClicked:  _focus()
                onRightClicked: _focus()
                onDoubleClicked: {
                    AppState.setLibraryFluid(root.tabKey, index)
                    AppState.setActiveFocus("library")
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
