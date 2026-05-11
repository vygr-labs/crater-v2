import QtQuick

// Scripture tab — flat virtualized verse list. Behavior mirrors the Electron
// scripture pane:
//
//   • Sidebar search bar (TabSearchBar) is dual-mode:
//       reference ─ "jn 3:16" parses via BibleService.parseReference;
//                   list scrolls and highlights the matched verse as the
//                   operator types.
//       search    ─ FTS5 trigram search across verses.text.
//     Ctrl+F toggles between modes (also clickable on the leading icon).
//   • Single click on a verse pushes it to Preview.
//   • Double-click or Enter promotes it to Live.
//   • Arrow Up/Down from the search input moves fluid focus inside the list.
//   • Right-click opens the standard context menu (Push Live, Add to
//     Schedule, Mark Up, Add to Favorites, Add to Collection).
//   • Switching translation (sidebar) preserves the focused (book, chapter,
//     verse) coordinates when possible.
//   • Verse count shows in the action bar.
Item {
    id: root

    readonly property string tabKey: "scripture"
    readonly property string mode:    AppState.librarySearchMode.scripture || "reference"
    readonly property string queryText: AppState.searchText.scripture || ""

    // Translations come back as uppercase codes ("KJV"); the sidebar stores
    // them lowercase ("kjv").
    readonly property string activeTranslation:
        (AppState.activeLibraryGroup.scripture || "").toUpperCase()

    // Cache-by-translation: BibleService.allVerses is ~80 ms cold for KJV.
    // The expensive call lives in a binding whose only dependency is the
    // translation code; keystrokes never re-fetch.
    readonly property var versesForActiveTranslation:
        activeTranslation.length > 0 ? BibleService.allVerses(activeTranslation) : []

    // Live result set the ListView renders.
    readonly property var currentVerses: {
        if (mode === "search") {
            return queryText.length > 0
                 ? BibleService.search(queryText, activeTranslation)
                 : []
        }
        return versesForActiveTranslation
    }

    // Reference-parser result (reference mode only). Used to scroll-to-match.
    readonly property var parsedRef: {
        if (mode !== "reference") return null
        if (queryText.length === 0) return null
        const v = BibleService.parseReference(queryText, activeTranslation)
        return (v && v.text && v.text.length > 0) ? v : null
    }

    readonly property int fluidIndex: AppState.libraryFluidIndex.scripture

    // Track focused coordinates so a translation switch can re-position.
    property var _focusedCoord: null

    function indexOf(book, chapter, verseNum) {
        const verses = currentVerses
        for (let i = 0; i < verses.length; i++) {
            const v = verses[i]
            if (v.book === book && v.chapter === chapter && v.verse === verseNum) return i
        }
        return -1
    }

    // ── Helpers ─────────────────────────────────────────────────────────

    function buildItemFromVerse(verse) {
        if (!verse || !verse.text || verse.text.length === 0) return null
        const code = verse.translationCode || activeTranslation
        return {
            kind:     "scripture",
            title:    verse.book + " " + verse.chapter + ":" + verse.verse + " (" + code + ")",
            subtitle: "",
            pages:    [{ label: verse.book + " " + verse.chapter + ":" + verse.verse, content: verse.text }],
            scriptureRef: {
                translationCode: code,
                book:            verse.book,
                chapter:         verse.chapter,
                verseStart:      verse.verse,
                verseEnd:        verse.verse
            }
        }
    }

    function verseItemAt(idx) {
        if (idx < 0 || idx >= currentVerses.length) return null
        return buildItemFromVerse(currentVerses[idx])
    }

    function pushPreviewFor(idx) {
        if (AppState.tabKeys[AppState.activeTab] !== tabKey) return
        const item = verseItemAt(idx)
        if (item) AppState.pushLibraryPreview(item)
        else      AppState.clearLibraryPreview()
    }

    function pushLiveFor(idx) {
        const item = verseItemAt(idx)
        if (item) AppState.pushLibraryLive(item)
    }

    function addToScheduleFor(idx) {
        const item = verseItemAt(idx)
        if (item) AppState.addItemToSchedule(item)
    }

    // When the parser yields a match, scroll there and highlight.
    onParsedRefChanged: {
        if (!parsedRef) return
        const idx = indexOf(parsedRef.book, parsedRef.chapter, parsedRef.verse)
        if (idx >= 0) {
            AppState.setLibraryFluid(tabKey, idx)
            list.positionViewAtIndex(idx, ListView.Center)
            pushPreviewFor(idx)
        }
    }

    // Re-bound fluid index when verses change (mode/translation/query swap).
    // Don't touch libraryPreviewItem unless this tab is active — it might
    // belong to another tab.
    onCurrentVersesChanged: {
        const n = currentVerses.length
        if (n === 0) {
            if (fluidIndex !== -1) AppState.setLibraryFluid(tabKey, -1)
            return
        }
        const idx = (fluidIndex >= 0 && fluidIndex < n) ? fluidIndex : 0
        if (idx !== fluidIndex) AppState.setLibraryFluid(tabKey, idx)
        if (AppState.tabKeys[AppState.activeTab] === tabKey) pushPreviewFor(idx)
    }

    // Refresh preview when the operator switches into this tab.
    Connections {
        target: AppState
        function onActiveTabChanged() {
            if (AppState.tabKeys[AppState.activeTab] !== root.tabKey) return
            if (root.fluidIndex >= 0) root.pushPreviewFor(root.fluidIndex)
        }
    }

    // Try to keep the same verse focused across translation changes.
    onActiveTranslationChanged: {
        if (!_focusedCoord) {
            AppState.setLibraryFluid(tabKey, 0)
            return
        }
        const idx = indexOf(_focusedCoord.book, _focusedCoord.chapter, _focusedCoord.verse)
        if (idx >= 0) {
            AppState.setLibraryFluid(tabKey, idx)
            Qt.callLater(() => list.positionViewAtIndex(idx, ListView.Center))
        } else {
            AppState.setLibraryFluid(tabKey, 0)
        }
    }

    // ── Top action bar ──────────────────────────────────────────────────
    Rectangle {
        id: actionBar
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 32
        color: "transparent"

        Text {
            anchors.centerIn: parent
            text: {
                const n = root.currentVerses.length
                const q = root.queryText
                return n.toLocaleString() + " " + qsTr("verses")
                     + (q.length > 0 ? qsTr(" matching search") : "")
            }
            color: Theme.color.textTertiary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.smallSize
        }

        // Right side: gear menu — quick toggles for mode and a refresh hook.
        Rectangle {
            id: gearBtn
            anchors.right: parent.right
            anchors.rightMargin: Theme.space.md
            anchors.verticalCenter: parent.verticalCenter
            width: 42; height: 22
            radius: 4
            color: gearMa.containsMouse ? Theme.color.overlay : "transparent"
            Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

            Row {
                anchors.centerIn: parent
                spacing: 2
                AppIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "settings"
                    color: Theme.color.textSecondary
                    size: 13
                }
                AppIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "chevron-down"
                    color: Theme.color.textSecondary
                    size: 9
                }
            }

            MouseArea {
                id: gearMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    const items = [
                        { label: root.mode === "reference"
                                ? qsTr("Switch to FTS search")
                                : qsTr("Switch to reference"),
                          iconName: root.mode === "reference" ? "search" : "book-open",
                          detail:   "Ctrl+F",
                          action: function() {
                              const next = root.mode === "reference" ? "search" : "reference"
                              AppState.setLibrarySearchMode(root.tabKey, next)
                              AppState.setSearch(root.tabKey, "")
                          } },
                        { separator: true },
                        { label: qsTr("Refresh"), iconName: "refresh-cw" }
                    ]
                    const p = gearBtn.mapToItem(null, gearBtn.width, gearBtn.height + 4)
                    AppState.openModal("contextMenu", {
                        anchorX:   p.x - 200,
                        anchorY:   p.y,
                        menuWidth: 220,
                        items:     items
                    })
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
        visible: root.activeTranslation.length === 0
        iconName: "book-open"
        title: qsTr("No Bible translation selected")
        body: qsTr("Pick a translation from the sidebar to start browsing")
    }

    EmptyState {
        anchors.top: actionBar.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        visible: root.activeTranslation.length > 0
              && root.mode === "search"
              && root.queryText.length === 0
        iconName: "search"
        title: qsTr("Search verses")
        body: qsTr("Type any phrase — results rank by relevance")
    }

    EmptyState {
        anchors.top: actionBar.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        visible: root.activeTranslation.length > 0
              && root.mode === "search"
              && root.queryText.length > 0
              && root.currentVerses.length === 0
        iconName: "book-x"
        title: qsTr("No matches")
        body: qsTr("Try a different phrase or switch to reference mode (Ctrl+F)")
    }

    // ── Verse list ──────────────────────────────────────────────────────
    ListView {
        id: list

        anchors.top: actionBar.bottom
        anchors.topMargin: Theme.space.sm
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottomMargin: Theme.space.md
        clip: true
        cacheBuffer: 400
        boundsBehavior: Flickable.StopAtBounds

        visible: root.activeTranslation.length > 0
              && !(root.mode === "search" && root.queryText.length === 0)
              && !(root.mode === "search" && root.currentVerses.length === 0)

        model: root.currentVerses
        currentIndex: root.fluidIndex

        onCurrentIndexChanged: {
            const v = root.currentVerses[currentIndex]
            if (v) {
                root._focusedCoord = { book: v.book, chapter: v.chapter, verse: v.verse }
                positionViewAtIndex(currentIndex, ListView.Contain)
            }
        }

        delegate: Item {
            id: verseRow
            width: list.width
            height: 36

            readonly property bool _selected: list.currentIndex === index

            Rectangle {
                anchors.fill: parent
                anchors.leftMargin: Theme.space.md
                anchors.rightMargin: Theme.space.md
                radius: Theme.radius.sm
                color: verseRow._selected ? Theme.color.previewSubtle
                     : verseMa.containsMouse ? Theme.color.elevated
                                             : "transparent"
                border.color: verseRow._selected ? Theme.color.preview : "transparent"
                border.width: 1
                Behavior on color        { ColorAnimation { duration: Theme.motion.instant } }
                Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }
            }

            AppIcon {
                id: bookIcon
                anchors.left: parent.left
                anchors.leftMargin: Theme.space.lg + 4
                anchors.verticalCenter: parent.verticalCenter
                name: "book-2"
                color: verseRow._selected ? Theme.color.preview : Theme.color.textTertiary
                size: 13
                opacity: verseRow._selected ? 1.0 : 0.55
            }

            Text {
                id: verseText
                anchors.left: bookIcon.right
                anchors.leftMargin: Theme.space.md
                anchors.right: refLabel.left
                anchors.rightMargin: Theme.space.md
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.text || ""
                color: verseRow._selected ? Theme.color.textPrimary : Theme.color.textSecondary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize
                elide: Text.ElideRight
            }

            Text {
                id: refLabel
                anchors.right: versionBadge.left
                anchors.rightMargin: Theme.space.md
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.book + " " + modelData.chapter + ":" + modelData.verse
                color: Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
            }

            Rectangle {
                id: versionBadge
                anchors.right: parent.right
                anchors.rightMargin: Theme.space.lg + 4
                anchors.verticalCenter: parent.verticalCenter
                width: versionLabel.implicitWidth + Theme.space.sm * 2
                height: 16
                radius: 2
                color: verseRow._selected ? Qt.darker(Theme.color.preview, 4.0) : Theme.color.overlay

                Text {
                    id: versionLabel
                    anchors.centerIn: parent
                    text: modelData.translationCode || root.activeTranslation
                    color: verseRow._selected ? Theme.color.preview : Theme.color.textTertiary
                    font.family: Theme.font.monoFamily
                    font.pixelSize: 9
                    font.weight: Theme.font.weightSemiBold
                }
            }

            MouseArea {
                id: verseMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton | Qt.RightButton

                onClicked: function(mouse) {
                    AppState.setLibraryFluid(root.tabKey, index)
                    root.pushPreviewFor(index)
                    if (mouse.button === Qt.RightButton) {
                        const p = mapToItem(null, mouse.x, mouse.y)
                        AppState.openModal("contextMenu", {
                            anchorX:   p.x,
                            anchorY:   p.y,
                            menuWidth: 220,
                            items: [
                                { label: qsTr("Push to Live"), iconName: "play",
                                  action: function() { root.pushLiveFor(index) } },
                                { label: qsTr("Add to Schedule"), iconName: "plus",
                                  action: function() { root.addToScheduleFor(index) } },
                                { separator: true },
                                { label: qsTr("Mark Up"),          iconName: "edit-3" },
                                { label: qsTr("Add to Favorites"), iconName: "heart" },
                                { label: qsTr("Add to Collection…"), iconName: "folder" }
                            ]
                        })
                    }
                }
                onDoubleClicked: {
                    AppState.setLibraryFluid(root.tabKey, index)
                    root.pushLiveFor(index)
                }
            }
        }
    }

    // ── Keyboard navigation routed from TabSearchBar ────────────────────
    Connections {
        target: AppState
        function onLibraryNavigateDown() {
            if (AppState.tabKeys[AppState.activeTab] !== root.tabKey) return
            if (root.currentVerses.length === 0) return
            const next = Math.min((root.fluidIndex < 0 ? -1 : root.fluidIndex) + 1,
                                  root.currentVerses.length - 1)
            AppState.setLibraryFluid(root.tabKey, next)
            root.pushPreviewFor(next)
        }
        function onLibraryNavigateUp() {
            if (AppState.tabKeys[AppState.activeTab] !== root.tabKey) return
            if (root.currentVerses.length === 0) return
            const next = Math.max(root.fluidIndex - 1, 0)
            AppState.setLibraryFluid(root.tabKey, next)
            root.pushPreviewFor(next)
        }
        function onLibraryActivate() {
            if (AppState.tabKeys[AppState.activeTab] !== root.tabKey) return
            if (root.fluidIndex >= 0) root.pushLiveFor(root.fluidIndex)
        }
    }

    // ── Ctrl+F: mode toggle ─────────────────────────────────────────────
    // Window-scoped shortcut. The TabSearchBar's leading icon also toggles
    // the same state via mouse — both paths converge through AppState.
    Shortcut {
        sequence: "Ctrl+F"
        enabled: AppState.tabKeys[AppState.activeTab] === root.tabKey
              && AppState.activeModal === ""
        onActivated: {
            const next = root.mode === "reference" ? "search" : "reference"
            AppState.setLibrarySearchMode(root.tabKey, next)
            AppState.setSearch(root.tabKey, "")
        }
    }
}
