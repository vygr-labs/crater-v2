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

    readonly property var groups: {
        switch (currentTabKey) {
            case "songs": {
                const songs = SongService.allSongs
                const favCount = songs.filter(function(s) { return s.isFavorite }).length
                // subgroups: collections placeholder. Empty until a
                // CollectionService lands; the accordion structure is in place
                // so adding collections is purely a data change downstream.
                //
                // All three rows use the folder glyph so the sidebar reads as
                // a flat list of containers — the heart glyph for Favorites
                // was visually inconsistent with Collections, which has no
                // single-noun equivalent.
                return [
                    { id: "all-songs",   iconName: "folder", label: qsTr("All Songs"),      count: songs.length, subgroups: [] },
                    { id: "favorites",   iconName: "folder", label: qsTr("My Favorites"),   count: favCount,     subgroups: [] },
                    { id: "collections", iconName: "folder", label: qsTr("My Collections"), count: 0,            subgroups: [] }
                ]
            }
            case "scripture": {
                // One sidebar row per installed translation. Code is uppercased
                // ("KJV"), id is lowercased to match AppState.activeLibraryGroup convention.
                //
                // Rows render as plain text labels (no icon, no count) so the
                // sidebar reads as a flat translation index, matching the
                // electron experience ("AMPC", "ASV", "CEV"…).
                let r = []
                const tl = BibleService.translations()
                for (let i = 0; i < tl.length; i++) {
                    const t = tl[i]
                    r.push({ id: (t.code || "").toLowerCase(),
                             iconName: "",
                             label: t.code,
                             count: 0 })
                }
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
                let favN   = 0
                for (let i = 0; i < all.length; i++) {
                    const m = all[i]
                    if (!m) continue
                    if (m.type === "image") imgN++
                    if (m.type === "video") vidN++
                    if (m.isFavorite)       favN++
                }
                return [
                    { id: "all-media", iconName: "folder", label: qsTr("All Media"), count: all.length },
                    { id: "images",    iconName: "image",  label: qsTr("Images"),    count: imgN },
                    { id: "videos",    iconName: "video",  label: qsTr("Videos"),    count: vidN },
                    { id: "favorites", iconName: "heart",  label: qsTr("Favorites"), count: favN }
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

    // Scroll container for the group rows. With ~14 Bible translations the
    // list overflows the sidebar height on any reasonable window size, so the
    // rows must scroll. Songs/Themes are short today but the same container
    // future-proofs them at zero cost. The ScrollBar is interactive so a
    // trackpad gesture works too.
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
        ScrollBar.vertical.policy: ScrollBar.AsNeeded
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

        ColumnLayout {
            width: groupScroll.availableWidth
            spacing: Theme.space.xs

            Repeater {
                model: root.groups
                delegate: ColumnLayout {
                    // Parent row + optional indented sub-rows. Today subgroups
                    // are always [] in production data (CollectionService is
                    // deferred), so this collapses visually to a plain row —
                    // the accordion structure ships ready for collections.
                    id: groupBlock
                    Layout.fillWidth: true
                    spacing: 0

                    readonly property bool hasSubs: modelData.subgroups && modelData.subgroups.length > 0
                    readonly property bool isExpanded: !!root.expandedGroups[modelData.id]

                    LibraryRow {
                        Layout.fillWidth: true
                        iconName: modelData.iconName
                        label:    modelData.label
                        count:    modelData.count
                        active:   AppState.activeLibraryGroup[root.currentTabKey] === modelData.id
                        bgRadius: root.currentTabKey === "scripture" ? 2 : Theme.radius.md
                        onClicked: {
                            // Parents with subgroups also toggle their expansion
                            // on click so the operator can drill into collections
                            // without a separate chevron target.
                            if (groupBlock.hasSubs) root.toggleExpanded(modelData.id)
                            if (root.currentTabKey === "media") {
                                AppState.setMediaGroup(modelData.id)
                            } else {
                                AppState.setLibraryGroup(root.currentTabKey, modelData.id)
                            }
                        }
                        onDoubleClicked: {
                            if (root.currentTabKey === "scripture") {
                                AppState.setLibraryGroup("scripture", modelData.id)
                                AppState.requestPushLiveInTranslation(modelData.label)
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

    // Bottom strip — per-tab quick actions (electron parity:
    // SelectionGroups.tsx ships a `<HStack h={6} bg="gray.800">` at the bottom
    // hosting each tab's `actionMenus`). Songs gets "+ ⚙" for collection
    // management; other tabs leave the strip invisible until they have actions
    // worth shipping. The scroll container above adjusts its bottom anchor.
    //
    // TODO: Re-enable for the songs tab once CollectionService.{create,
    //       rename,duplicate,destroy} lands — at that point the + and gear
    //       below get real onClicked handlers. Hidden today because the
    //       buttons are no-op stubs and the strip visually duplicates the
    //       content-pane's "+ ⚙" cluster (same iconography, different scope).
    Rectangle {
        id: actionBar
        visible: false
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

            // + (new collection) — opens a naming modal once CollectionService
            // is in place. Today's onClicked is a no-op so the affordance is
            // present and discoverable but doesn't half-launch a feature.
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
                    // TODO: wire to AppState.openModal("naming", { ... }) once
                    // CollectionService.create lands.
                    onClicked: {}
                }
            }

            // ⚙ Rename / Duplicate / Edit / Delete — same TODO until
            // CollectionService.{rename,duplicate,update,destroy} land.
            Rectangle {
                width: 36; height: 22
                radius: 0
                color: gearCollectionMa.containsMouse ? Theme.color.raised : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

                AppIcon {
                    anchors.centerIn: parent
                    name: "settings"
                    color: Theme.color.textSecondary
                    size: Theme.icon.sm
                }
                MouseArea {
                    id: gearCollectionMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    // TODO: open a PopoverMenu with Rename/Duplicate/Edit/Delete
                    // items once CollectionService is available.
                    onClicked: {}
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
