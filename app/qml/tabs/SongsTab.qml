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
    readonly property string query:  (AppState.searchText.songs || "").toLowerCase()
    readonly property string mode:   AppState.librarySearchMode.songs || "lyrics"
    readonly property string group:  AppState.activeLibraryGroup.songs

    // ── Filtered + sorted song list ─────────────────────────────────────
    // Mode semantics mirror SongSelection.tsx:
    //   title  ─ substring match against title
    //   lyrics ─ FTS5 search (SongService.search) when query present,
    //            otherwise all songs
    //   author ─ substring against author
    //   recent / oldest / newest ─ sort variants (date fields not yet
    //            exposed on Song; falls back to id-based ordering so the
    //            UX is preserved until the value type grows timestamps)
    readonly property var filteredSongs: {
        const all   = SongService.allSongs    // tracked for reactivity
        const grp   = root.group
        const m     = root.mode
        const q     = root.query
        let base    = []

        for (let i = 0; i < all.length; i++) {
            const s = all[i]
            if (!s) continue
            if (grp === "favorites" && !s.isFavorite) continue
            if (grp === "collections") continue
            base.push(s)
        }

        let result = base

        if (m === "title" && q.length > 0) {
            result = base.filter(function(s) {
                return (s.title || "").toLowerCase().indexOf(q) !== -1
            })
        } else if (m === "lyrics" && q.length > 0) {
            // FTS5 trigram search. Returns metadata-only Song rows.
            const hits = SongService.search(AppState.searchText.songs || "")
            // When filtering by collection group (deferred), narrow the hits.
            result = hits
        } else if (m === "author" && q.length > 0) {
            result = base.filter(function(s) {
                return (s.author || "").toLowerCase().indexOf(q) !== -1
            })
        } else if (m === "recent" || m === "oldest" || m === "newest") {
            // Fallback to id ordering until Song carries created_at / updated_at.
            // For "recent"/"newest" we want descending id, "oldest" ascending.
            result = base.slice().sort(function(a, b) {
                return m === "oldest" ? (a.id - b.id) : (b.id - a.id)
            })
            if (q.length > 0) {
                result = result.filter(function(s) {
                    return (s.title || "").toLowerCase().indexOf(q) !== -1
                })
            }
        }

        // Project to a render-friendly shape so the delegate doesn't re-bind
        // into the Song value type.
        let out = []
        for (let j = 0; j < result.length; j++) {
            const s = result[j]
            out.push({
                id:         s.id,
                title:      s.title,
                author:     s.author || "",
                isFavorite: s.isFavorite,
                ccli:       s.ccli || ""
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
            songId:   song.id
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

    function isLiveSong(id) {
        // A song is "live" if it's currently on projection and the live item
        // came from the library and shares this song id.
        if (!AppState.libraryLiveActive) return false
        const live = AppState.libraryPreviewItem
        return live && live.songId === id
    }

    // ── Top action bar ──────────────────────────────────────────────────
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

        // Left side: + button (add new) — bordered to read as a primary action.
        Rectangle {
            id: addBtn
            anchors.left: parent.left
            anchors.leftMargin: Theme.space.md
            anchors.verticalCenter: parent.verticalCenter
            width: 36; height: 22
            radius: 4
            color: addMa.containsMouse ? Theme.color.overlay : "transparent"
            border.color: Theme.color.borderStrong
            border.width: 1
            Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

            AppIcon {
                anchors.centerIn: parent
                name: "plus"
                color: Theme.color.textSecondary
                size: 13
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

        // Right side: gear menu — sort by, refresh, edit/delete current.
        Rectangle {
            id: gearBtn
            anchors.right: parent.right
            anchors.rightMargin: Theme.space.md
            anchors.verticalCenter: parent.verticalCenter
            width: 42; height: 22
            radius: 4
            color: gearMa.containsMouse ? Theme.color.overlay : "transparent"
            Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

            Row {
                anchors.centerIn: parent
                spacing: 2
                AppIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "settings"
                    color: Theme.color.textSecondary
                    size: 13
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
                        items.push({ label: qsTr("Edit Song"), iconName: "edit",
                            action: function() {
                                AppState.openModal("songEditor", { songId: focusedSong.id })
                            }})
                        items.push({ label: qsTr("Duplicate Song"), iconName: "copy" })
                        items.push({ separator: true })
                        items.push({ label: qsTr("Delete Song"), iconName: "trash",
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
                    items.push({ label: qsTr("Sort by Name"),       iconName: "arrow-down-az",
                        action: function() { AppState.setLibrarySearchMode("songs", "title") }})
                    items.push({ label: qsTr("Sort by Most Recent"), iconName: "clock",
                        action: function() { AppState.setLibrarySearchMode("songs", "recent") }})
                    items.push({ label: qsTr("Sort by Newest"),     iconName: "sort-desc",
                        action: function() { AppState.setLibrarySearchMode("songs", "newest") }})
                    items.push({ label: qsTr("Sort by Oldest"),     iconName: "sort-asc",
                        action: function() { AppState.setLibrarySearchMode("songs", "oldest") }})
                    items.push({ separator: true })
                    items.push({ label: qsTr("Refresh"), iconName: "refresh-cw" })

                    const p = gearBtn.mapToItem(null, gearBtn.width, gearBtn.height + 4)
                    AppState.openModal("contextMenu", {
                        anchorX:   p.x - 200,
                        anchorY:   p.y,
                        menuWidth: 200,
                        items:     items
                    })
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
        spacing: 1
        boundsBehavior: Flickable.StopAtBounds
        currentIndex: root.fluidIndex

        // Keep currentIndex visible when fluid focus moves via keyboard.
        onCurrentIndexChanged: {
            if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
        }

        delegate: Item {
            id: songRow
            width: list.width
            height: 52

            readonly property bool _selected: list.currentIndex === index
            readonly property bool _live:     root.isLiveSong(modelData.id)

            Rectangle {
                anchors.fill: parent
                anchors.leftMargin: Theme.space.sm
                anchors.rightMargin: Theme.space.sm
                radius: Theme.radius.md
                color: songRow._selected ? Theme.color.previewSubtle
                     : rowMa.containsMouse ? Theme.color.elevated
                                           : "transparent"
                border.color: songRow._selected ? Theme.color.preview : "transparent"
                border.width: 1
                Behavior on color        { ColorAnimation { duration: Theme.motion.instant } }
                Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }
            }

            // Leading music / favorite icon
            AppIcon {
                id: leadIcon
                anchors.left: parent.left
                anchors.leftMargin: Theme.space.lg + Theme.space.sm
                anchors.verticalCenter: parent.verticalCenter
                name: modelData.isFavorite ? "heart" : "music"
                color: modelData.isFavorite ? Theme.color.brand
                     : songRow._selected   ? Theme.color.preview
                                           : Theme.color.textTertiary
                opacity: modelData.isFavorite ? 1.0 : 0.55
                size: 14
            }

            Column {
                anchors.left: leadIcon.right
                anchors.leftMargin: Theme.space.md
                anchors.right: rightStack.left
                anchors.rightMargin: Theme.space.md
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                Text {
                    text: modelData.title
                    color: songRow._selected ? Theme.color.textPrimary : Theme.color.textSecondary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize
                    font.weight: songRow._selected ? Theme.font.weightMedium : Theme.font.weightRegular
                    elide: Text.ElideRight
                    width: parent.width
                }
                Text {
                    visible: modelData.author && modelData.author.length > 0
                    text: modelData.author
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                    elide: Text.ElideRight
                    width: parent.width
                }
            }

            // Right stack: LIVE pill + CCLI badge
            Row {
                id: rightStack
                anchors.right: parent.right
                anchors.rightMargin: Theme.space.lg + Theme.space.sm
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.space.xs

                Rectangle {
                    visible: songRow._live
                    anchors.verticalCenter: parent.verticalCenter
                    width: liveLabel.implicitWidth + Theme.space.sm * 2 + livePulse.width + 4
                    height: 16
                    radius: 3
                    color: Theme.color.live

                    Row {
                        anchors.centerIn: parent
                        spacing: 4

                        Rectangle {
                            id: livePulse
                            anchors.verticalCenter: parent.verticalCenter
                            width: 5; height: 5; radius: 3
                            color: "#ffffff"
                            SequentialAnimation on opacity {
                                running: songRow._live
                                loops: Animation.Infinite
                                NumberAnimation { from: 1.0; to: 0.4; duration: 800 }
                                NumberAnimation { from: 0.4; to: 1.0; duration: 800 }
                            }
                        }
                        Text {
                            id: liveLabel
                            anchors.verticalCenter: parent.verticalCenter
                            text: qsTr("LIVE")
                            color: "#ffffff"
                            font.family: Theme.font.family
                            font.pixelSize: 9
                            font.weight: Theme.font.weightSemiBold
                            font.letterSpacing: 0.5
                        }
                    }
                }

                Rectangle {
                    visible: rowMa.containsMouse && modelData.ccli && modelData.ccli.length > 0
                    anchors.verticalCenter: parent.verticalCenter
                    width: ccliLabel.implicitWidth + Theme.space.sm * 2
                    height: 16
                    radius: 2
                    color: Theme.color.overlay

                    Text {
                        id: ccliLabel
                        anchors.centerIn: parent
                        text: "CCLI " + modelData.ccli
                        color: Theme.color.textTertiary
                        font.family: Theme.font.monoFamily
                        font.pixelSize: 9
                    }
                }
            }

            MouseArea {
                id: rowMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton | Qt.RightButton

                onClicked: function(mouse) {
                    if (mouse.button === Qt.RightButton) {
                        const p = mapToItem(null, mouse.x, mouse.y)
                        AppState.setLibraryFluid(root.tabKey, index)
                        root.pushPreviewFor(index)
                        AppState.openModal("contextMenu", {
                            anchorX: p.x,
                            anchorY: p.y,
                            menuWidth: 220,
                            items: [
                                { label: qsTr("Add to Schedule"), iconName: "plus",
                                  action: function() { root.addToScheduleFor(index) } },
                                { label: qsTr("Push to Live"),    iconName: "play",
                                  action: function() { root.pushLiveFor(index) } },
                                { separator: true },
                                { label: qsTr("Edit Song"), iconName: "edit",
                                  action: function() {
                                      AppState.openModal("songEditor", { songId: modelData.id })
                                  } },
                                { label: qsTr("Duplicate Song"), iconName: "copy" },
                                { separator: true },
                                { label: modelData.isFavorite
                                        ? qsTr("Remove from Favorites")
                                        : qsTr("Add to Favorites"),
                                  iconName: modelData.isFavorite ? "heart-off" : "heart",
                                  action: function() { SongService.toggleFavorite(modelData.id) } },
                                { label: qsTr("Add to Collection…"), iconName: "folder" },
                                { separator: true },
                                { label: qsTr("Delete Song"), iconName: "trash", destructive: true,
                                  action: function() {
                                      AppState.openModal("confirm", {
                                          title:       qsTr("Delete song?"),
                                          body:        qsTr("This permanently removes \"") + modelData.title + "\".",
                                          confirmText: qsTr("Delete"),
                                          onConfirm:   function() { SongService.destroy(modelData.id) }
                                      })
                                  } }
                            ]
                        })
                    } else {
                        AppState.setLibraryFluid(root.tabKey, index)
                        root.pushPreviewFor(index)
                    }
                }

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
    }
}
