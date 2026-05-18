import QtQuick

// Per-tab search bar. Renders a different input variant for each library tab
// so the search experience matches Electron:
//
//   songs     ─ leading "mode" button (opens popover) + clear (×) + Ctrl+A hint
//               Modes: title / lyrics / author / recent / oldest / newest
//   scripture ─ leading "mode" button (book-open ↔ search toggle) + Ctrl+F hint
//               Modes: reference (parses "jn 3:16") / search (FTS5)
//               Interpreted hint renders below the input when in reference mode.
//   media     ─ leading search icon + clear (×) + Ctrl+A hint
//   strongs / themes ─ plain search bar (mirrors the old SearchBar control)
//
// State for query + mode lives on AppState (searchText[tabKey] +
// librarySearchMode[tabKey]) so the tab content panel can re-read them. The
// bar itself stays presentational — no debouncing here.
//
// Scripture reference mode supports two sub-modes via AppState.scriptureInputMode:
//   "crater"     — free-text + autocomplete on space; "Interpreted: …" hint
//                  below the input; Enter pushes the matched verse Live.
//   "controlled" — segmented stage editor: book → chapter → verse, each
//                  segment auto-selected (next keystroke replaces it);
//                  Tab/Space advances; Backspace at stage start retreats;
//                  click a segment to edit it. Per-character validation
//                  against BibleService.books().chapterCount and
//                  BibleService.chapter().length, cached per translation.
Item {
    id: root

    readonly property string tabKey: AppState.tabKeys[AppState.activeTab]
    readonly property string mode:
        tabKey === "songs"     ? (AppState.librarySearchMode.songs     || "lyrics")
      : tabKey === "scripture" ? (AppState.librarySearchMode.scripture || "reference")
      : tabKey === "media"     ? (AppState.librarySearchMode.media     || "title")
                               : ""

    readonly property string queryText: AppState.searchText[tabKey] || ""

    // Songs search-mode metadata (icon + placeholder + label). Mirrors the
    // SONG_SEARCH_MODE_* constants in electron/.../SongSelection.tsx, except
    // the sort variants (recent / oldest / newest) live in the gear menu's
    // AppState.librarySortMode now — keeping them out of this dropdown stops
    // "Sort by Newest" from hijacking the input placeholder.
    readonly property var songModes: [
        { id: "title",   label: qsTr("Title"),  icon: "search",    placeholder: qsTr("Search by title…") },
        { id: "lyrics",  label: qsTr("Lyrics"), icon: "file-text", placeholder: qsTr("Search in lyrics…") },
        { id: "author",  label: qsTr("Author"), icon: "user",      placeholder: qsTr("Search by author…") }
    ]

    function songMode(id) {
        for (let i = 0; i < songModes.length; i++) {
            if (songModes[i].id === id) return songModes[i]
        }
        return songModes[1]   // lyrics default
    }

    // ── Scripture reference-input sub-mode ──────────────────────────────
    // Two ways to type a reference, switched via AppState.scriptureInputMode:
    //
    //   "crater"     ─ free text + autocomplete on space. Only delta from the
    //                  default behavior is the on-space book completion below.
    //   "controlled" ─ segmented stage editor. The displayed text reads
    //                  "Genesis 1:1" with the current stage's segment auto-
    //                  selected; each keystroke replaces or extends that
    //                  segment after validating against the book metadata.
    //
    // State for controlled mode lives here (presentation-layer state, per
    // ARCHITECTURE.md §9). The persisted bits — query text, search mode —
    // continue to live on AppState.
    readonly property bool isScriptureReference:
        tabKey === "scripture" && mode === "reference"
    readonly property bool isControlledMode:
        isScriptureReference && AppState.scriptureInputMode === "controlled"
    readonly property bool isCraterMode:
        isScriptureReference && AppState.scriptureInputMode === "crater"

    // Controlled-mode state. Reset to the active translation's first book on
    // translation switch / mode switch. `_typed` is the buffer of characters
    // accumulated in the current stage — cleared on stage advance.
    property int    ctrlStage:   0           // 0=book, 1=chapter, 2=verse
    property string ctrlBook:    ""
    property int    ctrlChapter: 1
    property int    ctrlVerse:   1
    property string ctrlTyped:   ""

    // Caches for BibleService lookups so per-keystroke validation doesn't
    // re-query SQLite. Keyed by translation code (books) and "code/book/chap"
    // (verse counts). Invalidated on translation change.
    property var _booksCache:      ({})
    property var _verseCountCache: ({})

    function _booksFor(code) {
        if (!code) return []
        if (_booksCache[code]) return _booksCache[code]
        let books = BibleService.books(code)
        // Alphabetical sort so prefix matching favors "James" over "Joshua"
        // when the user types "j" — matches electron's allBooks ordering.
        books = books.slice().sort(function(a, b) {
            return a.name.toLowerCase().localeCompare(b.name.toLowerCase())
        })
        let copy = Object.assign({}, _booksCache)
        copy[code] = books
        _booksCache = copy
        return books
    }

    function _bookChapterCount(code, bookName) {
        const books = _booksFor(code)
        for (let i = 0; i < books.length; i++) {
            if (books[i].name === bookName) return books[i].chapterCount
        }
        return 0
    }

    function _chapterVerseCount(code, bookName, chapter) {
        const key = code + "/" + bookName + "/" + chapter
        if (_verseCountCache[key] !== undefined) return _verseCountCache[key]
        const verses = BibleService.chapter(code, bookName, chapter)
        let copy = Object.assign({}, _verseCountCache)
        copy[key] = verses.length
        _verseCountCache = copy
        return verses.length
    }

    function _findBookByPrefix(code, prefix) {
        if (!prefix) return null
        const lower = prefix.toLowerCase()
        const books = _booksFor(code)
        for (let i = 0; i < books.length; i++) {
            if (books[i].name.toLowerCase().indexOf(lower) === 0) return books[i]
        }
        return null
    }

    // Computed: the controlled-mode displayed text and the selection range
    // for the current stage. The selection range is what the TextInput
    // highlights so the operator can see which stage they're editing.
    //
    // Separator is a space (not colon). Reads cleaner as a "Book Ch V"
    // index and matches the format _syncInputToVerse pushes from the
    // verse-list click handlers. BibleService.parseReference accepts
    // both forms, so swapping is invisible to downstream consumers.
    readonly property string ctrlDisplay:
        ctrlBook + " " + ctrlChapter + " " + ctrlVerse

    function _ctrlSelStart(stage) {
        if (stage === 0) return 0
        if (stage === 1) return ctrlBook.length + 1
        return ctrlBook.length + 1 + String(ctrlChapter).length + 1
    }
    function _ctrlSelEnd(stage) {
        if (stage === 0) return ctrlBook.length
        if (stage === 1) return ctrlBook.length + 1 + String(ctrlChapter).length
        return ctrlBook.length + 1 + String(ctrlChapter).length + 1 + String(ctrlVerse).length
    }

    function _ctrlReset() {
        const code = activeTranslation
        const books = code ? _booksFor(code) : []
        ctrlStage   = 0
        ctrlBook    = (books.length > 0) ? books[0].name : ""
        ctrlChapter = 1
        ctrlVerse   = 1
        ctrlTyped   = ""
    }

    // Adopt the current searchText as controlled-mode segments. Returns true
    // when the text parses as "<book> <chap> <verse>" (or with a colon) and
    // the book resolves under the active translation — used on entry to
    // controlled mode so a memory-restored reference (e.g. search→reference
    // toggle) populates the segments instead of being wiped by _ctrlReset.
    function _ctrlHydrateFromQuery() {
        const q = AppState.searchText[tabKey] || ""
        const m = q.match(/^\s*(.+?)\s+(\d+)\s*[:\s]\s*(\d+)\s*$/)
        if (!m) return false
        const found = _findBookByPrefix(activeTranslation, m[1].trim())
        if (!found) return false
        ctrlStage   = 0
        ctrlBook    = found.name
        ctrlChapter = parseInt(m[2])
        ctrlVerse   = parseInt(m[3])
        ctrlTyped   = ""
        return true
    }

    // Determine which stage corresponds to a cursor position — used when the
    // operator clicks somewhere in the input to put the segment under the
    // click into edit mode.
    function ctrlStageAt(pos) {
        const bookEnd = ctrlBook.length
        const chapEnd = bookEnd + 1 + String(ctrlChapter).length
        if (pos <= bookEnd)              return 0
        if (pos <= chapEnd + 1)          return 1
        return 2
    }

    // Single key handler for controlled mode — branches on key + stage.
    // Returns true if the key was consumed (caller should accept the event).
    function _ctrlHandleKey(event) {
        // Backspace: remove a typed char, or retreat a stage when the buffer
        // is already empty and we're past stage 0.
        if (event.key === Qt.Key_Backspace) {
            if (ctrlTyped.length > 0) {
                ctrlTyped = ctrlTyped.substring(0, ctrlTyped.length - 1)
                _ctrlApplyTyped()
            } else if (ctrlStage > 0) {
                ctrlStage = ctrlStage - 1
                ctrlTyped = ""
            }
            return true
        }
        // Space / Tab: advance stage (if not already at the end).
        if (event.key === Qt.Key_Space || event.key === Qt.Key_Tab) {
            if (ctrlStage < 2) ctrlStage = ctrlStage + 1
            ctrlTyped = ""
            return true
        }
        // Up / Down / Enter / Return: let the existing nav handlers run.
        if (event.key === Qt.Key_Up
         || event.key === Qt.Key_Down
         || event.key === Qt.Key_Return
         || event.key === Qt.Key_Enter) {
            return false
        }
        // Single text character: route to stage handler.
        if (event.text && event.text.length === 1) {
            const ch = event.text
            if (ctrlStage === 0) {
                // Book stage: only letters / digits (e.g. "1 Samuel") accepted.
                if (!/[a-zA-Z0-9 ]/.test(ch)) return true
                const probe = ctrlTyped + ch
                const found = _findBookByPrefix(activeTranslation, probe)
                if (!found) return true   // no match — reject, keep buffer
                ctrlTyped = probe
                ctrlBook  = found.name
                // Reset chapter/verse to 1 since we just changed book.
                ctrlChapter = 1
                ctrlVerse   = 1
            } else if (ctrlStage === 1) {
                if (!/\d/.test(ch)) return true
                const probe   = ctrlTyped + ch
                const chapNum = parseInt(probe)
                if (isNaN(chapNum) || chapNum <= 0) return true
                const maxChap = _bookChapterCount(activeTranslation, ctrlBook)
                if (maxChap > 0 && chapNum > maxChap) return true
                ctrlTyped   = probe
                ctrlChapter = chapNum
                ctrlVerse   = 1   // chapter changed, reset verse
            } else if (ctrlStage === 2) {
                if (!/\d/.test(ch)) return true
                const probe    = ctrlTyped + ch
                const verseNum = parseInt(probe)
                if (isNaN(verseNum) || verseNum <= 0) return true
                const maxVerse = _chapterVerseCount(activeTranslation,
                                                    ctrlBook,
                                                    ctrlChapter)
                if (maxVerse > 0 && verseNum > maxVerse) return true
                ctrlTyped = probe
                ctrlVerse = verseNum
            }
            return true
        }
        return false
    }

    // Re-derive the current stage's value from the typed buffer. Used after
    // backspace so editing "20" → backspace → "2" updates ctrlChapter to 2.
    function _ctrlApplyTyped() {
        if (ctrlStage === 0) {
            const found = _findBookByPrefix(activeTranslation, ctrlTyped)
            if (found) ctrlBook = found.name
        } else if (ctrlStage === 1) {
            const v = parseInt(ctrlTyped)
            if (!isNaN(v) && v > 0) ctrlChapter = v
        } else if (ctrlStage === 2) {
            const v = parseInt(ctrlTyped)
            if (!isNaN(v) && v > 0) ctrlVerse = v
        }
    }

    // Apply the selection range for the current stage to the input. Defer
    // via Qt.callLater so the TextInput has finished re-laying out the new
    // displayed text before we ask it to select.
    function _ctrlApplySelection() {
        if (!isControlledMode) return
        const s = _ctrlSelStart(ctrlStage)
        const e = _ctrlSelEnd(ctrlStage)
        Qt.callLater(function() {
            if (inputField) inputField.select(s, e)
        })
    }

    // Crater-mode autocomplete: when the user presses space and the typed
    // text resolves to a book without a chapter yet, expand to "Book ".
    // Returns true if autocomplete fired (caller should consume the space).
    function _craterAutocomplete() {
        const code = activeTranslation
        if (!code || !queryText) return false
        const ref = BibleService.parseReference(queryText, code)
        if (!ref || !ref.text || ref.text.length === 0) return false
        // Only autocomplete when the user hasn't typed a chapter delimiter
        // yet. Once they have a chapter, space should be a literal space.
        if (queryText.indexOf(":") !== -1) return false
        if (/\d/.test(queryText)) return false
        const completed = ref.book + " "
        if (queryText.toLowerCase() === completed.toLowerCase()) return false
        AppState.setSearch(tabKey, completed)
        return true
    }

    // Compute placeholder + leading icon depending on tab + mode.
    readonly property string leadingIconName: {
        if (tabKey === "songs")     return songMode(mode).icon
        if (tabKey === "scripture") return mode === "reference" ? "book-open" : "search"
        return "search"
    }
    readonly property string placeholderText: {
        if (tabKey === "songs")     return songMode(mode).placeholder
        if (tabKey === "scripture") return mode === "reference" ? qsTr("Genesis 1 1") : qsTr("Search verses…")
        if (tabKey === "media")     return qsTr("Search media…")
        if (tabKey === "strongs")   return qsTr("Search Strong's…")
        if (tabKey === "themes")    return qsTr("Search themes…")
        return qsTr("Search…")
    }
    // macOS renders the modifier as ⌘ instead of Ctrl. Qt.platform.os returns
    // "osx" on macOS regardless of the actual marketing name (Sonoma, Sequoia,
    // etc.), so a single check is enough.
    readonly property string shortcutLabel: {
        const mod = Qt.platform.os === "osx" ? "⌘" : "Ctrl+"
        return tabKey === "scripture" ? (mod + "F") : (mod + "A")
    }

    // Interpreted reference (scripture tab, reference mode only). The
    // BibleService.parseReference already returns the full Verse, so we just
    // display "<book> <chapter>:<verse>" or "—" when unparseable.
    readonly property string activeTranslation:
        (AppState.activeLibraryGroup.scripture || "").toUpperCase()
    readonly property var parsedRef: {
        if (tabKey !== "scripture") return null
        if (mode !== "reference")   return null
        if (!queryText)             return null
        if (!activeTranslation)     return null
        const v = BibleService.parseReference(queryText, activeTranslation)
        return (v && v.text && v.text.length > 0) ? v : null
    }

    // Expose the input field so the tab can forceActiveFocus on it when
    // toggling mode / clearing query.
    property alias input: inputField

    // Toggle the scripture search mode (also bound to Ctrl+F at app level).
    function toggleScriptureMode() {
        const next = mode === "reference" ? "search" : "reference"
        AppState.setLibrarySearchModeWithMemory("scripture", next)
        inputField.forceActiveFocus()
    }

    // Cycle / pick the songs search mode.
    function setSongsMode(id) {
        AppState.setLibrarySearchMode("songs", id)
        inputField.forceActiveFocus()
    }

    implicitHeight: hintLabel.visible ? (inputBox.height + hintLabel.height + 4)
                                      : inputBox.height
    implicitWidth: 240

    // Move focus into the search input when the operator switches tabs so
    // they can start typing immediately. Mirrors Electron's createEffect that
    // focuses the per-tab search input on panel-focus change.
    Connections {
        target: AppState
        function onActiveTabChanged() {
            Qt.callLater(function() { inputField.forceActiveFocus() })
        }
    }
    Component.onCompleted: {
        Qt.callLater(function() { inputField.forceActiveFocus() })
        if (isControlledMode) _ctrlReset()
    }

    // Re-initialize controlled-mode state when translation changes or when
    // the operator flips into controlled mode. The new translation may have
    // a different book list, and entering controlled mode for the first
    // time needs sensible defaults (Genesis 1:1).
    onActiveTranslationChanged: {
        // Translation switched — caches are tied to the old code.
        _booksCache      = ({})
        _verseCountCache = ({})
        if (isControlledMode) _ctrlReset()
    }
    onIsControlledModeChanged: {
        if (isControlledMode) {
            // Prefer hydrating from the current query text so a memory-
            // restored reference (search→reference toggle) keeps its book/
            // chapter/verse instead of being reset. Falls back to the
            // default seed when the text isn't a parseable reference.
            if (!_ctrlHydrateFromQuery()) {
                _ctrlReset()
                // Push the seeded "Book 1 1" through the search pipeline so
                // the scripture list jumps to it immediately on mode entry.
                AppState.setSearch(tabKey, ctrlDisplay)
            }
            Qt.callLater(function() {
                inputField.forceActiveFocus()
                _ctrlApplySelection()
            })
        }
    }

    // External queryText updates (e.g. ScriptureTab click → setSearch with
    // "Exodus 1:2") need to flow back into the segmented state when we're in
    // controlled mode — otherwise the input text (bound to ctrlDisplay) would
    // ignore the change and continue showing the old "Genesis 1:1". The
    // `queryText === ctrlDisplay` guard skips self-driven updates: every
    // controlled-mode keystroke triggers ctrlDisplay → text → onTextChanged
    // → setSearch → queryText, which would otherwise cycle right back here.
    onQueryTextChanged: {
        if (!isControlledMode) return
        if (queryText === ctrlDisplay) return

        // Accept both separator styles ("Book 1:1" and "Book 1 1") so a
        // verse-click sync (which uses the space form) and any operator
        // who manually types a colon both round-trip correctly.
        const m = queryText.match(/^\s*(.+?)\s+(\d+)\s*[:\s]\s*(\d+)\s*$/)
        if (!m) return

        const found = _findBookByPrefix(activeTranslation, m[1].trim())
        if (!found) return

        ctrlBook    = found.name
        ctrlChapter = parseInt(m[2])
        ctrlVerse   = parseInt(m[3])
        ctrlTyped   = ""
    }

    // ── Search input row ────────────────────────────────────────────────
    Rectangle {
        id: inputBox
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 36
        radius: 0
        color: Theme.color.canvas
        border.color: inputField.activeFocus ? Theme.color.brand : Theme.color.borderStrong
        border.width: 1

        // 150ms matches Electron's `transition: all 0.15s ease` on the search
        // input's `_focusWithin` border. The instant token would snap; this
        // smooth tween reads as the input "lighting up" when focused.
        Behavior on border.color { ColorAnimation { duration: 150 } }

        // ── Leading: mode trigger (clickable when mode-switching is allowed)
        Rectangle {
            id: modeButton
            anchors.left: parent.left
            anchors.leftMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            // Content-sized: songs shows icon+chevron (~29px), other tabs show
            // just the icon (~16px) — a fixed width would clip the chevron on
            // songs or leave wasted padding elsewhere.
            width: modeRow.implicitWidth + 10
            height: 28
            radius: 0
            // Songs and Scripture get a real trigger; others render as a static icon.
            readonly property bool interactive:
                root.tabKey === "songs" || root.tabKey === "scripture"
            color: interactive && modeMa.containsMouse ? Theme.color.overlay : "transparent"
            Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

            Row {
                id: modeRow
                anchors.centerIn: parent
                spacing: 2

                AppIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: root.leadingIconName
                    color: Theme.color.textSecondary
                    size: Theme.icon.md
                }
                AppIcon {
                    visible: root.tabKey === "songs"
                    anchors.verticalCenter: parent.verticalCenter
                    name: "chevron-down"
                    color: Theme.color.textTertiary
                    size: Theme.icon.tiny
                }
            }

            MouseArea {
                id: modeMa
                anchors.fill: parent
                enabled: modeButton.interactive
                hoverEnabled: true
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor

                onClicked: {
                    if (root.tabKey === "songs") {
                        // Build the popover menu items inline from songModes.
                        const items = []
                        for (let i = 0; i < root.songModes.length; i++) {
                            const m = root.songModes[i]
                            items.push({
                                label:    m.label,
                                iconName: m.icon,
                                detail:   root.mode === m.id ? "✓" : "",
                                action:   function() { root.setSongsMode(m.id) }
                            })
                        }
                        AppState.openContextMenuAt(modeButton,
                            0, modeButton.height + 6,
                            items, { menuWidth: 200 })
                    } else if (root.tabKey === "scripture") {
                        root.toggleScriptureMode()
                    }
                }
            }
        }

        TextInput {
            id: inputField
            anchors.left: modeButton.right
            anchors.leftMargin: 4
            anchors.right: clearBtn.visible ? clearBtn.left
                          : hintChip.visible ? hintChip.left
                                             : parent.right
            anchors.rightMargin: Theme.space.sm
            anchors.verticalCenter: parent.verticalCenter
            color: Theme.color.textPrimary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.bodySize
            selectByMouse: true
            clip: true
            // Highlight color for the auto-selected stage segment in
            // controlled mode — brand-tinted so it reads as "active edit
            // target" instead of standard OS selection blue.
            selectionColor:     Theme.color.brandSubtle
            selectedTextColor:  Theme.color.textPrimary

            // Text source depends on input mode:
            //   controlled scripture → derived from _ctrl* state
            //   anything else        → the operator's typed query
            // The two-way write-back below pushes whatever ends up in the
            // input back into AppState.searchText so the existing parsedRef
            // / search pipelines (in ScriptureTab) see the same string.
            text: root.isControlledMode ? root.ctrlDisplay : root.queryText
            // Controlled mode owns editing — we manage characters via
            // Keys.onPressed below. Standard text editing is suppressed.
            readOnly: root.isControlledMode

            onTextChanged: {
                if (text !== root.queryText) AppState.setSearch(root.tabKey, text)
            }

            // Claim keyboard-focus ownership for the library panel whenever
            // the input gains focus. Main.qml's window-level shortcuts read
            // AppState.activeFocusPanel to decide whether Up/Down navigates
            // the library list or the schedule list — without this claim,
            // the schedule would steal the arrows even while the operator
            // is clearly typing in the library search.
            onActiveFocusChanged: {
                if (activeFocus) {
                    AppState.setActiveFocus("library")
                    // Re-apply the controlled-mode segment selection on focus
                    // (clicking outside dismisses the selection on most OSes).
                    if (root.isControlledMode) root._ctrlApplySelection()
                }
            }

            // I-beam cursor on hover. Raw QtQuick TextInput (vs the higher-
            // level TextField) doesn't set the cursor shape automatically,
            // so the operator hovering over the search input would see the
            // generic arrow — looks like a non-interactive label. The
            // overlay accepts no buttons (clicks pass through to the
            // TextInput's built-in mouse handling for cursor positioning
            // and selection).
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.NoButton
                cursorShape: Qt.IBeamCursor
                hoverEnabled: true
            }

            // Click on a segment selects that stage. The TextInput's own
            // mouse handling moves the cursor; we react to the cursor
            // position change to snap to the corresponding stage. Skipped
            // when the change came from our own select() call (which doesn't
            // alter the cursor's stage).
            onCursorPositionChanged: {
                if (!root.isControlledMode) return
                if (!activeFocus) return
                const stageAtCursor = root.ctrlStageAt(cursorPosition)
                if (stageAtCursor !== root.ctrlStage) {
                    root.ctrlStage = stageAtCursor
                    root.ctrlTyped = ""
                }
            }

            // Re-apply the segment selection whenever the controlled-mode
            // state changes (stage advance, character accepted, etc.). The
            // selection updates via an internal call deferred through
            // Qt.callLater so it happens after the TextInput re-lays out
            // for the new ctrlDisplay text.
            Connections {
                target: root
                function onCtrlStageChanged()   { root._ctrlApplySelection() }
                function onCtrlBookChanged()    { root._ctrlApplySelection() }
                function onCtrlChapterChanged() { root._ctrlApplySelection() }
                function onCtrlVerseChanged()   { root._ctrlApplySelection() }
            }

            // ── Input-mode key handlers ──────────────────────────────────
            // Controlled mode: every key flows through _ctrlHandleKey, which
            // updates stage state and validates against book metadata. It
            // returns false for keys it wants the existing nav handlers to
            // process (Up/Down/Enter), so those still work.
            //
            // Crater mode: a single special-case — space autocompletes the
            // current text to "<Book> " when it resolves to exactly a book
            // (no chapter typed yet). All other keys take the standard text-
            // editing path.
            Keys.onPressed: function(event) {
                // Ctrl+C — route to Clear instead of the text input's built-
                // in copy. QQuickTextInput's C++ code accepts the
                // ShortcutOverride event for QKeySequence::Copy while
                // editable+focused, which shadows the window-level
                // Shortcut element in Main.qml. Handling Ctrl+C here at the
                // KeyPress stage (after the override has fired) and
                // accepting the event suppresses TextInput's internal copy
                // handler and routes to clearLive(). Right-click → copy
                // still works in this field if the operator genuinely
                // needs to copy search text.
                if ((event.modifiers & Qt.ControlModifier)
                    && event.key === Qt.Key_C) {
                    AppState.clearLive()
                    event.accepted = true
                    return
                }

                // Media tab + grid view: Left/Right step the grid by one
                // tile, but only at a text boundary (start for Left, end
                // for Right) so editing search text keeps standard cursor
                // movement. Empty text trivially satisfies both boundary
                // checks so navigation works the moment the operator
                // arrives on the tab. List view is excluded — Up/Down
                // already cover the one-dimensional case there.
                if (root.tabKey === "media"
                    && AppState.mediaViewMode === "grid"
                    && AppState.activeFocusPanel === "library") {
                    if (event.key === Qt.Key_Left
                        && inputField.cursorPosition === 0) {
                        AppState.libraryNavigateLeft()
                        event.accepted = true
                        return
                    }
                    if (event.key === Qt.Key_Right
                        && inputField.cursorPosition === inputField.text.length) {
                        AppState.libraryNavigateRight()
                        event.accepted = true
                        return
                    }
                }

                if (root.isControlledMode) {
                    if (root._ctrlHandleKey(event)) {
                        event.accepted = true
                        return
                    }
                } else if (root.isCraterMode && event.key === Qt.Key_Space) {
                    if (root._craterAutocomplete()) {
                        event.accepted = true
                        return
                    }
                }
            }

            // Keyboard nav routed to the active library tab — but ONLY when
            // the library actually owns focus. If the operator clicked a
            // schedule row (flipping activeFocusPanel to "schedule") the
            // input may still hold OS-level focus visually; in that case we
            // bow out and let Main.qml's window shortcut route the key to
            // the schedule pane instead.
            Keys.onUpPressed: function(event) {
                if (AppState.activeFocusPanel !== "library") return
                AppState.libraryNavigateUp()
                event.accepted = true
            }
            Keys.onDownPressed: function(event) {
                if (AppState.activeFocusPanel !== "library") return
                AppState.libraryNavigateDown()
                event.accepted = true
            }
            Keys.onReturnPressed: function(event) {
                if (AppState.activeFocusPanel !== "library") return
                AppState.libraryActivate()
                event.accepted = true
            }
            Keys.onEnterPressed: function(event) {
                if (AppState.activeFocusPanel !== "library") return
                AppState.libraryActivate()
                event.accepted = true
            }

            // ShortcutOverride mirrors the same gate: when we own focus,
            // accept the override so the window-level Shortcut in Main.qml
            // is suppressed (preventing double-fire on Up/Down/Enter). When
            // we don't own focus, leave the override unaccepted so the
            // window Shortcut activates and routes to the right panel.
            Keys.onShortcutOverride: function(event) {
                if (AppState.activeFocusPanel !== "library") return
                if (event.key === Qt.Key_Up
                 || event.key === Qt.Key_Down
                 || event.key === Qt.Key_Return
                 || event.key === Qt.Key_Enter) {
                    event.accepted = true
                }
            }

            // Placeholder
            Text {
                visible: !inputField.activeFocus && inputField.text.length === 0
                anchors.verticalCenter: parent.verticalCenter
                text: root.placeholderText
                color: Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize
            }
        }

        // Clear (×) — shows whenever there's text. Hidden in controlled
        // mode because the displayed text is always populated by state and
        // "clear" has no meaningful behavior (use Backspace to retreat
        // through stages, or switch to crater mode for free editing).
        Rectangle {
            id: clearBtn
            visible: inputField.text.length > 0 && !root.isControlledMode
            anchors.right: hintChip.visible ? hintChip.left : parent.right
            anchors.rightMargin: hintChip.visible ? 2 : 6
            anchors.verticalCenter: parent.verticalCenter
            width: 22
            height: 22
            radius: 0
            color: clearMa.containsMouse ? Theme.color.overlay : "transparent"
            Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

            AppIcon {
                anchors.centerIn: parent
                name: "x"
                color: Theme.color.textTertiary
                size: Theme.icon.sm
            }

            MouseArea {
                id: clearMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    AppState.setSearch(root.tabKey, "")
                    inputField.forceActiveFocus()
                }
            }
        }

        // Shortcut hint chip — visible whenever the input is empty, including
        // while focused. Matches electron, where the ⌘F badge is always shown
        // until the operator starts typing.
        //
        // Content-sized + subtle border: a fixed width was clipping "Ctrl+A"
        // on Windows while leaving "⌘A" on macOS over-padded, and a strong
        // border made the chip read as a second input field competing with
        // the real one. Hairline border on a content-sized pill reads as a
        // quiet keycap hint instead.
        Rectangle {
            id: hintChip
            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            visible: inputField.text.length === 0
            width: hintText.implicitWidth + 12
            height: 18
            radius: 0
            color: Theme.color.elevated
            border.color: Theme.color.borderSubtle
            border.width: 1

            Text {
                id: hintText
                anchors.centerIn: parent
                text: root.shortcutLabel
                color: Theme.color.textTertiary
                font.family: Theme.font.monoFamily
                font.pixelSize: 11
            }
        }
    }

    // ── Interpreted hint (scripture / reference only) ───────────────────
    Text {
        id: hintLabel
        anchors.top: inputBox.bottom
        anchors.topMargin: 4
        anchors.left: parent.left
        anchors.leftMargin: 6
        visible: root.tabKey === "scripture"
              && root.mode === "reference"
              && root.queryText.length > 0
        text: root.parsedRef
              ? qsTr("Interpreted: ") + root.parsedRef.book + " "
                + root.parsedRef.chapter + " " + root.parsedRef.verse
              : qsTr("Interpreted: —")
        color: root.parsedRef ? Theme.color.textSecondary : Theme.color.textTertiary
        font.family: Theme.font.family
        // Body size (13px) — small enough to feel ancillary to the input
        // above, but large enough to read at a glance during live typing.
        font.pixelSize: Theme.font.bodySize
    }
}
