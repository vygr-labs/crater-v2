import QtQuick

// Bottom bar — quick-add affordance on the left, count of items in the
// current tab on the right.
Rectangle {
    id: root

    height: 36
    color: Theme.color.elevated

    // Top hairline
    Rectangle {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 1
        color: Theme.color.borderSubtle
    }

    // Per-tab item count
    readonly property string countLabel: {
        switch (AppState.tabKeys[AppState.activeTab]) {
            case "songs":     return AppState.songsList.count    + (AppState.songsList.count === 1    ? " song"    : " songs")
            case "scripture": return AppState.bibleVersions.count + (AppState.bibleVersions.count === 1 ? " version" : " versions")
            case "strongs":   return qsTr("Strong's concordance")
            case "media":     return AppState.mediaList.count   + (AppState.mediaList.count === 1   ? " file"  : " files")
            case "themes":    return AppState.themesList.count  + (AppState.themesList.count === 1  ? " theme" : " themes")
        }
        return ""
    }

    Row {
        anchors.left: parent.left
        anchors.leftMargin: Theme.space.md
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.space.xs

        IconButton {
            anchors.verticalCenter: parent.verticalCenter
            iconName: "plus"
            iconSize: 14
            onClicked: {
                // Context-aware: prompts to name a new item of the current tab type.
                const tabKey = AppState.tabKeys[AppState.activeTab]
                let placeholder = ""
                switch (tabKey) {
                    case "songs":     placeholder = qsTr("New song title");     break
                    case "scripture": placeholder = qsTr("Add Bible version");  break
                    case "media":     placeholder = qsTr("Import media file");  break
                    case "themes":    placeholder = qsTr("New theme name");     break
                }
                AppState.openModal("naming", {
                    title:       qsTr("Create new"),
                    placeholder: placeholder,
                    confirmText: qsTr("Create")
                })
            }
        }

        PillButton {
            id: footerSettingsBtn
            anchors.verticalCenter: parent.verticalCenter
            iconName: "settings"
            hasChevron: true
            text: ""    // no text — just icon + chevron
            onClicked: {
                const p = footerSettingsBtn.mapToItem(null, 0, -180)
                AppState.openModal("contextMenu", {
                    anchorX: p.x,
                    anchorY: p.y,
                    items: [
                        { label: qsTr("Sort by name"),  iconName: "sliders" },
                        { label: qsTr("Sort by date"),  iconName: "sliders" },
                        { separator: true },
                        { label: qsTr("Library settings…"), iconName: "settings",
                          action: function() { AppState.openModal("settings", {}) } }
                    ]
                })
            }
        }
    }

    Text {
        anchors.right: parent.right
        anchors.rightMargin: Theme.space.xl
        anchors.verticalCenter: parent.verticalCenter
        text: root.countLabel
        color: Theme.color.textTertiary
        font.family: Theme.font.family
        font.pixelSize: Theme.font.smallSize
    }
}
