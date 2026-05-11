import QtQuick
import QtQuick.Layouts

// Songs tab — search-filtered list with right-click add-to-schedule flow.
//
// Filtering happens synchronously inside the model binding. Cheap for the
// 8 mock songs; when a real SongService lands with FTS we'll switch the
// model to QSortFilterProxyModel and let the database do the work.
Item {
    id: root

    // Computed model: reactive to search text, library group, and song count.
    // QML's binding engine tracks reads of AppState.searchText.songs,
    // activeLibraryGroup.songs, and songsList.count so this auto-updates.
    readonly property var filteredSongs: {
        const q     = (AppState.searchText.songs || "").toLowerCase()
        const group = AppState.activeLibraryGroup.songs
        const count = AppState.songsList.count   // tracked for reactivity
        let result = []
        for (let i = 0; i < count; i++) {
            const s = AppState.songsList.get(i)
            if (!s) continue
            // Group filter
            if (group === "favorites" && !s.favorite) continue
            // Mock "Collections" — no seeded data routes here yet.
            if (group === "collections") continue
            // Search filter
            if (q.length > 0) {
                const t = (s.title  || "").toLowerCase()
                const a = (s.author || "").toLowerCase()
                if (t.indexOf(q) === -1 && a.indexOf(q) === -1) continue
            }
            // Carry the original index so right-click actions can target the source row.
            result.push({ originalIndex: i, title: s.title, author: s.author, favorite: s.favorite, ccli: s.ccli || "" })
        }
        return result
    }

    // ── Empty states ────────────────────────────────────────────────────
    EmptyState {
        anchors.fill: parent
        visible: AppState.songsList.count === 0
        iconName: "music"
        title: qsTr("No songs yet")
        body: qsTr("Import songs from a file or create them manually to get started")
    }

    EmptyState {
        anchors.fill: parent
        visible: AppState.songsList.count > 0 && root.filteredSongs.length === 0
        iconName: "search"
        title: qsTr("No matches")
        body: qsTr("Try a different search or switch group")
    }

    // "Add your first song" CTA — shown only on the truly-empty path.
    Item {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.verticalCenter
        anchors.topMargin: 56
        width: ctaBtn.implicitWidth
        height: ctaBtn.implicitHeight
        visible: AppState.songsList.count === 0

        PrimaryButton {
            id: ctaBtn
            variant: "brand"
            iconName: "plus"
            text: qsTr("Add your first song")
            onClicked: AppState.openModal("naming", {
                title:       qsTr("Create new song"),
                placeholder: qsTr("Song title"),
                confirmText: qsTr("Create")
            })
        }
    }

    // ── Songs list ──────────────────────────────────────────────────────
    ListView {
        id: list
        anchors.fill: parent
        anchors.topMargin: Theme.space.md
        anchors.leftMargin: Theme.space.md
        anchors.rightMargin: Theme.space.md
        anchors.bottomMargin: Theme.space.md
        visible: root.filteredSongs.length > 0
        model: root.filteredSongs
        clip: true
        cacheBuffer: 300
        spacing: 2
        boundsBehavior: Flickable.StopAtBounds

        delegate: Item {
            id: songRow
            width: list.width
            height: 52

            Rectangle {
                anchors.fill: parent
                anchors.leftMargin: Theme.space.sm
                anchors.rightMargin: Theme.space.sm
                radius: Theme.radius.md
                color: rowMa.containsMouse ? Theme.color.elevated : "transparent"

                Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
            }

            // Favorite indicator
            AppIcon {
                id: favIcon
                anchors.left: parent.left
                anchors.leftMargin: Theme.space.lg + Theme.space.sm
                anchors.verticalCenter: parent.verticalCenter
                name: "heart"
                color: modelData.favorite ? Theme.color.brand : Theme.color.textTertiary
                opacity: modelData.favorite ? 1.0 : 0.35
                size: 14
            }

            Column {
                anchors.left: favIcon.right
                anchors.leftMargin: Theme.space.md
                anchors.right: ccliBadge.visible ? ccliBadge.left : parent.right
                anchors.rightMargin: Theme.space.md
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                Text {
                    text: modelData.title
                    color: Theme.color.textPrimary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize
                    font.weight: Theme.font.weightMedium
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

            Rectangle {
                id: ccliBadge
                anchors.right: parent.right
                anchors.rightMargin: Theme.space.lg + Theme.space.sm
                anchors.verticalCenter: parent.verticalCenter
                visible: rowMa.containsMouse && modelData.ccli && modelData.ccli.length > 0
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

            MouseArea {
                id: rowMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton | Qt.RightButton

                onDoubleClicked: addToSchedule()

                onClicked: function(mouse) {
                    if (mouse.button !== Qt.RightButton) return
                    const p = mapToItem(null, mouse.x, mouse.y)
                    AppState.openModal("contextMenu", {
                        anchorX: p.x,
                        anchorY: p.y,
                        items: [
                            { label: qsTr("Add to Schedule"), iconName: "plus",
                              action: function() { addToSchedule() } },
                            { label: qsTr("Edit"), iconName: "edit",
                              action: function() {
                                  AppState.openModal("songEditor", { songIndex: modelData.originalIndex }) } },
                            { label: modelData.favorite ? qsTr("Unfavorite") : qsTr("Favorite"),
                              iconName: "heart",
                              action: function() {
                                  // Toggle favorite directly on the source row.
                                  const src = AppState.songsList.get(modelData.originalIndex)
                                  AppState.songsList.set(modelData.originalIndex, { favorite: !src.favorite })
                              } },
                            { separator: true },
                            { label: qsTr("Delete"), iconName: "trash", destructive: true,
                              action: function() {
                                  AppState.openModal("confirm", {
                                      title:       qsTr("Delete song?"),
                                      body:        qsTr("This permanently removes \"") + modelData.title + qsTr("\"."),
                                      confirmText: qsTr("Delete"),
                                      onConfirm:   function() {
                                          AppState.songsList.remove(modelData.originalIndex)
                                      }
                                  }) } }
                        ]
                    })
                }
            }

            function addToSchedule() {
                AppState.addScheduleItem({
                    title:     modelData.title,
                    subtitle:  modelData.author + (modelData.ccli ? " · CCLI " + modelData.ccli : ""),
                    typeName:  "SONG",
                    typeColor: Theme.color.typeSong,
                    data:      [ { content: modelData.title + "\n" + modelData.author } ]
                })
            }
        }
    }
}
