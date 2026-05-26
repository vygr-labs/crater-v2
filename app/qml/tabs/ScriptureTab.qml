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

    // Right-pane background — sits a touch darker than `canvas`, matching
    // electron's `bg="gray.950/30"` on the content side. Border line on the
    // left of the pane comes from LibraryContent's parent.
    Rectangle {
        anchors.fill: parent
        color: Theme.color.bgContent
        z: -1
    }
    readonly property string mode:    AppState.librarySearchMode.scripture || "reference"
    readonly property string queryText: AppState.searchText.scripture || ""

    // Debounced shadow of queryText — coalesces fast typing into one
    // settle-then-search instead of search-per-keystroke. The heavy
    // downstream paths (FTS5 search, parsedRef → indexOf scan over the
    // full verse list → positionViewAtIndex → pushLibraryPreview) all
    // read `_debouncedQuery` rather than `queryText`. The search input
    // itself still updates per-keystroke (TabSearchBar binds straight to
    // AppState.searchText), so typing feels instant.
    //
    // Why not debounce in TabSearchBar: that file's comment ("no
    // debouncing here", line 16) deliberately keeps the bar
    // presentational. Tab-local debounce is the architectural seam —
    // each tab gets to shape its own cost profile (Songs FTS over song
    // lyrics is cheaper because the index is smaller, so it doesn't
    // need this yet).
    property string _debouncedQuery: queryText
    Timer {
        id: queryDebounce
        interval: 120
        onTriggered: root._debouncedQuery = root.queryText
    }
    onQueryTextChanged: queryDebounce.restart()

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
    //
    // Search mode + empty query falls through to the full verse list so the
    // operator always has something to scroll while deciding what to type —
    // matches the electron behavior of returning `allScriptures()` when the
    // search box is empty regardless of mode.
    readonly property var currentVerses: {
        if (mode === "search" && _debouncedQuery.length > 0) {
            return BibleService.search(_debouncedQuery, activeTranslation)
        }
        return versesForActiveTranslation
    }

    // Reference-parser result (reference mode only). Used to scroll-to-match.
    readonly property var parsedRef: {
        if (mode !== "reference") return null
        if (_debouncedQuery.length === 0) return null
        const v = BibleService.parseReference(_debouncedQuery, activeTranslation)
        return (v && v.text && v.text.length > 0) ? v : null
    }

    readonly property int fluidIndex: AppState.libraryFluidIndex.scripture

    // Track focused coordinates so a translation switch can re-position.
    property var _focusedCoord: null

    // Pending operations queued during a translation switch. The translation
    // change is async (currentVerses re-resolves once activeLibraryGroup
    // updates), so we capture intent and replay it inside
    // onCurrentVersesChanged once the new translation's verses are loaded.
    //
    // _pendingSyncCoord: schedule click → scroll & focus the matching verse.
    // _pendingPushLiveCoord: translation dblclick → push verse Live in the
    //                        new translation.
    // Each is a `{book, chapter, verse}` shape (or null when nothing pending).
    property var _pendingSyncCoord:     null
    property var _pendingPushLiveCoord: null

    // Verse strings come from the Bible DB in several shapes:
    //   "2"       — plain number
    //   "1-2"     — verse range (covers both 1 and 2)
    //   "2a"      — subdivision (matches base verse 2)
    //   "1-2a"    — combined range + subdivision
    // Used by findBestVerseMatch to handle reference parsing and schedule
    // sync against verse rows that aren't a plain integer. Mirrors the
    // electron verseMatches() function in ScriptureSelection.tsx.
    function verseMatches(verseStr, targetVerse) {
        const verse  = String(verseStr)
        const target = (typeof targetVerse === "string")
                        ? parseInt(targetVerse) : targetVerse
        if (isNaN(target)) return false

        const simpleNum = parseInt(verse)
        if (!isNaN(simpleNum) && simpleNum === target && verse === String(target)) {
            return true
        }
        const rangeMatch = verse.match(/^(\d+)-(\d+)/)
        if (rangeMatch) {
            const start = parseInt(rangeMatch[1])
            const end   = parseInt(rangeMatch[2])
            if (target >= start && target <= end) return true
        }
        const subMatch = verse.match(/^(\d+)[a-z]/i)
        if (subMatch && parseInt(subMatch[1]) === target) return true
        if (simpleNum === target) return true
        return false
    }

    // Find the best-matching verse index. Prefers exact matches over
    // range/subdivision matches so a search for verse "2" lands on the
    // standalone "2" row before falling back to a "1-2" range row.
    function findBestVerseMatch(verses, book, chapter, targetVerse) {
        if (!verses || !verses.length) return -1
        const normBook = String(book || "").toLowerCase()
        const target   = (typeof targetVerse === "string")
                          ? parseInt(targetVerse) : targetVerse

        let exactIdx = -1
        let rangeIdx = -1
        for (let i = 0; i < verses.length; i++) {
            const v = verses[i]
            if (String(v.book || "").toLowerCase() !== normBook) continue
            if (v.chapter !== chapter) continue
            const verseStr = String(v.verse)
            if (verseStr === String(target)) { exactIdx = i; break }
            if (rangeIdx === -1 && verseMatches(verseStr, target)) rangeIdx = i
        }
        return exactIdx !== -1 ? exactIdx : rangeIdx
    }

    function indexOf(book, chapter, verseNum) {
        return findBestVerseMatch(currentVerses, book, chapter, verseNum)
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

    // Combined-item builder for multi-verse selections. Returns a single item
    // whose one page contains every selected verse, numbered, separated by
    // spaces — the "all on one slide" projection shape Q2 settled on. Title
    // collapses contiguous runs within the same book+chapter ("John 3:14-17"),
    // and falls back to a comma/semicolon list when the selection spans
    // multiple chapters or has gaps ("John 3:14, 16; Rom 5:8").
    //
    // scriptureRef carries the FIRST verse's coords so schedule → scripture
    // sync still has a single jump target. Schedule-row labels read the same
    // title field, so a multi-verse row reads as "John 3:14-17 (KJV)".
    function buildItemFromVerses(verses) {
        if (!verses || verses.length === 0) return null
        const usable = verses.filter(function(v) { return v && v.text && v.text.length > 0 })
        if (usable.length === 0) return null
        if (usable.length === 1) return buildItemFromVerse(usable[0])

        const code = usable[0].translationCode || activeTranslation
        const title = _formatVerseRangeTitle(usable) + " (" + code + ")"
        // Numbered verses so the operator can read which verse is which on
        // the slide. Two spaces between verses give the eye a parsing break
        // without bloating the layout the way line breaks would on themes
        // not designed for multi-verse content.
        const combined = usable.map(function(v) {
            return v.verse + " " + v.text
        }).join("  ")

        const first = usable[0]
        const last  = usable[usable.length - 1]
        return {
            kind:     "scripture",
            title:    title,
            subtitle: "",
            pages:    [{ label: _formatVerseRangeTitle(usable), content: combined }],
            scriptureRef: {
                translationCode: code,
                book:            first.book,
                chapter:         first.chapter,
                verseStart:      first.verse,
                verseEnd:        last.verse
            }
        }
    }

    // Compose a human reference string for a sorted verse array. Groups
    // verses by (book, chapter) and collapses each group's contiguous runs
    // into ranges. Numeric verse parsing tolerates the same shapes
    // verseMatches handles (plain "12", range "1-2", subdivision "2a")
    // by reading the leading integer.
    function _formatVerseRangeTitle(verses) {
        const groups = []        // [{book, chapter, verses:[int]}]
        let current = null
        for (let i = 0; i < verses.length; ++i) {
            const v = verses[i]
            const n = parseInt(String(v.verse), 10)
            if (isNaN(n)) continue
            if (!current || current.book !== v.book || current.chapter !== v.chapter) {
                current = { book: v.book, chapter: v.chapter, verses: [] }
                groups.push(current)
            }
            current.verses.push(n)
        }
        if (groups.length === 0) return ""
        return groups.map(function(g) {
            return g.book + " " + g.chapter + ":" + _collapseRanges(g.verses)
        }).join("; ")
    }

    // [14,15,16,18] → "14-16, 18". Sorted-ascending precondition; the
    // builder already filters to that order via librarySelectedIndices'
    // sort guarantee in AppState.setLibrarySelected.
    function _collapseRanges(nums) {
        if (nums.length === 0) return ""
        const out = []
        let start = nums[0], prev = nums[0]
        for (let i = 1; i < nums.length; ++i) {
            const n = nums[i]
            if (n === prev + 1) { prev = n; continue }
            out.push(start === prev ? String(start) : (start + "-" + prev))
            start = n; prev = n
        }
        out.push(start === prev ? String(start) : (start + "-" + prev))
        return out.join(", ")
    }

    // Resolve the active set of verse indices: multi-selection if any, else
    // the single fluid-anchor index (or empty if none). This single helper
    // keeps the push / preview / schedule paths from each re-deriving the
    // policy.
    function _activeIndices() {
        const sel = AppState.librarySelectedIndices[tabKey] || []
        if (sel.length > 0) {
            // Ensure the anchor is part of the active set even if the user
            // ctrl-clicked it off — the anchor is what they last touched.
            if (fluidIndex >= 0 && sel.indexOf(fluidIndex) < 0) {
                return sel.concat([fluidIndex]).sort(function(a, b) { return a - b })
            }
            return sel
        }
        return fluidIndex >= 0 ? [fluidIndex] : []
    }

    function _activeVerses() {
        const idxs = _activeIndices()
        const out = []
        for (let i = 0; i < idxs.length; ++i) {
            const v = currentVerses[idxs[i]]
            if (v) out.push(v)
        }
        return out
    }

    function _activeItem() {
        const verses = _activeVerses()
        if (verses.length === 0) return null
        return verses.length === 1
               ? buildItemFromVerse(verses[0])
               : buildItemFromVerses(verses)
    }

    function verseItemAt(idx) {
        if (idx < 0 || idx >= currentVerses.length) return null
        return buildItemFromVerse(currentVerses[idx])
    }

    // Push the current ACTIVE set (multi if any, else the single row at idx).
    // The idx argument is kept for the keyboard / parsedRef paths that target
    // a specific row without disturbing multi-selection state.
    function pushPreviewFor(idx) {
        if (AppState.tabKeys[AppState.activeTab] !== tabKey) return
        const sel = AppState.librarySelectedIndices[tabKey] || []
        const item = (sel.length > 0) ? _activeItem() : verseItemAt(idx)
        if (item) AppState.pushLibraryPreview(item)
        else      AppState.clearLibraryPreview()
    }

    function pushLiveFor(idx) {
        const sel = AppState.librarySelectedIndices[tabKey] || []
        const item = (sel.length > 0) ? _activeItem() : verseItemAt(idx)
        if (item) AppState.pushLibraryLive(item)
    }

    function addToScheduleFor(idx) {
        const sel = AppState.librarySelectedIndices[tabKey] || []
        const item = (sel.length > 0) ? _activeItem() : verseItemAt(idx)
        if (item) AppState.addItemToSchedule(item)
    }

    // Sync the sidebar search input to the verse at idx. Used after every
    // user-driven fluid-focus change (click, arrow nav, schedule sync) so
    // the input always reflects "what verse you're currently looking at"
    // — but explicitly NOT called from onParsedRefChanged, since that path
    // is driven BY the input and overwriting it would erase the operator's
    // typing mid-flight.
    //
    // Format uses a space between chapter and verse ("Exodus 12 1") rather
    // than a colon ("Exodus 12:1"). Matches the controlled-mode display
    // and reads cleaner — BibleService.parseReference accepts either form.
    function _syncInputToVerse(idx) {
        if (mode !== "reference") return
        if (idx < 0 || idx >= currentVerses.length) return
        const v = currentVerses[idx]
        if (!v) return
        AppState.setSearch(tabKey, v.book + " " + v.chapter + " " + v.verse)
    }

    // When the parser yields a match, scroll there and highlight.
    onParsedRefChanged: {
        if (!parsedRef) return
        const idx = indexOf(parsedRef.book, parsedRef.chapter, parsedRef.verse)
        if (idx >= 0) {
            AppState.setLibraryFluid(tabKey, idx)
            list.positionViewAtIndex(idx, ListView.Contain)
            pushPreviewFor(idx)
        }
    }

    // Re-bound fluid index when verses change (mode/translation/query swap).
    // Don't touch libraryPreviewItem unless this tab is active — it might
    // belong to another tab.
    //
    // Also drain pending sync / push-live ops queued during a translation
    // switch — see _pendingSyncCoord / _pendingPushLiveCoord above. These
    // run *after* the new translation's verses arrive so findBestVerseMatch
    // searches the correct corpus.
    onCurrentVersesChanged: {
        const n = currentVerses.length
        if (n === 0) {
            if (fluidIndex !== -1) AppState.setLibraryFluid(tabKey, -1)
            return
        }

        // Drain pending sync (schedule → scripture jump). Consume the
        // pending coord either way; only return early if we found a match.
        // On miss (verse doesn't exist in this translation), fall through
        // to the default fluid-index recovery so we don't leave a stale
        // out-of-bounds index.
        if (_pendingSyncCoord) {
            const syncIdx = findBestVerseMatch(currentVerses,
                _pendingSyncCoord.book,
                _pendingSyncCoord.chapter,
                _pendingSyncCoord.verse)
            _pendingSyncCoord = null
            if (syncIdx >= 0) {
                AppState.setLibraryFluid(tabKey, syncIdx)
                Qt.callLater(function() { list.positionViewAtIndex(syncIdx, ListView.Contain) })
                if (AppState.tabKeys[AppState.activeTab] === tabKey) pushPreviewFor(syncIdx)
                _syncInputToVerse(syncIdx)
                return
            }
        }

        // Drain pending push-live (translation dblclick).
        if (_pendingPushLiveCoord) {
            const liveIdx = findBestVerseMatch(currentVerses,
                _pendingPushLiveCoord.book,
                _pendingPushLiveCoord.chapter,
                _pendingPushLiveCoord.verse)
            _pendingPushLiveCoord = null
            if (liveIdx >= 0) {
                AppState.setLibraryFluid(tabKey, liveIdx)
                pushLiveFor(liveIdx)
                return
            }
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

        // Schedule → scripture sync: clicking a scripture row in the schedule
        // jumps the picker to that verse, switching translation if needed.
        // Same-translation case: act immediately. Different-translation case:
        // queue the coords + flip activeLibraryGroup; the verses-changed
        // handler above will replay once the new corpus loads.
        function onSyncScriptureFromSchedule(book, chapter, verse, translation) {
            if (!book || !chapter) return
            const wantCode = (translation || "").toUpperCase()
            const sameTranslation = (wantCode === "" || wantCode === root.activeTranslation)

            if (sameTranslation) {
                const idx = root.findBestVerseMatch(root.currentVerses, book, chapter, verse)
                if (idx >= 0) {
                    AppState.setLibraryFluid(root.tabKey, idx)
                    Qt.callLater(function() { list.positionViewAtIndex(idx, ListView.Contain) })
                    if (AppState.tabKeys[AppState.activeTab] === root.tabKey) {
                        root.pushPreviewFor(idx)
                    }
                    root._syncInputToVerse(idx)
                }
                return
            }

            root._pendingSyncCoord = { book: book, chapter: chapter, verse: verse }
            AppState.setLibraryGroup("scripture", wantCode.toLowerCase())
        }

        // Translation dblclick → push current verse Live in the new
        // translation. Captures _focusedCoord at the moment of the request
        // (it's still pointing at the OLD-translation verse coords) and
        // replays after the switch.
        function onRequestPushLiveInTranslation(translationCode) {
            const wantCode = (translationCode || "").toUpperCase()
            if (!wantCode) return
            // No focus → nothing to push live. The dblclick still switches
            // translation via LibrarySidebar's setLibraryGroup call.
            if (!root._focusedCoord) return

            if (wantCode === root.activeTranslation) {
                const idx = root.findBestVerseMatch(root.currentVerses,
                    root._focusedCoord.book,
                    root._focusedCoord.chapter,
                    root._focusedCoord.verse)
                if (idx >= 0) root.pushLiveFor(idx)
                return
            }

            root._pendingPushLiveCoord = {
                book:    root._focusedCoord.book,
                chapter: root._focusedCoord.chapter,
                verse:   root._focusedCoord.verse
            }
            AppState.setLibraryGroup("scripture", wantCode.toLowerCase())
        }
    }

    // Try to keep the same verse focused across translation changes.
    // Multi-selection is dropped on translation switch — the indices point
    // into the old corpus, and silently mapping coords across translations
    // gets ambiguous fast for ranges that include subdivision verses ("2a").
    onActiveTranslationChanged: {
        AppState.clearLibrarySelected(tabKey)
        if (!_focusedCoord) {
            AppState.setLibraryFluid(tabKey, 0)
            return
        }
        const idx = indexOf(_focusedCoord.book, _focusedCoord.chapter, _focusedCoord.verse)
        if (idx >= 0) {
            AppState.setLibraryFluid(tabKey, idx)
            Qt.callLater(() => list.positionViewAtIndex(idx, ListView.Contain))
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
            radius: 0
            color: gearMa.containsMouse ? Theme.color.overlay : "transparent"
            Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

            Row {
                anchors.centerIn: parent
                spacing: 2
                AppIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "settings"
                    color: Theme.color.textSecondary
                    size: Theme.icon.sm
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
                    const items = [
                        { label: root.mode === "reference"
                                ? qsTr("Switch to FTS search")
                                : qsTr("Switch to reference"),
                          iconName: root.mode === "reference" ? "search" : "book-open",
                          detail:   "Ctrl+F",
                          action: function() {
                              const next = root.mode === "reference" ? "search" : "reference"
                              AppState.setLibrarySearchModeWithMemory(root.tabKey, next)
                          } },
                        { separator: true },
                        // Reference-input sub-mode: only meaningful in
                        // reference mode. Greyed out (skipped from menu)
                        // when in FTS search to avoid noise.
                        ...(root.mode === "reference" ? [
                            { label: AppState.scriptureInputMode === "crater"
                                    ? qsTr("Reference input: Crater (autocomplete)")
                                    : qsTr("Reference input: Controlled (segmented)"),
                              iconName: AppState.scriptureInputMode === "crater"
                                    ? "edit" : "list-ordered",
                              action: function() {
                                  const next = AppState.scriptureInputMode === "crater"
                                             ? "controlled" : "crater"
                                  AppState.setScriptureInputMode(next)
                                  AppState.setSearch(root.tabKey, "")
                              } },
                            { separator: true }
                        ] : []),
                        { label: qsTr("Refresh"), iconName: "refresh-cw" }
                    ]
                    AppState.openContextMenuAt(gearBtn,
                        gearBtn.width, gearBtn.height + 4,
                        items, { menuWidth: 220, dx: -200 })
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
    // Two cases, mirroring electron's Switch:
    //   1. No verses available (no translation selected, or selected
    //      translation has no rows imported yet)
    //   2. Search mode with a query that returned zero hits
    // The "no query in search mode" case from before was removed because
    // currentVerses now falls back to the full list — matches electron.
    EmptyState {
        anchors.top: actionBar.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        visible: root.currentVerses.length === 0
              && !(root.mode === "search" && root.queryText.length > 0)
        iconName: "book-x"
        title: qsTr("No Scriptures Available")
        body: qsTr("Select a Bible version from the sidebar to load scriptures")
    }

    EmptyState {
        anchors.top: actionBar.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        visible: root.mode === "search"
              && root.queryText.length > 0
              && root.currentVerses.length === 0
        iconName: "search"
        title: qsTr("No scriptures found")
        body: qsTr("No verses match your search query")
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

        visible: root.currentVerses.length > 0

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
            height: 40

            readonly property bool _selected: list.currentIndex === index
            // True if this row is part of a multi-selection (shift+click
            // range, ctrl+click extra). The anchor row stays governed by
            // _selected — this flag lights up the *other* rows in the
            // selection so the operator sees the full active set.
            readonly property bool _inMulti:
                (AppState.librarySelectedIndices[root.tabKey] || []).indexOf(index) >= 0
            // Visual-selection truth: anchor row OR any extra row in the
            // multi-selection. Most chrome (icon tint, verse text color,
            // version badge fill) should react to this, not raw _selected,
            // so a 4-verse selection reads as one continuous highlighted
            // block rather than three pale rows with one bright anchor.
            readonly property bool _highlighted: _selected || _inMulti
            // True while the library pane owns keyboard focus. When the
            // operator clicks into Schedule / Preview / Live, this flips
            // false and the selected-row wash mutes to neutral gray so
            // the eye knows which pane the arrow keys will move next.
            readonly property bool _paneFocused: AppState.activeFocusPanel === "library"

            // Edge-to-edge background. Selected wash sits at brandSubtle
            // (#0E2528, deep cyan) — the calm cyan-presence tier where
            // selected rows read as "tinted dark" rather than "filled
            // cyan." Multi-selected (non-anchor) rows use the same wash so
            // every member of the set reads as one continuous selection;
            // the anchor is distinguished by the brighter brand-cyan version-
            // badge chip below, not by row background. Paired with textTitle
            // (gray.300) body text, this is the chosen gray-on-cyan polarity.
            // No Behavior on color (removed earlier to fix the arrow-key
            // navigation flash).
            Rectangle {
                anchors.fill: parent
                radius: 0
                color: verseRow._highlighted
                       ? (verseRow._paneFocused ? Theme.color.brandSubtle
                                                : Theme.color.selectionUnfocused)
                     : verseMa.containsMouse ? Theme.color.rowHoverBrand
                                             : "transparent"
            }

            AppIcon {
                id: bookIcon
                anchors.left: parent.left
                anchors.leftMargin: Theme.space.md
                anchors.verticalCenter: parent.verticalCenter
                name: "book-2"
                // Selected: `textTitle` (gray.300) on the deep-cyan wash.
                // Contrast ~11.6:1 (AAA easy) with the eye-comfort
                // benefit of softer-than-white ink.
                color: verseRow._highlighted ? Theme.color.textTitle : Theme.color.textTertiary
                size: Theme.icon.lg
                opacity: verseRow._highlighted ? 1.0 : 0.7
            }

            Text {
                id: verseText
                anchors.left: bookIcon.right
                anchors.leftMargin: Theme.space.md
                anchors.right: refLabel.left
                anchors.rightMargin: Theme.space.md
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.text || ""
                // Selected: `textTitle` (gray.300) softer-than-textPrimary
                // tone with semiBold (600) weight bump. Bolder strokes +
                // softer color = same perceived presence with less raw
                // luminance, addressing the eye-strain from pure white.
                color: verseRow._highlighted ? Theme.color.textTitle : "#d4d4d8"   // gray.300
                font.family: Theme.font.family
                // Scales with the operator's Font size setting via Theme.uiScale.
                // The literal 17 is the baseline pixel size (slightly larger
                // than Theme.font.bodySize so verse rows read more substantial
                // than song-row titles).
                font.pixelSize: Math.round(17 * Theme.uiScale)
                font.weight: verseRow._highlighted ? Theme.font.weightSemiBold
                                                   : Theme.font.weightRegular
                elide: Text.ElideRight
            }

            Text {
                id: refLabel
                anchors.right: versionBadge.left
                anchors.rightMargin: Theme.space.md
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.book + " " + modelData.chapter
                    + (SettingsService.showVerseNumbers ? ":" + modelData.verse : "")
                // Selected: textSecondary (a1a1aa) — quieter than the
                // verse text's textTitle, so the reference reads as
                // secondary chrome against the deep-cyan wash.
                color: verseRow._highlighted ? Theme.color.textSecondary
                                             : Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Math.round(16 * Theme.uiScale)
                font.weight: Theme.font.weightMedium
                font.capitalization: Font.Capitalize
            }

            Rectangle {
                id: versionBadge
                anchors.right: parent.right
                anchors.rightMargin: Theme.space.md
                anchors.verticalCenter: parent.verticalCenter
                width: versionLabel.implicitWidth + Theme.space.sm * 2
                height: 16
                radius: 0
                // Selected: brand-cyan chip on the deep-cyan-wash row.
                // The chip becomes the bright accent inside an otherwise
                // dark row, matching how Logic / Pro Tools treat colored
                // chips on dark surfaces. Unselected: flat gray.800 chip.
                color: verseRow._highlighted ? Theme.color.brand
                                             : Theme.color.raised

                Text {
                    id: versionLabel
                    anchors.centerIn: parent
                    text: modelData.translationCode || root.activeTranslation
                    // Selected: white text on the brand-cyan chip. 11px
                    // badge text wants the maximum contrast budget; white
                    // on brand sits at ~7.9:1 (AAA) where any gray would
                    // start chipping into legibility headroom.
                    color: verseRow._highlighted ? Theme.color.textPrimary
                                                 : Theme.color.textSecondary
                    font.family: Theme.font.monoFamily
                    font.pixelSize: Math.round(11 * Theme.uiScale)
                    font.weight: Theme.font.weightBold
                    font.capitalization: Font.AllUppercase
                    font.letterSpacing: 0.5
                }
            }

            RightClickArea {
                id: verseMa
                anchors.fill: parent
                menuItems: [
                    { label: qsTr("Push to Live"), iconName: "play",
                      action: function() { root.pushLiveFor(index) } },
                    { label: qsTr("Add to Schedule"), iconName: "plus",
                      action: function() { root.addToScheduleFor(index) } },
                    { separator: true },
                    { label: qsTr("Mark Up"),            iconName: "edit-3" },
                    { label: qsTr("Add to Favorites"),   iconName: "heart" },
                    { label: qsTr("Add to Collection…"), iconName: "folder" },
                    { separator: true },
                    { label: qsTr("Refresh"), iconName: "refresh-cw" }
                ]

                // Single-row focus path — used by plain clicks AND by
                // right-clicks that land on rows outside the current
                // selection (so the context menu acts on what was just
                // visually pointed at, the way every desktop file manager
                // works). Clears any prior multi-selection.
                function _focus() {
                    AppState.setLibraryFluid(root.tabKey, index)
                    AppState.clearLibrarySelected(root.tabKey)
                    // Claim Up/Down/Enter for the library — operator just
                    // clicked a verse row, so subsequent arrow keys should
                    // walk the verse list rather than the preview/live
                    // page list (which may currently own focus). The
                    // window-level TapHandler in LibraryContent only sees
                    // clicks that land outside row MouseAreas; this call
                    // covers the row-click path.
                    AppState.setActiveFocus("library")
                    root.pushPreviewFor(index)
                    root._syncInputToVerse(index)
                }

                // Extend the selection from the current anchor up to this
                // row, inclusive. Replaces any prior multi-selection (matches
                // Finder / Explorer / VS Code shift-click semantics — a fresh
                // shift+click is "select this range", not "merge with previous").
                function _extendRange() {
                    const anchor = root.fluidIndex
                    if (anchor < 0) { _focus(); return }
                    const lo = Math.min(anchor, index)
                    const hi = Math.max(anchor, index)
                    const range = []
                    for (let i = lo; i <= hi; ++i) range.push(i)
                    AppState.setLibrarySelected(root.tabKey, range)
                    // Anchor stays put; only the set grows. Re-push preview
                    // so the combined-verse content reflects the new set.
                    AppState.setActiveFocus("library")
                    root.pushPreviewFor(index)
                }

                // Toggle this row in/out of the multi-selection without
                // disturbing the others. If toggling brings the set to
                // empty, we fall back to single-row focus on this row so
                // there's always *something* selected (matches how the
                // existing single-row model expects fluidIndex >= 0).
                //
                // Seeding subtlety: the FIRST ctrl+click of a session has
                // no prior multi-set, only an anchor. We have to fold the
                // anchor into the set before adding the new index — without
                // that, moving the anchor to the new row would silently drop
                // the previously-clicked row from the visual selection (it
                // was never in `librarySelectedIndices`; it was the implicit
                // single-row selection conveyed by `fluidIndex` alone).
                function _toggleInSet() {
                    let sel = (AppState.librarySelectedIndices[root.tabKey] || []).slice()
                    if (sel.length === 0 && root.fluidIndex >= 0 && root.fluidIndex !== index) {
                        sel.push(root.fluidIndex)
                    }
                    const at = sel.indexOf(index)
                    if (at >= 0) sel.splice(at, 1)
                    else         sel.push(index)
                    // Anchor moves to the most recently touched row, matching
                    // Finder behavior (next shift+click extends from here).
                    AppState.setLibraryFluid(root.tabKey, index)
                    AppState.setLibrarySelected(root.tabKey, sel)
                    AppState.setActiveFocus("library")
                    root.pushPreviewFor(index)
                }

                onLeftClicked: function(mouse) {
                    if (mouse.modifiers & Qt.ShiftModifier) {
                        _extendRange()
                    } else if (mouse.modifiers & (Qt.ControlModifier | Qt.MetaModifier)) {
                        _toggleInSet()
                    } else {
                        _focus()
                    }
                }
                onRightClicked: function(mouse) {
                    // If the operator right-clicks INSIDE the current
                    // selection, keep the selection intact — the menu
                    // should act on the whole set. Otherwise behave like a
                    // plain click: clear the set and focus this single row.
                    if (verseRow._inMulti || verseRow._selected) {
                        AppState.setActiveFocus("library")
                    } else {
                        _focus()
                    }
                }
                onDoubleClicked: {
                    AppState.setLibraryFluid(root.tabKey, index)
                    AppState.setActiveFocus("library")
                    root._syncInputToVerse(index)
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
            // Plain arrow nav clears the multi-selection — operator is
            // moving the anchor, not extending the set. Shift+arrow as a
            // "extend selection" gesture is a possible later add (would
            // need TabSearchBar to forward modifier state through the
            // navigate signals).
            AppState.clearLibrarySelected(root.tabKey)
            const next = Math.min((root.fluidIndex < 0 ? -1 : root.fluidIndex) + 1,
                                  root.currentVerses.length - 1)
            AppState.setLibraryFluid(root.tabKey, next)
            root.pushPreviewFor(next)
            root._syncInputToVerse(next)
        }
        function onLibraryNavigateUp() {
            if (AppState.tabKeys[AppState.activeTab] !== root.tabKey) return
            if (root.currentVerses.length === 0) return
            AppState.clearLibrarySelected(root.tabKey)
            const next = Math.max(root.fluidIndex - 1, 0)
            AppState.setLibraryFluid(root.tabKey, next)
            root.pushPreviewFor(next)
            root._syncInputToVerse(next)
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

    // ── Ctrl+F: mode toggle ─────────────────────────────────────────────
    // Window-scoped shortcut. The TabSearchBar's leading icon also toggles
    // the same state via mouse — both paths converge through AppState.
    Shortcut {
        sequence: "Ctrl+F"
        enabled: AppState.tabKeys[AppState.activeTab] === root.tabKey
              && AppState.activeModal === ""
        onActivated: {
            const next = root.mode === "reference" ? "search" : "reference"
            AppState.setLibrarySearchModeWithMemory(root.tabKey, next)
        }
    }
}
