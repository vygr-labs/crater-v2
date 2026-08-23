import QtQuick
import QtQuick.Controls.Basic

// Presentations tab — the sermon-notes library.
//
// Follows the SongsTab contract exactly, because every library tab shares
// one interaction language and an operator should not have to learn a
// second one on a Sunday morning:
//
//   • Search lives in the sidebar (TabSearchBar); this tab filters on it.
//   • Single click sets fluid focus and pushes the deck to Preview.
//   • Double-click or Enter pushes it Live.
//   • Up / Down move fluid focus while the search input keeps keyboard focus.
//   • Right-click opens the standard context menu.
//   • A "LIVE" pill marks the deck currently on the projection.
//
// Filtering is a plain in-memory title match rather than FTS. Decks are
// authored one per service and a church accumulates tens of them, not the
// thousands a song library holds — indexing throwaway sermon text into a
// search table would cost an index rebuild on every keystroke of the editor
// to answer a question a substring scan answers instantly.
Item {
    id: root

    readonly property string tabKey: "presentations"

    Rectangle {
        anchors.fill: parent
        color: Theme.color.bgContent
        z: -1
    }

    readonly property string query: (AppState.searchText.presentations || "").toLowerCase()

    // ── Filtered deck list ──────────────────────────────────────────────
    // PresentationService returns decks most-recently-edited first, which is
    // the order the operator wants; the sort gear can flip it to by-name.
    readonly property string sortMode: AppState.librarySortMode.presentations || "recent"

    readonly property var filteredDecks: {
        const all = PresentationService.presentations   // tracked for reactivity
        const q   = root.query
        let result = q.length === 0
            ? all.slice()
            : all.filter(function(d) {
                  return d && (d.title || "").toLowerCase().indexOf(q) !== -1
              })
        if (root.sortMode === "name") {
            result.sort(function(a, b) {
                return (a.title || "").localeCompare(b.title || "")
            })
        }
        // "recent" needs no sort — it is the service's own ORDER BY.
        return result
    }

    readonly property int fluidIndex: AppState.libraryFluidIndex.presentations

    onFilteredDecksChanged: {
        const n = filteredDecks.length
        if (n === 0) {
            if (fluidIndex !== -1) AppState.setLibraryFluid(tabKey, -1)
            return
        }
        const idx = (fluidIndex >= 0 && fluidIndex < n) ? fluidIndex : 0
        if (idx !== fluidIndex) AppState.setLibraryFluid(tabKey, idx)
        if (AppState.tabKeys[AppState.activeTab] === tabKey) pushPreviewFor(idx)
    }

    Connections {
        target: AppState
        function onActiveTabChanged() {
            if (AppState.tabKeys[AppState.activeTab] !== root.tabKey) return
            if (root.fluidIndex >= 0) root.pushPreviewFor(root.fluidIndex)
        }
    }

    // ── Helpers ─────────────────────────────────────────────────────────
    // Two reads per item: the header row is already in the list model, the
    // slides are fetched on demand. Loading every deck's slides up front
    // would parse the whole library's JSON to render a list that only shows
    // titles and counts.
    function deckItemAt(idx) {
        if (idx < 0 || idx >= filteredDecks.length) return null
        const row = filteredDecks[idx]
        if (!row) return null
        return AppState.buildPresentationItem(row, PresentationService.slides(row.id))
    }

    function pushPreviewFor(idx) {
        if (AppState.tabKeys[AppState.activeTab] !== tabKey) return
        const item = deckItemAt(idx)
        if (item) AppState.pushLibraryPreview(item)
        else      AppState.clearLibraryPreview()
    }

    function pushLiveFor(idx) {
        const item = deckItemAt(idx)
        if (item) AppState.pushLibraryLive(item)
    }

    function addToScheduleFor(idx) {
        const item = deckItemAt(idx)
        if (item) AppState.addItemToSchedule(item)
    }

    function confirmDelete(deck) {
        AppState.openModal("confirm", {
            title:       qsTr("Delete presentation?"),
            body:        qsTr("This permanently removes \"") + deck.title + "\".",
            confirmText: qsTr("Delete"),
            onConfirm:   function() { PresentationService.destroy(deck.id) }
        })
    }

    // Context-menu rows shared by the gear menu and the per-row right-click,
    // so the two can never drift into offering different actions for the
    // same deck.
    function deckMenuItems(deck, index) {
        return [
            { label: qsTr("Edit Presentation"), iconName: "edit", kbd: "E",
              action: function() {
                  AppState.openModal("presentationEditor", { presentationId: deck.id })
              } },
            { label: qsTr("Duplicate"), iconName: "copy",
              action: function() { PresentationService.duplicate(deck.id) } },
            { separator: true },
            { label: qsTr("Add to Schedule"), iconName: "plus",
              action: function() { root.addToScheduleFor(index) } },
            { label: qsTr("Push to Live"), iconName: "play",
              action: function() { root.pushLiveFor(index) } },
            { separator: true },
            { label: qsTr("Delete"), iconName: "trash", kbd: "Del",
              destructive: true,
              action: function() { root.confirmDelete(deck) } }
        ]
    }

    // ── Action bar ──────────────────────────────────────────────────────
    Item {
        id: actionBar
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 36

        Text {
            anchors.centerIn: parent
            text: {
                const n = root.filteredDecks.length
                const noun = n === 1 ? qsTr("presentation") : qsTr("presentations")
                const q = AppState.searchText.presentations || ""
                if (q.length === 0) return n + " " + noun
                return n + " " + noun + qsTr(" matching \"") + q + "\""
            }
            color: Theme.color.textTertiary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.smallSize
        }

        Row {
            anchors.right: parent.right
            anchors.rightMargin: Theme.space.md
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            Rectangle {
                id: addBtn
                width: 28; height: 22
                radius: 0
                color: addMa.containsMouse ? Theme.color.raised : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

                AppIcon {
                    anchors.centerIn: parent
                    name: "plus"
                    color: addMa.containsMouse ? Theme.color.textPrimary : Theme.color.textSecondary
                    size: Theme.icon.sm
                    Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
                }

                MouseArea {
                    id: addMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    // Named first, then edited. A deck without a title is
                    // unfindable in a list whose only column is the title,
                    // so the name is asked for before the editor opens
                    // rather than left as an "Untitled" the operator has to
                    // remember to fix.
                    onClicked: AppState.openModal("naming", {
                        title:       qsTr("New presentation"),
                        placeholder: qsTr("Sermon title"),
                        confirmText: qsTr("Create"),
                        onConfirm:   function(name) {
                            const id = PresentationService.create(name)
                            if (id > 0) {
                                AppState.openModal("presentationEditor",
                                                   { presentationId: id })
                            }
                        }
                    })
                }
            }

            Rectangle {
                id: gearBtn
                width: 36; height: 22
                radius: 0
                color: gearMa.containsMouse ? Theme.color.raised : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

                Row {
                    anchors.centerIn: parent
                    spacing: 2
                    AppIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "settings"
                        color: gearMa.containsMouse ? Theme.color.textPrimary : Theme.color.textSecondary
                        size: Theme.icon.sm
                        Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
                    }
                    AppIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "chevron-down"
                        color: Theme.color.textSecondary
                        size: Theme.icon.tiny
                    }
                }

                MouseArea {
                    id: gearMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        const focus = root.fluidIndex
                        const haveFocus = focus >= 0 && focus < root.filteredDecks.length
                        const deck = haveFocus ? root.filteredDecks[focus] : null

                        let items = []
                        if (deck) {
                            items = root.deckMenuItems(deck, focus)
                            items.push({ separator: true })
                        }
                        const cur = root.sortMode
                        items.push({ label: qsTr("Sort by Most Recent"), iconName: "clock",
                            detail: cur === "recent" ? "✓" : "",
                            action: function() {
                                AppState.setLibrarySortMode("presentations", "recent")
                            } })
                        items.push({ label: qsTr("Sort by Name"), iconName: "arrow-down-az",
                            detail: cur === "name" ? "✓" : "",
                            action: function() {
                                AppState.setLibrarySortMode("presentations", "name")
                            } })

                        AppState.openContextMenuAt(gearBtn,
                            gearBtn.width, gearBtn.height + 4,
                            items, { menuWidth: 220, dx: -220 })
                    }
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

    // ── Empty states ────────────────────────────────────────────────────
    EmptyState {
        anchors.top: actionBar.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        visible: PresentationService.presentations.length === 0
        iconName: "presentation"
        title: qsTr("No Presentations Yet")
        body: qsTr("Write sermon notes and slides here, then send them to the audience screen and your notes to a stage monitor")
    }

    // Nothing matched the query, but the library is not empty — a different
    // situation from having no decks at all, and one the operator fixes by
    // clearing the search rather than by creating something.
    Item {
        anchors.top: actionBar.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        visible: PresentationService.presentations.length > 0
                 && root.filteredDecks.length === 0

        Column {
            anchors.centerIn: parent
            spacing: Theme.space.sm

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: qsTr("No presentations match your search")
                color: Theme.color.textSecondary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: qsTr("Clear search")
                color: Theme.color.brand
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: AppState.setSearch("presentations", "")
                }
            }
        }
    }

    // ── Deck list ───────────────────────────────────────────────────────
    ListView {
        id: list
        ScrollBar.vertical: AppScrollBar {}
        anchors.top: actionBar.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: Theme.space.sm
        anchors.bottomMargin: Theme.space.md
        visible: root.filteredDecks.length > 0
        model: root.filteredDecks
        clip: true
        cacheBuffer: 400
        spacing: 0
        boundsBehavior: Flickable.StopAtBounds
        currentIndex: root.fluidIndex

        onCurrentIndexChanged: {
            if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
        }

        delegate: Item {
            id: deckRow
            width: list.width - Theme.size.scrollBar
            height: 40

            readonly property bool _selected: list.currentIndex === index
            readonly property bool _paneFocused: AppState.activeFocusPanel === "library"
            // Live comparison keys on presentationId, which only exists on a
            // presentation item — guarding on contentKind keeps the check
            // meaningful while a song or a verse is on the projector.
            readonly property bool _isLive:
                ProjectionService.contentKind === "presentation"
                && ProjectionService.currentItem
                && ProjectionService.currentItem.presentationId === modelData.id

            Rectangle {
                anchors.fill: parent
                radius: 0
                color: deckRow._selected
                       ? (deckRow._paneFocused ? Theme.color.brandSubtle
                                               : Theme.color.selectionUnfocused)
                     : rowMa.containsMouse ? Theme.color.rowHoverBrand
                                           : "transparent"
            }

            Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: 2
                color: Theme.color.brand
                visible: deckRow._selected
                opacity: deckRow._paneFocused ? 1.0 : 0.5
            }

            Row {
                id: rowRight
                anchors.right: parent.right
                anchors.rightMargin: Theme.space.md
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.space.sm

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.slideCount === 1
                              ? qsTr("1 slide")
                              : qsTr("%1 slides").arg(modelData.slideCount)
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                }

                Badge {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: deckRow._isLive
                    text: qsTr("LIVE")
                    background: Theme.color.liveSubtle
                    foreground: Theme.color.live
                }
            }

            Text {
                anchors.left: parent.left
                anchors.leftMargin: Theme.space.lg
                anchors.right: rowRight.left
                anchors.rightMargin: Theme.space.md
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.title
                elide: Text.ElideRight
                color: deckRow._selected ? Theme.color.textPrimary : Theme.color.textSecondary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize
                font.weight: deckRow._selected ? Theme.font.weightSemiBold
                                               : Theme.font.weightMedium
            }

            RightClickArea {
                id: rowMa
                anchors.fill: parent
                menuItems: root.deckMenuItems(modelData, index)

                // Right-click focuses the row too, so the menu always acts
                // on what is visually highlighted rather than on whatever
                // was selected before.
                function _focus() {
                    AppState.setLibraryFluid(root.tabKey, index)
                    AppState.setActiveFocus("library")
                    root.pushPreviewFor(index)
                }
                onLeftClicked:  _focus()
                onRightClicked: _focus()
                onDoubleClicked: {
                    AppState.setLibraryFluid(root.tabKey, index)
                    AppState.setActiveFocus("library")
                    root.pushLiveFor(index)
                }
            }
        }
    }

    // ── Keyboard navigation from the search input ───────────────────────
    Connections {
        target: AppState
        function onLibraryNavigateDown() {
            if (AppState.tabKeys[AppState.activeTab] !== root.tabKey) return
            if (root.filteredDecks.length === 0) return
            const next = Math.min((root.fluidIndex < 0 ? -1 : root.fluidIndex) + 1,
                                  root.filteredDecks.length - 1)
            AppState.setLibraryFluid(root.tabKey, next)
            root.pushPreviewFor(next)
        }
        function onLibraryNavigateUp() {
            if (AppState.tabKeys[AppState.activeTab] !== root.tabKey) return
            if (root.filteredDecks.length === 0) return
            const next = Math.max(root.fluidIndex - 1, 0)
            AppState.setLibraryFluid(root.tabKey, next)
            root.pushPreviewFor(next)
        }
        function onLibraryActivate() {
            if (AppState.tabKeys[AppState.activeTab] !== root.tabKey) return
            if (root.fluidIndex >= 0) root.pushLiveFor(root.fluidIndex)
        }
        function onLibraryAddToSchedule() {
            if (AppState.tabKeys[AppState.activeTab] !== root.tabKey) return
            if (root.fluidIndex >= 0) root.addToScheduleFor(root.fluidIndex)
        }
    }

    // The editor saves through PresentationService, which emits
    // presentationsChanged. filteredDecks re-runs on that, but the item
    // already staged in Preview is a plain JS snapshot taken when the
    // operator clicked the row — it would keep showing the pre-edit slides.
    // Re-push it, exactly as SongsTab does after a song edit. Live is
    // deliberately NOT re-pushed: ProjectionService snapshots on goLive so a
    // half-finished edit cannot reach the audience mid-service.
    Connections {
        target: PresentationService
        function onPresentationsChanged() {
            if (AppState.tabKeys[AppState.activeTab] !== root.tabKey) return
            if (root.fluidIndex >= 0) root.pushPreviewFor(root.fluidIndex)
        }
    }
}
