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
            case "songs": return [
                { id: "all-songs",   iconName: "folder",  label: qsTr("All Songs"),      count: AppState.songsList.count },
                { id: "favorites",   iconName: "heart",   label: qsTr("My Favorites"),   count: 0 },
                { id: "collections", iconName: "folders", label: qsTr("My Collections"), count: AppState.collectionsList.count }
            ]
            case "scripture": {
                let r = []
                for (let i = 0; i < AppState.bibleVersions.count; i++) {
                    const v = AppState.bibleVersions.get(i)
                    r.push({ id: v.abbrev.toLowerCase(), iconName: "book-open", label: v.abbrev, count: 0 })
                }
                return r
            }
            case "strongs": return [
                { id: "greek",  iconName: "book", label: qsTr("Greek"),  count: 5523 },
                { id: "hebrew", iconName: "book", label: qsTr("Hebrew"), count: 8674 }
            ]
            case "media": return [
                { id: "all-media", iconName: "folder", label: qsTr("All Media"), count: AppState.mediaList.count },
                { id: "images",    iconName: "film",   label: qsTr("Images"),    count: 3 },
                { id: "videos",    iconName: "film",   label: qsTr("Videos"),    count: 3 }
            ]
            case "themes": return [
                { id: "all-themes", iconName: "palette", label: qsTr("All Themes"), count: AppState.themesList.count },
                { id: "custom",     iconName: "palette", label: qsTr("Custom"),     count: 0 },
                { id: "presets",    iconName: "palette", label: qsTr("Presets"),    count: AppState.themesList.count }
            ]
        }
        return []
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.topMargin: Theme.space.md
        spacing: Theme.space.xs

        // Search bar
        SearchBar {
            Layout.fillWidth: true
            Layout.preferredHeight: 36
            Layout.leftMargin: Theme.space.lg
            Layout.rightMargin: Theme.space.lg
            Layout.bottomMargin: Theme.space.sm

            placeholder: root.searchPlaceholder
            shortcutHint: "⌘A"
            text: AppState.searchText[root.currentTabKey] || ""
            onTextChanged: AppState.setSearch(root.currentTabKey, text)
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
