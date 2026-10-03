import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts

// Left side of the bottom row — search input plus the group navigation.
// The group list is tab-specific: Songs shows All/Favorites/Collections,
// Scripture shows Bible versions, etc.
Rectangle {
    id: root

    // Slight tonal differentiation from canvas — mirrors electron's
    // sidebar `bg="gray.950/50"` (a translucent dark composited onto the
    // page bg). On Qt we just pick the resulting near-equal color.
    color: Theme.color.bgSidebar

    readonly property string currentTabKey: AppState.tabKeys[AppState.activeTab]

    readonly property string searchPlaceholder: {
        switch (currentTabKey) {
            case "songs":     return qsTr("Search in lyrics…")
            case "scripture": return qsTr("Search verses…")
            case "strongs":   return qsTr("Search Strong's…")
            case "media":     return qsTr("Search media…")
            case "presentations": return qsTr("Search decks…")
            case "themes":    return qsTr("Search themes…")
        }
        return qsTr("Search…")
    }

    // Local state: which parent groups are expanded in the accordion. Keyed
    // by group id. Persists across tab switches (cheap; ids are unique per
    // tab today). If that ever changes, reset on activeTab change via a
    // Connections { target: AppState; function onActiveTabChanged() { ... } }.
    property var expandedGroups: ({})

    function toggleExpanded(id) {
        let copy = Object.assign({}, expandedGroups)
        copy[id] = !copy[id]
        expandedGroups = copy
    }

    // ── Collection action-strip helpers (Songs tab) ─────────────────────
    // The gear operates on the currently-selected collection, encoded as
    // "collection:<id>" in activeLibraryGroup.songs. Returns { id, name } or
    // null when the active group isn't a specific collection.
    function _selectedCollection() {
        const g = AppState.activeLibraryGroup["songs"] || ""
        if (g.indexOf("collection:") !== 0) return null
        const cid = parseInt(g.substring("collection:".length))
        const colls = CollectionService.collections
        for (let i = 0; i < colls.length; i++)
            if (colls[i].id === cid) return { id: colls[i].id, name: colls[i].name }
        return null
    }

    function _promptNewCollection() {
        AppState.openModal("naming", {
            title:       qsTr("New collection"),
            placeholder: qsTr("Collection name"),
            confirmText: qsTr("Create"),
            onConfirm:   function(name) {
                const id = CollectionService.create(name)
                if (id > 0) {
                    // Expand the container + select the new collection so it's
                    // immediately visible and active.
                    let copy = Object.assign({}, root.expandedGroups)
                    copy["collections"] = true
                    root.expandedGroups = copy
                    AppState.setLibraryGroup("songs", "collection:" + id)
                }
            }
        })
    }

    function _openCollectionMenu(originItem) {
        const coll = root._selectedCollection()
        if (!coll) return
        const items = [
            { label: qsTr("Rename"), iconName: "edit",
              action: function() {
                  AppState.openModal("naming", {
                      title:        qsTr("Rename collection"),
                      placeholder:  qsTr("Collection name"),
                      confirmText:  qsTr("Save"),
                      initialValue: coll.name,
                      onConfirm:    function(name) { CollectionService.rename(coll.id, name) }
                  })
              } },
            { label: qsTr("Duplicate"), iconName: "copy",
              action: function() { CollectionService.duplicate(coll.id) } },
            { separator: true },
            { label: qsTr("Delete"), iconName: "trash", destructive: true,
              action: function() {
                  AppState.openModal("confirm", {
                      title:       qsTr("Delete collection?"),
                      body:        qsTr("This removes the collection \"") + coll.name
                                 + qsTr("\". The songs themselves are not deleted."),
                      confirmText: qsTr("Delete"),
                      onConfirm:   function() {
                          CollectionService.destroy(coll.id)
                          // Fall back to All Songs if the deleted collection was
                          // the active filter, so the list isn't stuck on it.
                          if ((AppState.activeLibraryGroup["songs"] || "") === "collection:" + coll.id)
                              AppState.setLibraryGroup("songs", "all-songs")
                      }
                  })
              } }
        ]
        // Body auto-clamps upward to stay on-screen (PopoverMenu.qml:158).
        AppState.openContextMenuAt(originItem, 0, originItem.height + 4, items, { menuWidth: 180 })
    }

    // ── Translation order and visibility ────────────────────────────────
    // The Bible library is shared by every profile; each profile picks which
    // translations it shows and in what order (SettingsService
    // translationOrder / hiddenTranslations, applied by BibleService). The
    // grid lists this profile's translations. Hidden ones sit behind a
    // "More" card, and a hidden one the operator picks from there shows as
    // an extra card while it's active. Drag a card onto another, or use its
    // right-click menu.
    property int _dragFrom: -1
    property int _dragTo:   -1

    // The cards that take part in ordering: this profile's own list, not
    // the More card or a hidden translation that's only on show for now.
    function _translationOrder() {
        const out = []
        for (let i = 0; i < groups.length; i++)
            if (!groups[i].more && !groups[i].temporary) out.push(String(groups[i].label))
        return out
    }

    function _hideTranslation(code) {
        const hidden = SettingsService.hiddenTranslations.slice()
        if (hidden.indexOf(code) < 0) hidden.push(code)
        SettingsService.hiddenTranslations = hidden
    }

    function _showTranslation(code) {
        const up = String(code).toUpperCase()
        SettingsService.hiddenTranslations = SettingsService.hiddenTranslations
            .filter(function(c) { return String(c).toUpperCase() !== up })
    }

    // The More card: every hidden translation. Picking one reads it now
    // without changing the profile; "Show" puts it back in the list.
    function _moreMenu(card) {
        const all = BibleService.allTranslations()
        const items = []
        for (let i = 0; i < all.length; i++) {
            const t = all[i]
            if (!t.hidden) continue
            items.push({ label: String(t.code), detail: String(t.description || ""),
                         action: function() {
                             AppState.setLibraryGroup("scripture", String(t.code).toLowerCase())
                         } })
        }
        items.push({ separator: true })
        items.push({ label: qsTr("Choose translations…"), iconName: "settings",
                     action: function() {
                         AppState.settingsSection = "scripture"
                         AppState.openModal("settings", {})
                     } })
        AppState.openContextMenuAt(card, 0, card.height + 4, items, { menuWidth: 220 })
    }

    // Move the card at `from` so it ends up at index `to`.
    function _moveTranslation(from, to) {
        const codes = _translationOrder()
        if (from < 0 || from >= codes.length) return
        to = Math.max(0, Math.min(codes.length - 1, to))
        if (from === to) return
        const code = codes.splice(from, 1)[0]
        codes.splice(to, 0, code)
        SettingsService.translationOrder = codes
    }

    function _sortTranslationsAtoZ() {
        const codes = _translationOrder()
        codes.sort(function(a, b) { return a.localeCompare(b) })
        SettingsService.translationOrder = codes
    }

    // Index of the version card under a scene point, or -1.
    function _cardIndexAt(sceneX, sceneY) {
        if (sceneX < 0) return -1
        const p = versionGrid.mapFromItem(null, sceneX, sceneY)
        for (let i = 0; i < versionRepeater.count; i++) {
            const it = versionRepeater.itemAt(i)
            if (it && p.x >= it.x && p.x < it.x + it.width
                   && p.y >= it.y && p.y < it.y + it.height)
                return i
        }
        return -1
    }

    function _translationMenu(card, index, x, y) {
        const g = groups[index]
        if (!g || g.more) return
        const code = String(g.label)
        // A hidden translation on show for now: offer to put it back.
        if (g.temporary) {
            AppState.openContextMenuAt(card, x, y, [
                { label: qsTr("Show in This Profile"), iconName: "eye",
                  action: function() { root._showTranslation(code) } }
            ], { menuWidth: 200 })
            return
        }
        const last = _translationOrder().length - 1
        AppState.openContextMenuAt(card, x, y, [
            { label: qsTr("Move Earlier"), iconName: "arrow-left", enabled: index > 0,
              action: function() { root._moveTranslation(index, index - 1) } },
            { label: qsTr("Move Later"), iconName: "arrow-right", enabled: index < last,
              action: function() { root._moveTranslation(index, index + 1) } },
            { label: qsTr("Move to Start"), iconName: "align-start-vertical", enabled: index > 0,
              action: function() { root._moveTranslation(index, 0) } },
            { label: qsTr("Move to End"), iconName: "align-end-vertical", enabled: index < last,
              action: function() { root._moveTranslation(index, last) } },
            { separator: true },
            { label: qsTr("Sort A to Z"), iconName: "arrow-down-az",
              action: function() { root._sortTranslationsAtoZ() } },
            // Keep at least one: a profile has to be able to read something.
            { label: qsTr("Hide from This Profile"), iconName: "eye-off", enabled: last > 0,
              action: function() { root._hideTranslation(code) } }
        ], { menuWidth: 200 })
    }

    readonly property var groups: {
        switch (currentTabKey) {
            case "songs": {
                const songs = SongService.allSongs
                const favCount = songs.filter(function(s) { return s.isFavorite }).length
                // Real collections drive the "My Collections" subgroups now.
                // Each carries id "collection:<n>" so the single per-tab group
                // string (activeLibraryGroup.songs) can encode which collection
                // is selected — SongsTab parses it back out to filter.
                const colls = CollectionService.collections
                let subs = []
                for (let i = 0; i < colls.length; i++) {
                    subs.push({ id:       "collection:" + colls[i].id,
                                iconName: "folder",
                                label:    colls[i].name,
                                count:    colls[i].songCount })
                }
                // All three top rows use the folder glyph so the sidebar reads
                // as a flat list of containers.
                return [
                    { id: "all-songs",   iconName: "folder", label: qsTr("All Songs"),      count: songs.length,  subgroups: [] },
                    { id: "favorites",   iconName: "folder", label: qsTr("My Favorites"),   count: favCount,      subgroups: [] },
                    { id: "collections", iconName: "folder", label: qsTr("My Collections"), count: colls.length,  subgroups: subs }
                ]
            }
            case "scripture": {
                // One entry per installed translation, each rendered as a
                // VersionCard in the scripture tab's version grid (see the
                // ScrollView body below). Code is uppercased ("KJV") for
                // display; id is lowercased to match the
                // AppState.activeLibraryGroup convention. iconName/count stay
                // at no-op values — the card reads only id + label, but
                // keeping the shape uniform lets every tab share `groups`.
                BibleService.translationsRevision   // re-read after a change
                let r = []
                const tl = BibleService.translations()
                for (let i = 0; i < tl.length; i++) {
                    const t = tl[i]
                    r.push({ id: (t.code || "").toLowerCase(),
                             iconName: "",
                             label: t.code,
                             count: 0 })
                }
                // Hidden in this profile: reachable from the More card. One
                // the operator picked from there stays on show while active.
                const active = String(AppState.activeLibraryGroup["scripture"] || "")
                const all = BibleService.allTranslations()
                let hiddenCount = 0
                for (let i = 0; i < all.length; i++) {
                    if (!all[i].hidden) continue
                    hiddenCount++
                    const id = String(all[i].code).toLowerCase()
                    if (id === active)
                        r.push({ id: id, iconName: "", label: all[i].code, count: 0, temporary: true })
                }
                if (hiddenCount > 0)
                    r.push({ id: "__more", iconName: "", label: qsTr("More…"), count: 0, more: true })
                return r
            }
            case "strongs": return [
                { id: "greek",  iconName: "book", label: qsTr("Greek"),  count: 0 },
                { id: "hebrew", iconName: "book", label: qsTr("Hebrew"), count: 0 }
            ]
            case "media": {
                // Count from MediaService.allMedia (Q_PROPERTY re-emits on
                // import / delete / favorite toggle, so the counts stay live).
                const all  = MediaService.allMedia
                let imgN   = 0
                let vidN   = 0
                let pdfN   = 0
                let favN   = 0
                for (let i = 0; i < all.length; i++) {
                    const m = all[i]
                    if (!m) continue
                    if (m.type === "image") imgN++
                    if (m.type === "video") vidN++
                    if (m.type === "pdf")   pdfN++
                    if (m.isFavorite)       favN++
                }
                return [
                    { id: "all-media", iconName: "folder", label: qsTr("All Media"), count: all.length },
                    { id: "images",    iconName: "image",  label: qsTr("Images"),    count: imgN },
                    { id: "videos",    iconName: "video",  label: qsTr("Videos"),    count: vidN },
                    { id: "pdfs",      iconName: "file-text", label: qsTr("PDFs"),   count: pdfN },
                    { id: "favorites", iconName: "heart",  label: qsTr("Favorites"), count: favN }
                ]
            }
            case "presentations": {
                // One group. A deck library has no natural sub-division the
                // way media splits by type or themes split by builtin —
                // decks are all the same shape, and the search box above
                // does the narrowing. A row is still worth showing because
                // it carries the live count.
                return [
                    { id: "all-presentations", iconName: "presentation",
                      label: qsTr("All Decks"),
                      count: PresentationService.presentations.length }
                ]
            }
            case "themes": {
                const themes = ThemeService.allThemes
                const presetCount = themes.filter(function(t) { return t.isBuiltin }).length
                const customCount = themes.length - presetCount
                return [
                    { id: "all-themes", iconName: "palette", label: qsTr("All Themes"), count: themes.length },
                    { id: "custom",     iconName: "palette", label: qsTr("Custom"),     count: customCount },
                    { id: "presets",    iconName: "palette", label: qsTr("Presets"),    count: presetCount }
                ]
            }
        }
        return []
    }

    // Per-tab search bar — pinned at the top of the sidebar so it stays
    // visible while the group list below scrolls.
    TabSearchBar {
        id: searchBar
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: Theme.space.md
        anchors.leftMargin: Theme.space.lg
        anchors.rightMargin: Theme.space.lg
    }

    // Scroll container for the sidebar group list. Scripture renders its
    // versions as a compact card grid (versionGrid); every other tab keeps
    // the 1-per-row accordion. The grid usually fits ~14 translations
    // without scrolling, but the container stays so a short window — or a
    // larger installed-translation set — still scrolls. Songs/Themes are
    // short today and ride the same container at zero cost. The ScrollBar
    // is interactive so a trackpad gesture works too.
    ScrollView {
        id: groupScroll
        anchors.top: searchBar.bottom
        anchors.topMargin: Theme.space.sm
        // Sidebar action bar sits at the bottom for Songs (currently); other
        // tabs leave it invisible so the scroll runs to the sidebar's edge.
        anchors.bottom: actionBar.visible ? actionBar.top : parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.rightMargin: 1   // leave room for the right-edge divider
        clip: true
        // Themed bar to match the rest of the tabs/panels (AppScrollBar is
        // AsNeeded itself); keep the horizontal one off.
        ScrollBar.vertical: AppScrollBar {}
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

        // One content child so ScrollView has a single, unambiguous item to
        // size its scroll extent to. It hosts both layouts; only the one for
        // the current tab is populated (the other's Repeater model is left
        // empty) and implicitHeight tracks whichever is live.
        Item {
            id: groupContent
            width: groupScroll.availableWidth

            readonly property bool isScripture: root.currentTabKey === "scripture"

            implicitHeight: isScripture
                          ? versionGrid.implicitHeight + Theme.space.sm
                          : accordion.implicitHeight

            // ── Scripture: Bible-version card grid ──────────────────────
            // Codes are short ("KJV", "NASB2020"), so a compact 4-column
            // card grid shows several versions per row where the old
            // full-width rows showed one. Selecting routes through
            // AppState.setLibraryGroup and double-click fires
            // requestPushLiveInTranslation — the exact wiring the rows had.
            Grid {
                id: versionGrid
                visible: groupContent.isScripture
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Theme.space.sm
                anchors.rightMargin: Theme.space.sm
                columnSpacing: Theme.space.xs
                rowSpacing: Theme.space.xs

                // Fixed 4-up grid. The sidebar is a constant fraction of
                // the window width, so 4 columns stay proportional as the
                // window resizes; cellWidth below distributes the row.
                columns: 4
                readonly property real cellWidth:
                    Math.max(0, Math.floor((width - columnSpacing * (columns - 1)) / columns))

                Repeater {
                    id: versionRepeater
                    // Emptied for non-scripture tabs so no cards are built
                    // while the accordion is the visible layout.
                    model: groupContent.isScripture ? root.groups : []
                    delegate: VersionCard {
                        required property var modelData
                        required property int index
                        width: versionGrid.cellWidth
                        height: Theme.d(36)
                        label: modelData.label
                        active: AppState.activeLibraryGroup["scripture"] === modelData.id
                        // The bar sits on the side the card will land: after
                        // the target when moving later, before it otherwise.
                        // The More card and a hidden-for-now card sit after
                        // the profile's list and never take part in a drag.
                        readonly property bool _ordered: !modelData.more && !modelData.temporary
                        muted: !!modelData.more || !!modelData.temporary
                        draggable: _ordered
                        dropSide: (_ordered && root._dragFrom >= 0 && root._dragTo === index
                                   && root._dragTo !== root._dragFrom)
                                  ? (root._dragFrom < index ? 1 : -1) : 0
                        onDragMoved: function(sx, sy) {
                            root._dragFrom = index
                            const to = root._cardIndexAt(sx, sy)
                            const g = to >= 0 ? root.groups[to] : null
                            root._dragTo = (g && !g.more && !g.temporary) ? to : -1
                        }
                        onDragEnded: function(sx, sy) {
                            const to = root._dragTo
                            const from = index
                            root._dragFrom = -1
                            root._dragTo = -1
                            if (to >= 0) root._moveTranslation(from, to)
                        }
                        onContextMenuRequested: function(x, y) {
                            root._translationMenu(this, index, x, y)
                        }
                        onClicked: {
                            if (modelData.more) { root._moreMenu(this); return }
                            AppState.setLibraryGroup("scripture", modelData.id)
                        }
                        onDoubleClicked: {
                            if (modelData.more) return
                            // Switch translation, then ask ScriptureTab to
                            // push the focused verse Live in it — only that
                            // tab knows which verse the operator has focused.
                            AppState.setLibraryGroup("scripture", modelData.id)
                            AppState.requestPushLiveInTranslation(modelData.label)
                        }
                    }
                }
            }

            // ── Songs / Strong's / Media / Themes: 1-per-row accordion ──
            ColumnLayout {
                id: accordion
                visible: !groupContent.isScripture
                width: groupScroll.availableWidth
                spacing: Theme.space.xs

                Repeater {
                    model: groupContent.isScripture ? [] : root.groups
                    delegate: ColumnLayout {
                        // Parent row + optional indented sub-rows. Today subgroups
                        // are always [] in production data (CollectionService is
                        // deferred), so this collapses visually to a plain row —
                        // the accordion structure ships ready for collections.
                        id: groupBlock
                        Layout.fillWidth: true
                        spacing: 0

                        // Coerce to strict bool — `modelData.subgroups && …` returns
                        // `undefined` when subgroups is missing (instead of false),
                        // which QML's `bool` property type rejects with thousands
                        // of "Unable to assign [undefined] to bool" warnings.
                        readonly property bool hasSubs: !!(modelData.subgroups && modelData.subgroups.length > 0)
                        readonly property bool isExpanded: !!root.expandedGroups[modelData.id]

                        LibraryRow {
                            Layout.fillWidth: true
                            iconName: modelData.iconName
                            label:    modelData.label
                            count:    modelData.count
                            active:   AppState.activeLibraryGroup[root.currentTabKey] === modelData.id
                            bgRadius: 0
                            onClicked: {
                                // Parents with subgroups also toggle their expansion
                                // on click so the operator can drill into collections
                                // without a separate chevron target.
                                if (groupBlock.hasSubs) root.toggleExpanded(modelData.id)
                                // "My Collections" is a pure container, not a filter —
                                // clicking it only expands/collapses; the individual
                                // collections below are the real filter targets. Skip
                                // setting the group so the song list doesn't jump to
                                // an empty container view.
                                if (root.currentTabKey === "songs" && modelData.id === "collections") return
                                if (root.currentTabKey === "media") {
                                    AppState.setMediaGroup(modelData.id)
                                } else {
                                    AppState.setLibraryGroup(root.currentTabKey, modelData.id)
                                }
                            }
                        }

                        // Indented sub-rows for collections (when present + parent
                        // expanded). Each sub-row is a child LibraryRow with indent.
                        Repeater {
                            model: groupBlock.hasSubs && groupBlock.isExpanded
                                 ? modelData.subgroups : []
                            delegate: LibraryRow {
                                Layout.fillWidth: true
                                indent: Theme.space.md
                                iconName: modelData.iconName || ""
                                label:    modelData.label || ""
                                count:    modelData.count || 0
                                // Sub-row "active" key follows the modelData.id —
                                // CollectionService will provide unique ids.
                                active:   AppState.activeLibraryGroup[root.currentTabKey] === modelData.id
                                onClicked: AppState.setLibraryGroup(root.currentTabKey, modelData.id)
                            }
                        }
                    }
                }
            }
        }
    }

    // Bottom strip — per-tab quick actions (electron parity:
    // SelectionGroups.tsx ships a `<HStack h={6} bg="gray.800">` at the bottom
    // hosting each tab's `actionMenus`). Songs gets "+ ⚙" for collection
    // management (create / rename / duplicate / delete); other tabs leave the
    // strip invisible until they have actions worth shipping. The scroll
    // container above adjusts its bottom anchor.
    Rectangle {
        id: actionBar
        // Songs only: "+" creates a collection, the gear manages the selected
        // one. Other tabs keep the strip hidden (no actions worth shipping).
        visible: root.currentTabKey === "songs"
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.rightMargin: 1   // leave room for the right-edge divider
        height: 24
        color: Theme.color.elevated

        Rectangle {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: 1
            color: Theme.color.borderSubtle
        }

        Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: 0

            // + (new collection) — opens the naming modal to create one, then
            // expands + selects it (see root._promptNewCollection).
            Rectangle {
                width: 36; height: 22
                radius: 0
                color: addCollectionMa.containsMouse ? Theme.color.raised : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

                AppIcon {
                    anchors.centerIn: parent
                    name: "plus"
                    color: Theme.color.textSecondary
                    size: Theme.icon.sm
                }
                MouseArea {
                    id: addCollectionMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root._promptNewCollection()
                }
            }

            // ⚙ Rename / Duplicate / Delete for the selected collection
            // (root._openCollectionMenu). Dimmed + inert when no collection
            // is the active filter.
            Rectangle {
                id: gearBtnRect
                width: 36; height: 22
                radius: 0
                // Gear only does something when a specific collection is
                // selected — dim it otherwise so it reads as inactive.
                readonly property bool _hasSel: !!root._selectedCollection()
                color: (_hasSel && gearCollectionMa.containsMouse) ? Theme.color.raised : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

                AppIcon {
                    anchors.centerIn: parent
                    name: "settings"
                    color: Theme.color.textSecondary
                    size: Theme.icon.sm
                    opacity: gearBtnRect._hasSel ? 1.0 : 0.4
                }
                MouseArea {
                    id: gearCollectionMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: gearBtnRect._hasSel ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: root._openCollectionMenu(gearBtnRect)
                }
            }
        }
    }

    // Right divider
    Rectangle {
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 1
        color: Theme.color.borderSubtle
    }
}
