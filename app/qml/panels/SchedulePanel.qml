import QtQuick
import QtQuick.Layouts

// Left top pane — the working schedule (the "playlist" being assembled).
// Empty state ↔ ListView of ScheduleRow, driven by ScheduleService.currentItems
// (QVariantList of canonical-shape items; delegate uses `modelData` to access).
Rectangle {
    id: root

    color: "transparent"

    // ── Header ──────────────────────────────────────────────────────────
    Item {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 40

        Row {
            anchors.left: parent.left
            anchors.leftMargin: Theme.space.lg
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.space.sm

            AppIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "menu"
                color: Theme.color.textSecondary
                size: 14
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("Schedule")
                color: Theme.color.textPrimary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize
                font.weight: Theme.font.weightMedium
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: ScheduleService.currentItems.length > 0
                text: ScheduleService.currentItems.length.toLocaleString(Qt.locale(), "f", 0)
                color: Theme.color.textTertiary
                font.family: Theme.font.monoFamily
                font.pixelSize: Theme.font.smallSize
            }
        }

        IconButton {
            anchors.right: parent.right
            anchors.rightMargin: Theme.space.md
            anchors.verticalCenter: parent.verticalCenter
            iconName: "grid"
            iconSize: 13
            // Placeholder for future grid-view toggle. Logs only for now.
            onClicked: console.log("[schedule] grid toggle (not yet wired)")
        }

        // Bottom hairline
        Rectangle {
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: 1
            color: Theme.color.borderSubtle
        }
    }

    // ── Body: empty state OR list ───────────────────────────────────────
    Item {
        id: body
        anchors.top: header.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right

        EmptyState {
            anchors.fill: parent
            visible: ScheduleService.currentItems.length === 0
            iconName: "music"
            title: qsTr("No items in schedule")
            body: qsTr("Add songs, scriptures, or media from the tabs below")
        }

        ListView {
            id: list
            anchors.fill: parent
            anchors.topMargin: Theme.space.sm
            anchors.bottomMargin: Theme.space.sm
            visible: ScheduleService.currentItems.length > 0
            model: ScheduleService.currentItems
            clip: true
            cacheBuffer: 200    // keep off-screen rows alive for snappy scroll
            boundsBehavior: Flickable.StopAtBounds

            // Smooth row enter/exit so deletions don't snap.
            add: Transition {
                NumberAnimation { properties: "opacity"; from: 0; to: 1; duration: Theme.motion.normal }
            }
            remove: Transition {
                NumberAnimation { properties: "opacity"; to: 0; duration: Theme.motion.instant }
            }
            displaced: Transition {
                NumberAnimation { properties: "y"; duration: Theme.motion.normal; easing.type: Easing.OutCubic }
            }

            delegate: ScheduleRow {
                width: list.width
                rowIndex: index
                title:    modelData.title    || ""
                subtitle: modelData.subtitle || ""
                kind:     modelData.kind     || ""
                isLive:   AppState.liveScheduleIndex === index
                isQueued: AppState.selectedScheduleIndex === index

                onClicked: {
                    // Claim keyboard focus for the schedule so Up/Down step
                    // through schedule rows (instead of the library list).
                    AppState.setActiveFocus("schedule")
                    AppState.selectScheduleItem(index)

                    // Scripture rows: notify the scripture picker so it can
                    // scroll-and-highlight the same verse, switching
                    // translation if needed. Mirrors electron's
                    // syncFromSchedule mechanism.
                    const it = ScheduleService.currentItems[index]
                    if (it && it.kind === "scripture" && it.scriptureRef) {
                        const r = it.scriptureRef
                        AppState.syncScriptureFromSchedule(
                            r.book, r.chapter, r.verseStart,
                            r.translationCode || "")
                    }
                }
                onDoubleClicked: {
                    AppState.setActiveFocus("schedule")
                    AppState.selectScheduleItem(index)
                    AppState.goLive()
                }
                onRightClicked: function(mouseX, mouseY) {
                    AppState.selectScheduleItem(index)
                    const item = ScheduleService.currentItems[index]
                    if (!item) return
                    const p = mapToItem(null, mouseX, mouseY)
                    AppState.openModal("contextMenu", {
                        anchorX: p.x,
                        anchorY: p.y,
                        items: [
                            { label: qsTr("Send to Live"), iconName: "play",
                              action: function() { AppState.goLive() } },
                            { label: qsTr("Edit"), iconName: "edit",
                              action: function() {
                                  AppState.openModal(
                                      item.kind === "song" ? "songEditor" : "themeEditor",
                                      { itemIndex: index }) } },
                            { label: qsTr("Duplicate"), iconName: "copy",
                              action: function() {
                                  // addItem assigns a fresh ID; strip the old one so
                                  // we don't end up with two rows sharing identity.
                                  const copy = Object.assign({}, item)
                                  delete copy.id
                                  ScheduleService.addItem(copy)
                              } },
                            { separator: true },
                            { label: qsTr("Remove"), iconName: "trash", destructive: true,
                              action: function() {
                                  AppState.openModal("confirm", {
                                      title: qsTr("Remove item?"),
                                      body:  qsTr("Remove \"") + (item.title || "") + qsTr("\" from the schedule?"),
                                      confirmText: qsTr("Remove"),
                                      onConfirm: function() { ScheduleService.removeAt(index) }
                                  }) } }
                        ]
                    })
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
