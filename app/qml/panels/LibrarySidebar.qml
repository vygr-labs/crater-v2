import QtQuick
import QtQuick.Layouts

// Left side of the bottom row — search input plus the group navigation.
// The group list is tab-specific: Songs shows All/Favorites/Collections,
// Scripture shows Bible versions, etc.
Rectangle {
    id: root

    color: "transparent"

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
                let r = []
                const tl = BibleService.translations()
                for (let i = 0; i < tl.length; i++) {
                    const t = tl[i]
                    r.push({ id: (t.code || "").toLowerCase(),
                             iconName: "book-open",
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

    ColumnLayout {
        anchors.fill: parent
        anchors.topMargin: Theme.space.md
        spacing: Theme.space.xs

        // Per-tab search bar — renders a different input variant per active tab
        // (mode dropdown for Songs, reference/search toggle for Scripture,
        // simple search elsewhere). Owns its own state via AppState.searchText
        // and AppState.librarySearchMode.
        TabSearchBar {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space.lg
            Layout.rightMargin: Theme.space.lg
            Layout.bottomMargin: Theme.space.sm
        }

        // Group list — uses LibraryRow component
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

        Item { Layout.fillHeight: true }
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
