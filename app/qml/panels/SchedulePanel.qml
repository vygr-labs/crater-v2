import QtQuick
import QtQuick.Layouts

// Left top pane — the working schedule (the "playlist" being assembled).
//
// Three things differentiate this from a bare ListView:
//   1) Header shows the loaded schedule's name + a dirty dot when there are
//      unsaved changes, plus a kebab menu for clear / close-loaded actions.
//   2) Multi-select via Ctrl/Shift+click; the selected set drives multi-delete
//      and is rendered with checks + a softer border on non-primary members.
//   3) Drag-to-reorder via the per-row handle; the panel tracks the dragged
//      row's offset and projects a brand-colored insertion line at the drop
//      target. moveItem is called on release; ListView's `displaced`
//      transition then animates the rows to their final positions.
Rectangle {
    id: root

    // Panel surface — gray.900 equivalent, matching electron's `bg.muted`
    // used on Tabs.ContentGroup and panel containers. Header sits on the
    // same surface and is differentiated only by its 1px bottom border.
    color: Theme.color.elevated

    // ── Header ──────────────────────────────────────────────────────────
    // Single-line, ~32px tall — matches electron's `h={8}` header with a
    // playlist icon, label, parenthesised count, optional "• N selected"
    // accent, and a right cluster of (trash, menu).
    Rectangle {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 32
        color: Theme.color.elevated

        // Left cluster: playlist glyph + name + count + selection accent.
        // The dirty dot stays inline (small, between the name and count) so
        // we don't grow the header to two lines.
        Row {
            anchors.left: parent.left
            anchors.leftMargin: Theme.space.md
            anchors.right: actions.left
            anchors.rightMargin: Theme.space.sm
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.space.sm

            AppIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "list-music"
                color: Theme.color.textTertiary
                size: Theme.icon.md
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: ScheduleService.loadedScheduleName.length > 0
                    ? ScheduleService.loadedScheduleName
                    : qsTr("Schedule")
                color: Theme.color.textTitle
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize + 1   // 12px
                font.weight: Theme.font.weightMedium
                elide: Text.ElideRight
            }

            // Unsaved-edits dot. Smaller than before (4px) so it reads as an
            // annotation, not a status badge.
            Rectangle {
                visible: ScheduleService.isDirty
                anchors.verticalCenter: parent.verticalCenter
                width: 5; height: 5
                radius: 2.5
                color: Theme.color.warning
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: ScheduleService.currentItems.length > 0
                text: "(" + ScheduleService.currentItems.length + ")"
                color: Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: AppState.selectedScheduleIndices.length > 0
                text: "• " + AppState.selectedScheduleIndices.length + " " + qsTr("selected")
                color: Theme.color.preview
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
            }
        }

        // Right cluster: trash (visible only when there are items) + kebab.
        Row {
            id: actions
            anchors.right: parent.right
            anchors.rightMargin: Theme.space.sm
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            // Trash — bulk-delete the current multi-selection, or "clear all"
            // when nothing is selected (matches electron's deleteSelectedItems).
            IconButton {
                id: trashBtn
                visible: ScheduleService.currentItems.length > 0
                iconName: "trash"
                iconSize: Theme.icon.sm
                tintHover: Theme.color.live   // electron's red.400 hover
                anchors.verticalCenter: parent.verticalCenter
                onClicked: {
                    const sel = AppState.selectedScheduleIndices
                    if (sel.length === 0) {
                        AppState.openModal("confirm", {
                            title: qsTr("Clear schedule?"),
                            body:  qsTr("Remove all items from the working schedule? Saved schedules are not affected."),
                            confirmText: qsTr("Clear all"),
                            onConfirm: function() {
                                ScheduleService.clearAll()
                                AppState.clearScheduleSelection()
                                AppState.liveScheduleIndex = -1
                                AppState.libraryLiveActive = false
                                AppState.clearLibraryPreview()
                            }
                        })
                        return
                    }
                    // Remove selected in reverse so earlier indices stay valid
                    // through the splice loop — same approach as electron.
                    const sorted = sel.slice().sort(function(a, b) { return b - a })
                    AppState.openModal("confirm", {
                        title: sorted.length === 1
                            ? qsTr("Remove item?")
                            : qsTr("Remove %1 items?").arg(sorted.length),
                        body:  qsTr("Remove the selected items from the schedule?"),
                        confirmText: qsTr("Remove"),
                        onConfirm: function() {
                            for (let i = 0; i < sorted.length; i++) {
                                ScheduleService.removeAt(sorted[i])
                            }
                            AppState.clearScheduleSelection()
                        }
                    })
                }
            }

            IconButton {
                id: kebab
                anchors.verticalCenter: parent.verticalCenter
                iconName: "more-vertical"
                iconSize: Theme.icon.md
                onClicked: {
                    const items = []
                    if (AppState.selectedScheduleIndices.length > 0) {
                        items.push({
                            label: qsTr("Clear selection"),
                            iconName: "x",
                            action: function() { AppState.clearScheduleSelection() }
                        })
                    }
                    if (ScheduleService.loadedScheduleId > 0) {
                        items.push({
                            label: qsTr("Close loaded schedule"),
                            iconName: "x",
                            action: function() { ScheduleService.closeLoaded() }
                        })
                    }
                    if (items.length > 0) items.push({ separator: true })
                    items.push({
                        label: qsTr("Clear all items"),
                        iconName: "trash",
                        destructive: true,
                        action: function() {
                            AppState.openModal("confirm", {
                                title: qsTr("Clear schedule?"),
                                body:  qsTr("Remove all items from the working schedule? Saved schedules are not affected."),
                                confirmText: qsTr("Clear all"),
                                onConfirm: function() {
                                    ScheduleService.clearAll()
                                    AppState.clearScheduleSelection()
                                    AppState.liveScheduleIndex = -1
                                    AppState.libraryLiveActive = false
                                    AppState.clearLibraryPreview()
                                }
                            })
                        }
                    })
                    AppState.openContextMenuAt(kebab, 0, kebab.height + 4,
                        items, { dx: -200 })
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
            iconName: "list-music"
            title: qsTr("No items in schedule")
            body: qsTr("Add songs, scriptures, or media from the tabs below")
        }

        ListView {
            id: list
            anchors.fill: parent
            // Rows are now flat (no card inset) so they sit flush against
            // the header — drop the top margin, keep a small bottom one for
            // scroll padding on the last row.
            anchors.bottomMargin: Theme.space.xs
            visible: ScheduleService.currentItems.length > 0
            model: ScheduleService.currentItems
            clip: true
            cacheBuffer: 200
            boundsBehavior: Flickable.StopAtBounds
            // Disable flick-scroll while a row is being dragged so a small
            // mouse jitter doesn't yank the whole list along with the row.
            interactive: list.draggedRow < 0

            // ── Drag state ──────────────────────────────────────────────
            // Updated by ScheduleRow drag signals. The panel is the single
            // owner of "which row is dragging and where" so the insertion
            // indicator below has a single source of truth.
            property int  draggedRow:     -1
            property real draggedOffsetY: 0

            function dropTargetIndex() {
                if (draggedRow < 0) return -1
                const rowH = Theme.size.scheduleRowHeight
                const delta = Math.round(draggedOffsetY / rowH)
                return Math.max(0, Math.min(count - 1, draggedRow + delta))
            }

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
                isSelected: AppState.selectedScheduleIndices.indexOf(index) >= 0
                isPrimarySelected: AppState.selectedScheduleIndex === index
                hasThemeOverride: {
                    const t = modelData.themeId
                    return (typeof t === "number" && t > 0)
                        || (typeof t === "string" && parseInt(t) > 0)
                }

                onClicked: function(button, modifiers) {
                    AppState.setActiveFocus("schedule")
                    if (modifiers & Qt.ControlModifier) {
                        AppState.toggleScheduleSelection(index)
                    } else if (modifiers & Qt.ShiftModifier) {
                        AppState.extendScheduleSelectionTo(index)
                    } else {
                        AppState.selectScheduleItem(index)
                        // Scripture rows: notify the picker so it can scroll-and-
                        // highlight the same verse, switching translation as
                        // needed. Mirrors electron's syncFromSchedule mechanism.
                        const it = ScheduleService.currentItems[index]
                        if (it && it.kind === "scripture" && it.scriptureRef) {
                            const r = it.scriptureRef
                            AppState.syncScriptureFromSchedule(
                                r.book, r.chapter, r.verseStart,
                                r.translationCode || "")
                        } else if (it && it.kind === "song" && it.songId) {
                            // Song rows: same idea — scroll the library so the
                            // operator sees what they just selected in the
                            // schedule. SongsTab skips the sync when in
                            // lyrics-FTS mode (filtered list may exclude the row).
                            AppState.syncSongFromSchedule(it.songId)
                        }
                    }
                }
                onDoubleClicked: {
                    AppState.setActiveFocus("schedule")
                    AppState.selectScheduleItem(index)
                    AppState.goLive()
                }
                onRightClicked: function(mouseX, mouseY) {
                    // If the right-clicked row isn't part of the current
                    // selection, switch to single-select on it first so the
                    // context menu actions operate on the visible target.
                    if (AppState.selectedScheduleIndices.indexOf(index) < 0) {
                        AppState.selectScheduleItem(index)
                    }
                    const item = ScheduleService.currentItems[index]
                    if (!item) return

                    // Theme submenu — filtered to themes matching this item's
                    // kind, with a check on the active choice and a "Use
                    // default" fallback at the bottom.
                    const themeItems = []
                    const allThemes = ThemeService.allThemes
                    const itemKind = item.kind || "song"
                    const currentThemeId = (typeof item.themeId === "number") ? item.themeId : 0
                    for (let i = 0; i < allThemes.length; i++) {
                        const t = allThemes[i]
                        if (t.kind !== itemKind) continue
                        themeItems.push({
                            label: t.name,
                            iconName: (currentThemeId === t.id) ? "check" : "circle",
                            action: function() { ScheduleService.setItemTheme(index, t.id) }
                        })
                    }
                    if (themeItems.length > 0) themeItems.push({ separator: true })
                    themeItems.push({
                        label: qsTr("Use default theme"),
                        iconName: (currentThemeId === 0) ? "check" : "refresh-cw",
                        action: function() { ScheduleService.setItemTheme(index, 0) }
                    })

                    AppState.openContextMenuAt(this, mouseX, mouseY, [
                        { label: qsTr("Send to Live"), iconName: "play",
                          action: function() { AppState.goLive() } },
                        { label: qsTr("Edit"), iconName: "edit",
                          action: function() {
                              AppState.openModal(
                                  item.kind === "song" ? "songEditor" : "themeEditor",
                                  { itemIndex: index })
                          } },
                        { label: qsTr("Duplicate"), iconName: "copy",
                          action: function() {
                              // addItem assigns a fresh id; strip the old one
                              // so we don't end up with two rows sharing identity.
                              const copy = Object.assign({}, item)
                              delete copy.id
                              ScheduleService.addItem(copy)
                          } },
                        // First-class submenu — chevron + hover-open inside
                        // PopoverMenu. Used to be two sibling top-level
                        // contextMenu modals chained via Qt.callLater.
                        { label: qsTr("Theme…"), iconName: "palette",
                          submenu: themeItems },
                        { separator: true },
                        { label: qsTr("Remove"), iconName: "trash", destructive: true,
                          action: function() {
                              AppState.openModal("confirm", {
                                  title: qsTr("Remove item?"),
                                  body:  qsTr("Remove \"") + (item.title || "") + qsTr("\" from the schedule?"),
                                  confirmText: qsTr("Remove"),
                                  onConfirm: function() { ScheduleService.removeAt(index) }
                              })
                          } }
                    ])
                }

                onDragStarted: function(i) {
                    list.draggedRow = i
                    list.draggedOffsetY = 0
                }
                onDragMoved: function(i, off) {
                    list.draggedOffsetY = off
                }
                onDragReleased: function(i, off) {
                    const target = list.dropTargetIndex()
                    list.draggedRow = -1
                    list.draggedOffsetY = 0
                    if (target >= 0 && target !== i) {
                        ScheduleService.moveItem(i, target)
                        // Carry selection across the move so the primary
                        // selection still points at the dragged item visually.
                        if (AppState.selectedScheduleIndex === i) {
                            AppState.selectScheduleItem(target)
                        }
                        // Live pointer too — if we re-order the row that's
                        // currently Live, the badge needs to follow.
                        if (AppState.liveScheduleIndex === i) {
                            AppState.liveScheduleIndex = target
                        }
                    }
                }
            }

            // ── Drop-target indicator ──────────────────────────────────
            // Parented to the ListView's contentItem so its y is in content
            // coordinates (no list.contentY math). Visible only when there's
            // an actual move pending (delta != 0). The y formula: top of the
            // target row for moves up, bottom of the target row for moves down
            // — which matches where the row will actually slot in after the
            // moveItem call resolves.
            // Drop-target indicator. Edge-to-edge (no inset margins) since
            // rows are now flat. Slightly lighter brand color so it reads
            // clearly against the deeper brand-tinted selected-row bg.
            Rectangle {
                id: dropIndicator
                parent: list.contentItem
                visible: list.draggedRow >= 0
                      && list.dropTargetIndex() !== list.draggedRow
                x: 0
                width: list.width
                height: 2
                z: 1000
                color: Qt.lighter(Theme.color.brand, 1.6)

                y: {
                    if (!visible) return 0
                    const rowH = Theme.size.scheduleRowHeight
                    const target = list.dropTargetIndex()
                    const delta = target - list.draggedRow
                    return target * rowH + (delta > 0 ? rowH : 0) - height / 2
                }

                Behavior on y { NumberAnimation { duration: Theme.motion.instant } }
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
