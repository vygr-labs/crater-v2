import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic

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

    // ── Multi-select ────────────────────────────────────────────────────
    // Selection mode = 2+ rows selected. One selected row is the ordinary
    // "current" row that drives Preview, so the checkboxes and the bulk bar
    // only take over once the operator has actually picked several.
    readonly property bool selectionMode: AppState.selectedScheduleIndices.length > 1

    // The header's Select toggle (SelectModeToggle reads these two). On, the
    // rows show their checkboxes and a plain click ticks a row.
    readonly property bool selectMode: AppState.scheduleSelectMode
    // Turning it on is a schedule gesture, so the schedule takes the
    // keyboard and Escape can step back out.
    function setSelectMode(on) {
        AppState.setScheduleSelectMode(on)
        if (on) AppState.setActiveFocus("schedule")
    }

    // Selected rows in schedule order. Snapshotted by each action so a
    // click during a confirm dialog can't change what it acts on.
    function selectedRows() {
        const n = ScheduleService.currentItems.length
        return AppState.selectedScheduleIndices
            .filter(function(i) { return i >= 0 && i < n })
            .sort(function(a, b) { return a - b })
    }

    function confirmRemoveSelected() {
        const rows = selectedRows()
        if (rows.length === 0) return
        AppState.openModal("confirm", {
            title: rows.length === 1
                ? qsTr("Remove item?")
                : qsTr("Remove %1 items?").arg(rows.length),
            body:  rows.length === 1
                ? qsTr("Remove the selected item from the schedule?")
                : qsTr("Remove the %1 selected items from the schedule?").arg(rows.length),
            confirmText: qsTr("Remove"),
            // One batch call: one schedule change, and the live pointer is
            // carried past the removed rows.
            onConfirm: function() { AppState.removeScheduleIndices(rows) }
        })
    }

    // Theme picker for several rows. Lists the themes of every kind present
    // in the selection; each applies only to rows of its own kind (the same
    // rule as the single-row menu). With mixed kinds the kind is named next
    // to each theme so the operator can tell "Classic (song)" from
    // "Classic (scripture)".
    // Replaces each row's theme, so it asks first like Remove.
    function _confirmScheduleTheme(rows, tid, tkind, themeName) {
        AppState.openModal("confirm", {
            title:       qsTr("Change the theme of %1 items?").arg(rows.length),
            body:        tid > 0
                ? qsTr("Each matching item's current theme is replaced with %1.").arg(themeName)
                : qsTr("Each item's own theme is removed, so it uses the default theme."),
            confirmText: qsTr("Change theme"),
            destructive: false,
            onConfirm:   function() { AppState.setScheduleTheme(rows, tid, tkind) }
        })
    }

    function bulkThemeSubmenu() {
        const rows = selectedRows()
        const items = ScheduleService.currentItems
        let kinds = {}
        let kindCount = 0
        for (let i = 0; i < rows.length; i++) {
            const k = items[rows[i]].kind || "song"
            if (!kinds[k]) { kinds[k] = true; kindCount++ }
        }
        const all = ThemeService.allThemes
        let out = []
        for (let j = 0; j < all.length; j++) {
            const t = all[j]
            if (!kinds[t.kind]) continue
            const tid = t.id
            const tkind = t.kind
            out.push({
                label: kindCount > 1 ? qsTr("%1 (%2)").arg(t.name).arg(t.kind) : t.name,
                iconName: "palette",
                action: function() { root._confirmScheduleTheme(rows, tid, tkind, t.name) }
            })
        }
        if (out.length > 0) out.push({ separator: true })
        out.push({ label: qsTr("Use default theme"), iconName: "refresh-cw",
                   action: function() { root._confirmScheduleTheme(rows, 0, "", "") } })
        return out
    }

    // Right-click on a selected row while 2+ are selected.
    function bulkMenuItems() {
        const rows = selectedRows()
        return [
            { label: qsTr("Move Up"), iconName: "arrow-up",
              enabled: AppState.canMoveScheduleSelection(-1),
              action: function() { AppState.moveScheduleSelection(-1) } },
            { label: qsTr("Move Down"), iconName: "arrow-down",
              enabled: AppState.canMoveScheduleSelection(1),
              action: function() { AppState.moveScheduleSelection(1) } },
            { separator: true },
            { label: qsTr("Duplicate %1 items").arg(rows.length), iconName: "copy",
              action: function() { AppState.duplicateScheduleIndices(rows) } },
            { label: qsTr("Theme…"), iconName: "palette",
              submenu: root.bulkThemeSubmenu() },
            { separator: true },
            { label: qsTr("Remove %1 items").arg(rows.length), iconName: "trash",
              destructive: true,
              action: function() { root.confirmRemoveSelected() } }
        ]
    }

    // Selection indices are positional; when rows go away by some path that
    // doesn't fix them up itself (single-row Remove, clear, loading a saved
    // schedule), drop the ones now past the end so no action can act on a
    // row that no longer exists.
    Connections {
        target: ScheduleService
        function onCurrentItemsChanged() {
            const n = ScheduleService.currentItems.length
            // Nothing left to select (cleared, or an empty schedule loaded).
            if (n === 0) AppState.setScheduleSelectMode(false)
            const sel = AppState.selectedScheduleIndices
            const kept = sel.filter(function(i) { return i >= 0 && i < n })
            if (kept.length !== sel.length) AppState.selectedScheduleIndices = kept
            if (AppState.selectedScheduleIndex >= n)
                AppState.selectedScheduleIndex = kept.length > 0 ? kept[kept.length - 1] : -1
        }
    }

    // ── Header ──────────────────────────────────────────────────────────
    // Single-line, ~32px tall — matches electron's `h={8}` header with a
    // playlist icon, label, parenthesised count, optional "• N selected"
    // accent, and a right cluster of (trash, menu).
    Rectangle {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: Theme.d(32)
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

            // Select mode: shows the row checkboxes.
            SelectModeToggle {
                anchors.verticalCenter: parent.verticalCenter
                visible: ScheduleService.currentItems.length > 0 || root.selectMode
                target: root
            }

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
                    root.confirmRemoveSelected()
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

            // Every first-run user lands here, so it carries the way into
            // the tutorials.
            GhostButton {
                iconName: "circle-play"
                text: qsTr("Watch Getting started")
                onClicked: Qt.openUrlExternally(HelpLinks.playlist("getting-started"))
            }
        }

        ListView {
            id: list
            ScrollBar.vertical: AppScrollBar {}
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: scheduleBar.visible ? scheduleBar.top : parent.bottom
            // Rows are now flat (no card inset) so they sit flush against
            // the header — drop the top margin, keep a small bottom one for
            // scroll padding on the last row.
            anchors.bottomMargin: Theme.space.xs
            visible: ScheduleService.currentItems.length > 0
            model: ScheduleService.itemsModel
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

            // Bring a freshly-appended row into view, so an item added to a
            // long schedule doesn't land out of sight. Contain scrolls the
            // minimum needed, which for an appended row means settling on
            // the bottom edge exactly where the new item is.
            Connections {
                target: AppState
                function onScheduleItemAppended(index) {
                    if (index >= 0 && index < list.count)
                        list.positionViewAtIndex(index, ListView.Contain)
                }
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
                width: list.width - Theme.size.scrollBar
                // The row's item, read once: each model.entry read converts
                // the whole map to a JS object again.
                readonly property var _entry: model.entry
                rowIndex: index
                title:    _entry.title    || ""
                subtitle: _entry.subtitle || ""
                kind:     _entry.kind     || ""
                isLive:   AppState.liveScheduleIndex === index
                isSelected: AppState.selectedScheduleIndices.indexOf(index) >= 0
                isPrimarySelected: AppState.selectedScheduleIndex === index
                hasThemeOverride: {
                    const t = _entry.themeId
                    return (typeof t === "number" && t > 0)
                        || (typeof t === "string" && parseInt(t) > 0)
                }
                hasContentOverride: _entry.contentOverride === true
                selectionMode: root.selectionMode || root.selectMode

                // Checkbox: toggles this row in or out of the selection
                // without moving the anchor (Preview stays put). Counts as a
                // schedule gesture, so it takes keyboard focus like Ctrl+click.
                onCheckToggled: {
                    AppState.toggleScheduleChecked(index)
                    AppState.setActiveFocus("schedule")
                }

                // Click DELIBERATELY does NOT call setActiveFocus("schedule").
                // The operator typically clicks a schedule row to load it into
                // the Preview pane while their keyboard focus is still in the
                // Library (arrowing through scripture or songs); claiming focus
                // on click would steal the arrow keys mid-navigation. The row
                // still becomes the primary-selected item — it just shows in
                // the focus-muted gray wash, signalling "selected, but arrows
                // aren't pointing here." Operators move keyboard focus to
                // schedule by other means (future: Tab-cycle, explicit hotkey).
                onClicked: function(button, modifiers) {
                    if (modifiers & Qt.ControlModifier) {
                        AppState.toggleScheduleSelection(index)
                        // A modified click is an unambiguous "I am working
                        // in the schedule" gesture, so it claims keyboard
                        // focus where a plain click deliberately does not.
                        // Without this, activeFocusPanel never reached
                        // "schedule" and the Delete shortcut gated on it could
                        // never fire — multi-select had no keyboard removal
                        // at all.
                        AppState.setActiveFocus("schedule")
                    } else if (modifiers & Qt.ShiftModifier) {
                        AppState.extendScheduleSelectionTo(index)
                        AppState.setActiveFocus("schedule")
                    } else if (root.selectMode) {
                        // Select mode: a plain click ticks the row, like its
                        // checkbox.
                        AppState.toggleScheduleChecked(index)
                        AppState.setActiveFocus("schedule")
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
                // Double-click also keeps focus where it was. Going live is a
                // committed projection action — the operator's keyboard
                // ownership shouldn't be a side effect of it.
                //
                // goLive(false) pushes the item to the live channel without
                // raising the projection window. Raising the audience-facing
                // window from a schedule double-click was a surprise — the
                // operator may be staging items during a rehearsal or
                // between songs, and yanking the projector up mid-stage is
                // disruptive. The explicit "Go Live" button in the TopBar is
                // the entry point for raising the window (it now ONLY opens the
                // window — it no longer commits anything); schedule double-click
                // is a "stage to live" shortcut that respects the current
                // projector visibility.
                onDoubleClicked: {
                    AppState.selectScheduleItem(index)
                    AppState.goLive(false)
                }
                onRightClicked: function(mouseX, mouseY) {
                    // If the right-clicked row isn't part of the current
                    // selection, switch to single-select on it first so the
                    // context menu actions operate on the visible target.
                    if (AppState.selectedScheduleIndices.indexOf(index) < 0) {
                        AppState.selectScheduleItem(index)
                    }
                    // Opening the row menu is a schedule gesture, never a
                    // library-navigation one, so it can safely take focus
                    // — which is also what arms the Delete shortcut.
                    AppState.setActiveFocus("schedule")
                    const item = ScheduleService.currentItems[index]
                    if (!item) return

                    // On a row that is part of a 2+ selection, the menu
                    // offers the bulk versions of its actions instead.
                    if (root.selectionMode) {
                        AppState.openContextMenuAt(this, mouseX, mouseY, root.bulkMenuItems())
                        return
                    }

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
                        // Edit routes by kind — song / scripture rows open
                        // the schedule item editor (edits THIS row's slides,
                        // not the library record), media rows open their
                        // options. See AppState.editScheduleItem. Dimmed
                        // rather than hidden when a row has nothing editable,
                        // so the entry keeps a stable position in the menu.
                        { label: qsTr("Edit…"), iconName: "edit",
                          enabled: AppState.canEditScheduleItem(index),
                          action: function() { AppState.editScheduleItem(index) } },
                        // Scripture only: swap WHICH verses the row holds.
                        // Distinct from Edit, which marks up the text the row
                        // already has. Hidden (not dimmed) on other kinds —
                        // there is no passage to re-pick, so the entry would
                        // be noise rather than a disabled affordance.
                        { label: qsTr("Change passage…"), iconName: "book-open",
                          visible: (item.kind || "") === "scripture" && !!item.scriptureRef,
                          action: function() { AppState.repickSchedulePassage(index) } },
                        // Retitles THIS row only; the library record keeps its
                        // own name (see AppState.renameScheduleItem).
                        { label: qsTr("Rename…"), iconName: "type",
                          action: function() { AppState.renameScheduleItem(index) } },
                        { label: qsTr("Duplicate"), iconName: "copy",
                          action: function() {
                              // addItem assigns a fresh id; strip the old one
                              // so we don't end up with two rows sharing identity.
                              const copy = Object.assign({}, item)
                              delete copy.id
                              ScheduleService.addItem(copy)
                              // Deliberately not routed through
                              // AppState.addItemToSchedule: that also selects
                              // the new row, and duplicating shouldn't move the
                              // operator's selection. We still announce the
                              // append so the copy gets scrolled into view.
                              AppState.scheduleItemAppended(
                                  ScheduleService.currentItems.length - 1)
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
                    // PopoverMenu has no `visible` in its row schema (only
                    // `enabled`), so kind-specific entries are filtered out
                    // here rather than handed over to be ignored. Entries
                    // without the key are kept, so this only affects rows
                    // that opt in.
                    ].filter(function(e) { return e.visible !== false }))
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
                    // Dragging one row of a 2+ selection moves the whole
                    // group, packed together where this row was dropped.
                    // AppState carries the selection and live pointer along.
                    // Dragging an unselected row past a multi-selection goes
                    // through the same remapping so the selected rows stay
                    // selected rather than their indices pointing at
                    // whatever slid into place.
                    if (target >= 0 && target !== i && root.selectionMode) {
                        if (AppState.selectedScheduleIndices.indexOf(i) >= 0) {
                            AppState.moveScheduleSelectionTo(i, target)
                        } else {
                            let order = []
                            for (let k = 0; k < list.count; k++) order.push(k)
                            order.splice(i, 1)
                            order.splice(target, 0, i)
                            AppState.applyScheduleOrder(order)
                        }
                        return
                    }
                    // A single row goes through the same remapping, so the
                    // rows it passes keep their selection and the Live badge
                    // stays on the live item even when that item is one of
                    // the rows that shifted.
                    if (target >= 0 && target !== i) {
                        let order = []
                        for (let k = 0; k < list.count; k++) order.push(k)
                        order.splice(i, 1)
                        order.splice(target, 0, i)
                        AppState.applyScheduleOrder(order)
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
                width: list.width - Theme.size.scrollBar
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

        // Wheel scrolls straight to a fixed step and stops at the ends,
        // with no momentum or overshoot (see DirectWheel).
        DirectWheel { target: list }

        // Bulk-action bar while 2+ rows are selected. Clear drops back to
        // the anchor row alone (the "current" row Preview shows) rather
        // than deselecting everything, matching the first Escape.
        SelectionBar {
            id: scheduleBar
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            visible: root.selectionMode
            count: AppState.selectedScheduleIndices.length
            canSelectAll: AppState.selectedScheduleIndices.length
                          < ScheduleService.currentItems.length
            onSelectAllClicked: {
                AppState.selectAllSchedule()
                AppState.setActiveFocus("schedule")
            }
            onClearClicked: AppState.collapseScheduleSelection()
            actions: [
                { label: qsTr("Move up"), iconName: "arrow-up",
                  enabled: AppState.canMoveScheduleSelection(-1),
                  action: function() { AppState.moveScheduleSelection(-1) } },
                { label: qsTr("Move down"), iconName: "arrow-down",
                  enabled: AppState.canMoveScheduleSelection(1),
                  action: function() { AppState.moveScheduleSelection(1) } },
                { label: qsTr("Duplicate"), iconName: "copy",
                  action: function() { AppState.duplicateScheduleIndices(root.selectedRows()) } },
                { label: qsTr("Theme"), iconName: "palette",
                  submenu: root.bulkThemeSubmenu() },
                { label: qsTr("Remove"), iconName: "trash", destructive: true,
                  action: function() { root.confirmRemoveSelected() } }
            ]
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
