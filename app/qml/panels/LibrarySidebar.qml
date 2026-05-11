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

    readonly property var groups: {
        switch (currentTabKey) {
            case "songs": {
                const songs = SongService.allSongs
                const favCount = songs.filter(function(s) { return s.isFavorite }).length
                // "My Collections" deferred until a CollectionService lands.
                return [
                    { id: "all-songs", iconName: "folder", label: qsTr("All Songs"),    count: songs.length },
                    { id: "favorites", iconName: "heart",  label: qsTr("My Favorites"), count: favCount }
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
            case "media": return [
                { id: "all-media", iconName: "folder", label: qsTr("All Media"), count: 0 }
            ]
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
        anchors.bottom: parent.bottom
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
                delegate: LibraryRow {
                    Layout.fillWidth: true
                    iconName: modelData.iconName
                    label:    modelData.label
                    count:    modelData.count
                    active:   AppState.activeLibraryGroup[root.currentTabKey] === modelData.id
                    onClicked: AppState.setLibraryGroup(root.currentTabKey, modelData.id)
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
