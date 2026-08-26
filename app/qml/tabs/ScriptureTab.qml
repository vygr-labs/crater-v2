import QtQuick
import QtQuick.Controls.Basic

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
    // Text last written into the search input BY a sync rather than typed.
    // _syncInputToVerse rewrites the box after a schedule click, a verse
    // click and an arrow step, and that rewrite drives parsedRef exactly as
    // a keystroke would — so onParsedRefChanged fires one debounce tick
    // later and, before this, CLAIMED the Preview pane with the library's
    // copy of the verse. That is the same schedule-edit-disappears bug the
    // refreshPreviewFor split fixes elsewhere, arriving by a slower route.
    //
    // Held only while the box still contains exactly what the sync wrote:
    // the moment the operator types anything else it clears below, and the
    // parser handlers go back to treating the edit as real intent.
    property string _syncedInputText: ""

    // Deliberately a FUNCTION, not a `readonly property bool` binding. As a
    // binding this read stale: _syncInputToVerse writes _syncedInputText and
    // the search text in one go, _reconcileQueryTranslation pushes
    // _debouncedQuery synchronously behind it, and onParsedRefChanged then
    // runs in that same cascade — BEFORE the binding re-evaluates. It
    // reported false with both strings already equal, so the push went
    // through and the schedule row's markup vanished anyway. A function is
    // evaluated at the call, so it cannot lag its own inputs.
    function _inputIsSyncEcho() {
        return _syncedInputText.length > 0 && _debouncedQuery === _syncedInputText
    }

    onQueryTextChanged: {
        // Anything that isn't verbatim the synced text is the operator
        // typing, so the echo grace ends here.
        if (queryText !== _syncedInputText) _syncedInputText = ""
        queryDebounce.restart()
        // Translation switch is INTENTIONALLY un-debounced — the operator
        // should see the sidebar flip the instant they finish typing the
        // code. Reconcile is cheap (one tokenize + hash lookup).
        _reconcileQueryTranslation()
    }

    // Translations come back as uppercase codes ("KJV"); the sidebar stores
    // them lowercase ("kjv").
    readonly property string activeTranslation:
        (AppState.activeLibraryGroup.scripture || "").toUpperCase()

    // ── Translation auto-switch from query token ────────────────────────
    // Typing a known translation code into the search input (e.g. "jn 3:16
    // NIV" or just "NIV") flips the active translation to that code. When
    // the operator backspaces the code out, we restore whichever translation
    // they were on before. Lets the operator pivot between versions without
    // taking their hand off the keyboard to click the sidebar.
    //
    // Code recognition is a Set of every installed translation's `.code`
    // uppercased; `BibleService.translations()` is the canonical source.
    // We rebuild on translationsChanged so freshly-imported translations
    // become typeable immediately (no app restart).
    readonly property var _translationCodeSet: {
        const set = {}
        const trs = BibleService.translations()
        for (let i = 0; i < trs.length; ++i) {
            set[String(trs[i].code).toUpperCase()] = true
        }
        return set
    }
    // The translation we switched to because the user typed its code, and
    // the translation we'll revert to when they remove it. Both empty when
    // no override is active.
    property string _queryOverrideCode:    ""
    property string _priorTranslation:     ""
    // Set just before we drive a translation switch ourselves, cleared on
    // the next tick. Lets onActiveTranslationChanged tell "we did this" from
    // "the operator clicked the sidebar."
    property bool   _switchingFromOverride: false

    // Scan `text` for the first whole-word token that matches an installed
    // translation code. Case-insensitive. Returns "" when nothing matches.
    function _detectQueryTranslation(text) {
        const tokens = String(text || "").split(/\s+/)
        for (let i = 0; i < tokens.length; ++i) {
            const t = String(tokens[i]).toUpperCase()
            if (t.length > 0 && _translationCodeSet[t]) return t
        }
        return ""
    }

    // Same scan + strip — returns the query with the recognized translation
    // token removed so the reference parser and FTS search don't have to
    // deal with the trailing/leading "NIV" remnant.
    function _strippedQuery(text) {
        const t = String(text || "")
        const detected = _detectQueryTranslation(t)
        if (!detected) return t
        // Whole-word, case-insensitive replace, single occurrence (the one
        // _detectQueryTranslation found). \b boundaries keep "KJV" from
        // chewing into a hypothetical "KJV2".
        const re = new RegExp("\\b" + detected + "\\b", "i")
        return t.replace(re, "").replace(/\s+/g, " ").trim()
    }

    // React to query edits: switch translation if a code appeared, revert
    // if it disappeared. Drives off raw queryText (not the debounced shadow)
    // so the sidebar flip is instant — feels like the input owns the
    // translation while a code is in it.
    //
    // Critical: after switching translation, force _debouncedQuery to the
    // current queryText synchronously. parsedRef reads _parserQuery which
    // reads _debouncedQuery; without this push, parsedRef would re-evaluate
    // against the new translation but the OLD query, leaving the cursor on
    // whatever stale row matched, until the 120 ms debounce eventually
    // fires and corrects it. The force-push collapses that race into one
    // deterministic tick — the same well-tested onParsedRefChanged path
    // that handles normal reference typing does all the cursor work.
    function _reconcileQueryTranslation() {
        const detected = _detectQueryTranslation(queryText)
        if (detected) {
            if (detected !== activeTranslation && detected !== _queryOverrideCode) {
                if (_priorTranslation === "") {
                    _priorTranslation = activeTranslation
                }
                _queryOverrideCode = detected
                _switchingFromOverride = true
                AppState.setLibraryGroup(tabKey, detected.toLowerCase())
                _debouncedQuery = queryText
                Qt.callLater(function() { _switchingFromOverride = false })
            }
        } else if (_queryOverrideCode !== "" && _priorTranslation !== "") {
            const prev = _priorTranslation
            _queryOverrideCode = ""
            _priorTranslation  = ""
            _switchingFromOverride = true
            AppState.setLibraryGroup(tabKey, prev.toLowerCase())
            _debouncedQuery = queryText
            Qt.callLater(function() { _switchingFromOverride = false })
        }
    }

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
    // Strip any translation-code token from the debounced query before
    // handing it to the reference parser / FTS search — those paths only
    // care about the verse-reference / search-text portion. Without this,
    // "jn 3:16 NIV" would parse with "NIV" as a stray trailing token and
    // a bare "NIV" search would yield zero hits while the switch quietly
    // succeeded behind it. Stripping makes the typed code feel like a
    // sidebar control: it changes the corpus, it doesn't filter inside.
    readonly property string _parserQuery: _strippedQuery(_debouncedQuery)

    readonly property var currentVerses: {
        if (mode === "search" && _parserQuery.length > 0) {
            // Empty filter → search every imported translation at once; the
            // hit list then spans versions (each row shows its own chip).
            const scope = AppState.scriptureSearchAllTranslations ? "" : activeTranslation
            return BibleService.search(_parserQuery, scope)
        }
        return versesForActiveTranslation
    }

    // Reference-parser result (reference mode only). Used to scroll-to-match.
    readonly property var parsedRef: {
        if (mode !== "reference") return null
        if (_parserQuery.length === 0) return null
        const v = BibleService.parseReference(_parserQuery, activeTranslation)
        return (v && v.text && v.text.length > 0) ? v : null
    }

    // The same input read as a SPAN. parsedRef collapses "John 3:16-18" to
    // its opening verse, which is what scroll-to-match and the "Interpreted"
    // hint want; this one keeps both bounds so a typed dash can stage the
    // whole passage on one slide. verseEnd equals verseStart for a plain
    // reference, so the range branch below is the only place that has to
    // care about the difference.
    //
    // Deliberately NOT gated on the verse text existing (the way parsedRef
    // is). This is a pure parse; whether the rows are present is decided
    // against currentVerses when the range is applied, so a range typed
    // while a translation is still loading fails on the lookup rather than
    // on the parse.
    readonly property var parsedRange: {
        if (mode !== "reference") return null
        if (_parserQuery.length === 0) return null
        const r = BibleService.parseReferenceRange(_parserQuery)
        return (r && r.valid) ? r : null
    }

    // True while the current multi-selection came from a typed range rather
    // than from clicks. Only a selection WE created gets torn down when the
    // operator narrows the input back to a single verse — otherwise every
    // re-parse would quietly wipe a set they built with Shift+click.
    property bool _rangeFromInput: false

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
    // _pendingRetargetCoord: translation switch → keep the operator on the
    //                        verse they were reading, in the new version.
    // Each is a `{book, chapter, verse}` shape (or null when nothing pending).
    property var _pendingSyncCoord:     null
    property var _pendingPushLiveCoord: null
    property var _pendingRetargetCoord: null

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
            // Clipboard-ready text in the "quote + attribution" format. Built
            // here so it rides along to Preview/Live/Schedule — any surface
            // holding the item can copy without re-deriving the verse text.
            copyText: _formatCopyText([verse]),
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
        //
        // The verse number is wrapped in DSL markup — bold (**…**) so it
        // reads as the heaviest run on the slide, and {color=yellow} (the
        // palette's #fdd835, the same gold the default theme uses for its
        // reference label) so it stands distinct from the verse body. This
        // is build-time, not render-time, on purpose: every surface that
        // shows this content (ProjectionContentLayer, ThemedMonitor, and the
        // Preview/Live page-list cards) feeds it through LyricsService.dslToHtml,
        // so a concrete color marker renders identically on all of them. A
        // per-theme "match the scriptureRef node color" scheme would only
        // reach the two resolveText paths and skip the thumbnail cards.
        // dslToHtml HTML-escapes the body text, so only our own markers are
        // interpreted; the verse body already flowed through the DSL parser
        // before this change, so no new escaping surface is introduced.
        // Trailing period ("3.") sits INSIDE the bold+color markup so the dot
        // inherits the same gold/bold styling as the digit — it reads as a
        // numbered marker rather than a bare digit colliding with the verse's
        // first word (and a separate unstyled dot would render plain white).
        // Passage builder — one styled run per verse, joined by two spaces.
        // activeIndex >= 0 dims every verse except that one (progressive-
        // highlight mode); -1 leaves them all bright (the default all-on-one-
        // slide look). Dimming is color-only ({color=gray}) so glyph metrics —
        // and therefore the binary-search auto-fit size — stay identical across
        // pages; stepping the highlight never resizes the text. (Note: gray
        // reads as "dimmed" on the dark backgrounds projection themes almost
        // always use; a light-background theme would want the inverse.)
        const composePassage = function(activeIndex) {
            return usable.map(function(v, j) {
                const num  = "{color=yellow}**" + v.verse + ".**{/color} "
                const body = (activeIndex < 0 || j === activeIndex)
                    ? v.text
                    : "{color=gray}" + v.text + "{/color}"
                return num + body
            }).join("  ")
        }

        // Progressive highlight (Settings > Scripture > Highlight current verse)
        // turns the passage into one page per verse — each page shows the whole
        // passage with that verse lit and the rest dimmed — so the normal slide
        // nav walks the highlight. Off → a single combined slide (unchanged).
        // Baked here at selection time, so a settings change applies to the
        // next projected passage.
        let pages
        if (SettingsService.highlightCurrentVerse) {
            pages = usable.map(function(v, i) {
                return { label:   v.book + " " + v.chapter + ":" + v.verse,
                         content: composePassage(i) }
            })
        } else {
            pages = [{ label: _formatVerseRangeTitle(usable), content: composePassage(-1) }]
        }

        const first = usable[0]
        const last  = usable[usable.length - 1]
        return {
            kind:     "scripture",
            title:    title,
            subtitle: "",
            // Flowing-quote clipboard text for the whole selection (see
            // _formatCopyText). Distinct from `combined` above, which numbers
            // each verse for the projection slide.
            copyText: _formatCopyText(usable),
            pages:    pages,
            scriptureRef: {
                translationCode: code,
                book:            first.book,
                chapter:         first.chapter,
                verseStart:      first.verse,
                verseEnd:        last.verse
            }
        }
    }

    // Build the "copy to clipboard" string for a verse array — the format the
    // operator pastes into a YouTube description, sermon notes, etc. The verses
    // flow as one quoted passage (no inline verse numbers), then the reference
    // (book chapter:verse + translation) follows below on its own attribution
    // line:
    //
    //   "For God so loved the world... to condemn the world..."
    //
    //   - John 3:16-17 (KJV)
    //
    // Straight ASCII quotes (not typographic) keep the paste clean across web
    // inputs. Reuses _formatVerseRangeTitle so the reference shape matches the
    // projection title (collapsed ranges + translation) exactly. Returns ""
    // when nothing usable is passed, so callers can guard on empty instead of
    // copying a bare reference.
    function _formatCopyText(verses) {
        if (!verses || verses.length === 0) return ""
        const usable = verses.filter(function(v) { return v && v.text && v.text.length > 0 })
        if (usable.length === 0) return ""
        const first = usable[0]
        const code = (first.translationCode && first.translationCode.length > 0)
                       ? first.translationCode : activeTranslation
        const body = usable.map(function(v) { return v.text }).join(" ")
        // Reference (book chapter:verse). _formatVerseRangeTitle collapses a
        // multi-verse selection into ranges; fall back to the first verse's own
        // coords if it ever returns empty so the attribution line is never
        // blank. Translation in parens only when we actually have a code.
        let ref = _formatVerseRangeTitle(usable)
        if (ref.length === 0 && first.book)
            ref = first.book + " " + first.chapter + ":" + first.verse
        const attribution = (code && code.length > 0) ? ref + " (" + code + ")" : ref
        return "\"" + body + "\"\n\n- " + attribution
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

    // Incidental-path sibling of pushPreviewFor. Resolves the same item, but
    // routes through AppState.refreshLibraryPreview so it can only UPDATE a
    // preview the library already owns — never take the pane off a schedule
    // row the operator staged (and possibly marked up in the schedule item
    // editor). Used by every path the operator did not directly ask for: a
    // model reload, this tab's async Loader finishing, switching back into
    // the tab.
    function refreshPreviewFor(idx) {
        if (AppState.tabKeys[AppState.activeTab] !== tabKey) return
        const sel = AppState.librarySelectedIndices[tabKey] || []
        AppState.refreshLibraryPreview((sel.length > 0) ? _activeItem() : verseItemAt(idx))
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
        let text = v.book + " " + v.chapter + " " + v.verse
        // Preserve the translation override across sync rewrites. Without
        // this, arrow-key navigation overwrites the input with a plain
        // reference, the reconcile sees no translation token, and reverts
        // the operator to the prior version mid-scroll. Re-appending the
        // active override keeps the typed-code state alive as long as the
        // operator is still navigating the synced reference.
        if (_queryOverrideCode !== "") text += " " + _queryOverrideCode
        _syncedInputText = text
        AppState.setSearch(tabKey, text)
    }

    // A typed range selects the span. Runs independently of
    // onParsedRefChanged because the two fire on different edits: appending
    // "-18" to "John 3:16" leaves the opening verse untouched, so
    // parsedRef never changes and only this handler sees the edit.
    onParsedRangeChanged: {
        const r = parsedRange
        if (!r) return
        if (r.verseEnd > r.verseStart) {
            const lo = indexOf(r.book, r.chapter, r.verseStart)
            if (lo < 0) return
            // A missing end row (range runs past the chapter, or the
            // translation splits verses differently) degrades to the opening
            // verse instead of selecting nothing.
            const hiMatch = indexOf(r.book, r.chapter, r.verseEnd)
            const hi = (hiMatch >= lo) ? hiMatch : lo
            const range = []
            for (let i = lo; i <= hi; ++i) range.push(i)
            _rangeFromInput = true
            AppState.setLibraryFluid(tabKey, lo)
            AppState.setLibrarySelected(tabKey, range)
            list.positionViewAtIndex(lo, ListView.Contain)
            if (_inputIsSyncEcho()) refreshPreviewFor(lo)
            else                    pushPreviewFor(lo)
        } else if (_rangeFromInput) {
            _rangeFromInput = false
            AppState.clearLibrarySelected(tabKey)
        }
    }

    // When the parser yields a match, scroll there and highlight.
    onParsedRefChanged: {
        if (!parsedRef) return
        const idx = indexOf(parsedRef.book, parsedRef.chapter, parsedRef.verse)
        if (idx >= 0) {
            AppState.setLibraryFluid(tabKey, idx)
            list.positionViewAtIndex(idx, ListView.Contain)
            if (_inputIsSyncEcho()) refreshPreviewFor(idx)
            else                    pushPreviewFor(idx)
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
            // Nothing to resolve against (translation selected but no rows
            // imported). Drop the queued retarget rather than let it outlive
            // its cascade and fire against some unrelated later corpus.
            _pendingRetargetCoord = null
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
                refreshPreviewFor(syncIdx)
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

        // Drain a queued translation-switch retarget (see
        // onActiveTranslationChanged) against the corpus that just landed.
        // This has to run here, not there: only now do we hold the verses
        // the coordinates should be resolved against.
        let idx = -1
        if (_pendingRetargetCoord) {
            idx = findBestVerseMatch(currentVerses,
                _pendingRetargetCoord.book,
                _pendingRetargetCoord.chapter,
                _pendingRetargetCoord.verse)
            _pendingRetargetCoord = null
            // Verse simply isn't in this translation (different splits, or a
            // canon that doesn't carry it) — the top of the list is honest,
            // a carried-over row number is not.
            if (idx < 0) idx = 0
        }
        // No retarget pending: same corpus, so the row number still means
        // what it did (search-mode keystrokes, mode flips).
        if (idx < 0) idx = (fluidIndex >= 0 && fluidIndex < n) ? fluidIndex : 0
        if (idx !== fluidIndex) AppState.setLibraryFluid(tabKey, idx)
        refreshPreviewFor(idx)

        // Force-resync list.currentIndex with fluidIndex AND re-center the
        // viewport — but only when needed. ListView's model-swap path
        // internally writes currentIndex = 0, which the standalone Binding
        // doesn't recover from (it only re-pushes when its `value` —
        // fluidIndex — changes; fluidIndex hasn't changed). The
        // search-mode keystroke path also fires this handler but usually
        // doesn't break the binding, so the re-sync is a no-op there
        // — and the Center scroll would jolt the viewport on every
        // typed character. Guarding both behind the "binding broke"
        // check avoids that lag.
        Qt.callLater(function() {
            // Re-read fluidIndex instead of closing over `idx`.
            // onParsedRefChanged and onParsedRangeChanged run later in this
            // same change cascade and legitimately move the focus; a
            // captured `idx` would fire afterwards and stomp the highlight
            // back onto the row that was current when this handler ran,
            // leaving list.currentIndex disagreeing with fluidIndex and the
            // preview until the next arrow key knocked them back in sync.
            const want = root.fluidIndex
            if (want < 0 || want >= root.currentVerses.length) return
            if (list.currentIndex === want) return
            list.currentIndex = want
            list.positionViewAtIndex(want, ListView.Center)
        })
    }

    // Refresh preview when the operator switches into this tab.
    Connections {
        target: AppState
        function onActiveTabChanged() {
            if (AppState.tabKeys[AppState.activeTab] !== root.tabKey) return
            if (root.fluidIndex >= 0) root.refreshPreviewFor(root.fluidIndex)
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
                    root.refreshPreviewFor(idx)
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
        // If the operator flipped translation manually (sidebar click or
        // dblclick), our remembered "prior" is stale — backspacing the
        // typed code later should NOT yank them back. Detect "not us"
        // via the _switchingFromOverride one-tick flag.
        if (!_switchingFromOverride && _queryOverrideCode !== "") {
            _queryOverrideCode = ""
            _priorTranslation  = ""
        }
        AppState.clearLibrarySelected(tabKey)

        // Queue the focused verse rather than looking it up here.
        // `activeTranslation` changes FIRST; the
        // versesForActiveTranslation → currentVerses chain only re-resolves
        // after this handler returns, so an indexOf at this point searches
        // the OUTGOING translation and yields a row number that means a
        // different verse in the incoming one — translations split verses
        // differently ("1-2" rows, "2a" subdivisions), so the same index
        // drifts. onCurrentVersesChanged then treats any in-range fluidIndex
        // as still valid and keeps it, which is how the operator ends up
        // some rows off the verse they were on while the reference input
        // still reads correctly. Same queue-and-drain shape the schedule
        // sync above already uses, and for the same reason.
        if (_focusedCoord) {
            _pendingRetargetCoord = {
                book:    _focusedCoord.book,
                chapter: _focusedCoord.chapter,
                verse:   _focusedCoord.verse
            }
        }

        // When we drove the switch via the typed-code override, leave
        // cursor placement to onParsedRefChanged (it already ran with
        // synchronously-pushed _debouncedQuery). But the model swap
        // also reset ListView's viewport to the top, and Contain-mode
        // positionViewAtIndex in onCurrentIndexChanged is too lazy to
        // re-scroll once the focused row is technically visible
        // anywhere in the viewport. Force-center on the actual
        // fluidIndex AFTER the cascade settles so the operator sees
        // the highlighted verse in the middle of the list instead of
        // perceiving Gen 1:1 at top as "the highlight."
        if (_switchingFromOverride) {
            Qt.callLater(function() {
                if (root.fluidIndex >= 0 && root.fluidIndex < root.currentVerses.length)
                    list.positionViewAtIndex(root.fluidIndex, ListView.Center)
            })
            return
        }

        // Nothing focused to preserve — open the new translation at the top.
        // Everything else is handled by the queued retarget, which resolves
        // (and re-centers) in onCurrentVersesChanged once the corpus lands.
        if (!_focusedCoord) AppState.setLibraryFluid(tabKey, 0)
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

        // Copy the active scripture selection to the system clipboard in the
        // "quote + attribution" format (_formatCopyText). Sits just left of the
        // gear menu. Enabled whenever there's a focused/selected verse — on the
        // scripture tab that's almost always true, so copy is one click away.
        IconButton {
            id: copyBtn
            anchors.right: allVersionsBtn.left
            anchors.rightMargin: Theme.space.xs
            anchors.verticalCenter: parent.verticalCenter
            iconName: copyBtn._copied ? "check" : "copy"
            iconSize: Theme.icon.sm
            enabled: root._activeVerses().length > 0

            // Momentary check-glyph confirmation after a copy. There's no
            // global toast in this console, so the icon itself is the feedback.
            property bool _copied: false
            Timer {
                id: copiedReset
                interval: 1200
                onTriggered: copyBtn._copied = false
            }

            onClicked: {
                const text = root._formatCopyText(root._activeVerses())
                if (text.length === 0) return
                ClipboardService.setText(text)
                copyBtn._copied = true
                copiedReset.restart()
            }
        }

        // All-versions toggle — only meaningful in FTS search mode, so it shows
        // (and reserves its width) only then. Surfaces the "search every
        // imported translation" switch as a first-class action-bar button next
        // to copy + gear (the gear menu keeps its item too). Active state paints
        // the icon brand so the operator sees at a glance that results span
        // versions.
        IconButton {
            id: allVersionsBtn
            anchors.right: gearBtn.left
            anchors.rightMargin: Theme.space.xs
            anchors.verticalCenter: parent.verticalCenter
            visible: root.mode === "search"
            width: visible ? implicitWidth : 0
            iconName: "library"
            iconSize: Theme.icon.sm
            tint:      AppState.scriptureSearchAllTranslations ? Theme.color.brand
                                                               : Theme.color.textSecondary
            tintHover: AppState.scriptureSearchAllTranslations ? Theme.color.brand
                                                               : Theme.color.textPrimary
            onClicked: AppState.setScriptureSearchAllTranslations(
                           !AppState.scriptureSearchAllTranslations)
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
                        // FTS-search-only: scope toggle across translations.
                        ...(root.mode === "search" ? [
                            { label: qsTr("Search all translations"),
                              iconName: "book",
                              detail: AppState.scriptureSearchAllTranslations ? "✓" : "",
                              action: function() {
                                  AppState.setScriptureSearchAllTranslations(
                                      !AppState.scriptureSearchAllTranslations)
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
        ScrollBar.vertical: AppScrollBar {}

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

        // NOT an inline `currentIndex: root.fluidIndex` binding. Qt 6
        // ListView resets currentIndex to 0 internally whenever the
        // `model` property is reassigned (e.g. translation switch), and
        // that imperative write *permanently breaks* an inline binding.
        // The standalone Binding below re-pushes fluidIndex into
        // currentIndex on every fluidIndex change, so the binding
        // survives model swaps. Symptom of the inline form: after
        // typing a translation code, the visual highlight stuck on
        // Gen 1:1 even though fluidIndex was on the right verse —
        // arrow keys would then jump from the misleading Gen 1:1 to
        // the actual focused verse + 1 (e.g. Gen 1:3 + Down → Gen 1:4
        // with the highlight visually skipping 1:2/1:3).

        onCurrentIndexChanged: {
            const v = root.currentVerses[currentIndex]
            if (v) {
                root._focusedCoord = { book: v.book, chapter: v.chapter, verse: v.verse }
                positionViewAtIndex(currentIndex, ListView.Contain)
            }
        }

        delegate: Item {
            id: verseRow
            width: list.width - Theme.size.scrollBar   // leave the scrollbar its lane
            // 36 (was 40) — dropping the redundant per-row book icon
            // freed enough horizontal weight that the row no longer needs
            // 40 px to breathe. Density win on long passages: Psalm 119
            // gains ~10 visible rows on a 1080p screen.
            height: 36

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

            // The per-row book icon used to live here. Removed because the
            // list is type-homogeneous (every row is a verse) and the
            // translation chip on the right already anchors row identity.
            // The selected-row brand wash + the new left accent bar below
            // do everything the icon was doing for focus indication.

            // Left brand-accent bar — visible only when the row is the
            // anchor or part of a multi-selection. 2 px flush to the row's
            // left edge, brand-cyan. Replaces the icon's role as "this row
            // is the focus" with a smaller, more deliberate UI affordance
            // (pattern matches Mail / Things / Linear list anchors).
            Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: 2
                color: Theme.color.brand
                visible: verseRow._highlighted
                opacity: verseRow._paneFocused ? 1.0 : 0.5
            }

            Text {
                id: verseText
                // Anchored to the row's left edge with Theme.space.lg
                // padding — slightly more generous than the old icon's
                // leftMargin so the text breathes against the wash edge
                // and (crucially) doesn't sit directly against the 2 px
                // accent bar when a row is highlighted.
                anchors.left: parent.left
                anchors.leftMargin: Theme.space.lg
                anchors.right: refLabel.left
                anchors.rightMargin: Theme.space.md
                anchors.verticalCenter: parent.verticalCenter
                // In FTS search mode, bold the matched terms inside the verse
                // (StyledText) — unless the operator turned scripture highlight
                // off (Settings › Search). Plain text otherwise so eliding stays
                // cheap and no escaping is needed on the hot non-search path.
                readonly property bool _colorize:
                    root.mode === "search" && root._parserQuery.length > 0
                    && SettingsService.highlightScriptureMatches
                textFormat: _colorize ? Text.StyledText : Text.PlainText
                text: _colorize
                        ? SearchFormat.markup(modelData.text || "", root._parserQuery,
                                              Theme.color.brand)
                        : (modelData.text || "")
                // Selected: `textTitle` (gray.300) softer-than-textPrimary
                // tone with semiBold (600) weight bump. Bolder strokes +
                // softer color = same perceived presence with less raw
                // luminance, addressing the eye-strain from pure white.
                // textTitle both ways — highlight is carried by the weight
                // bump + accent bar below, not the text colour. (Was a
                // hardcoded gray.300 that stayed light-on-white in light mode.)
                color: Theme.color.textTitle
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

                // Remembers the multi-selection that a plain click just
                // collapsed, so a following double-click can restore it and
                // project the whole combined slide instead of one verse.
                // Reset at the top of onLeftClicked (click 1 of a double-click
                // runs there first); consumed and cleared in onDoubleClicked.
                property var _collapseStash: null

                // Group order matches SongsTab and MediaTab: row-edit
                // actions first (Mark Up — closest scripture analogue to
                // Edit), then projection (Add to Schedule / Push to Live),
                // then organization (Favorites / Collection), then utility
                // (Refresh) last. Verses have no destructive action — they
                // come from immutable Bible DBs — so the bottom slot stays
                // safe rather than dangerous.
                menuItems: [
                    { label: qsTr("Mark Up"),            iconName: "edit-3" },
                    { separator: true },
                    { label: qsTr("Add to Schedule"), iconName: "plus",
                      action: function() { root.addToScheduleFor(index) } },
                    { label: qsTr("Push to Live"), iconName: "play",
                      action: function() { root.pushLiveFor(index) } },
                    { separator: true },
                    { label: qsTr("Add to Favorites"),   iconName: "heart" },
                    { label: qsTr("Add to Collection…"), iconName: "folder" },
                    { separator: true },
                    { label: qsTr("Refresh"), iconName: "refresh-cw" }
                ]

                // Single-row focus path — used by plain clicks AND by
                // right-clicks that land on rows outside the current
                // selection (so the context menu acts on what was just
                // visually pointed at, the way every desktop file manager
                // works).
                //
                // Clears any prior multi-selection ONLY when the click lands
                // on a row that isn't already highlighted. Clicking a row
                // that IS part of the current selection keeps the set intact,
                // because the first click of a double-click-to-go-live fires
                // onLeftClicked (→ _focus) BEFORE onDoubleClicked. Without
                // this guard that first click wiped the multi-selection, so
                // double-clicking a multi-verse range silently sent only the
                // one clicked verse Live instead of the combined slide. With
                // it, the set survives into onDoubleClicked → pushLiveFor.
                function _focus() {
                    // Capture membership BEFORE moving the anchor. setLibraryFluid
                    // flips list.currentIndex (via the standalone Binding), which
                    // makes _selected — and therefore _highlighted — read true for
                    // THIS row. Reading the guard after that write would always see
                    // true and skip the clear, so a plain/shift click after a
                    // multi-selection failed to collapse it and the clicked row got
                    // folded into the active set instead of replacing it.
                    const wasHighlighted = verseRow._highlighted
                    // TEMP DIAGNOSTIC — this is the guard under suspicion. If
                    // wasHighlighted is true here on a plain click, the prior
                    // multi-selection survives and _activeIndices() folds this
                    // row into it, which is the reported "adds instead of replaces".
                    console.log("[verse-click] _focus idx=" + index
                              + " wasHighlighted=" + wasHighlighted
                              + " willClear=" + !wasHighlighted
                              + " fluid=" + root.fluidIndex
                              + " listCurrent=" + list.currentIndex
                              + " selBefore=[" + (AppState.librarySelectedIndices[root.tabKey] || []) + "]")
                    AppState.setLibraryFluid(root.tabKey, index)
                    if (!wasHighlighted) {
                        AppState.clearLibrarySelected(root.tabKey)
                    }
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
                    const removed = at >= 0
                    if (removed) sel.splice(at, 1)
                    else         sel.push(index)

                    // Anchor placement. Adding a row (or removing the last one,
                    // leaving an empty set) anchors on the clicked row — Finder
                    // semantics, and the empty case falls back to single-row
                    // focus on it. But when we REMOVE a row that still has
                    // company, anchoring on the just-removed row would defeat the
                    // deselect: _activeIndices() folds the anchor back into the
                    // active set and _selected keeps it highlighted, so the row
                    // would never actually leave. So keep the anchor where it was
                    // — or hop it onto a surviving row if the removed row WAS the
                    // anchor.
                    let anchorIdx
                    if (!removed || sel.length === 0) anchorIdx = index
                    else if (root.fluidIndex === index) anchorIdx = sel[sel.length - 1]
                    else                                anchorIdx = root.fluidIndex

                    AppState.setLibraryFluid(root.tabKey, anchorIdx)
                    AppState.setLibrarySelected(root.tabKey, sel)
                    AppState.setActiveFocus("library")
                    root.pushPreviewFor(anchorIdx)
                }

                // TEMP DIAGNOSTIC (multi-select collapse bug) — remove before release.
                // Writes one line per verse click to crater.log. In a dev tree that's
                // <repo>/personal/crater.log; in an installed build it's
                // %APPDATA%/Crater/crater.log (see main.cpp resolveLogDir).
                function _dbg(tag) {
                    console.log("[verse-click] " + tag
                              + " idx=" + index
                              + " mods=" + mouse_modifiers_dbg
                              + " fluid=" + root.fluidIndex
                              + " listCurrent=" + list.currentIndex
                              + " _selected=" + verseRow._selected
                              + " _inMulti=" + verseRow._inMulti
                              + " _highlighted=" + verseRow._highlighted
                              + " sel=[" + (AppState.librarySelectedIndices[root.tabKey] || []) + "]")
                }
                property int mouse_modifiers_dbg: 0

                onLeftClicked: function(mouse) {
                    // Fresh click — discard any prior collapse stash. The
                    // member-collapse branch below re-arms it when relevant.
                    verseMa._collapseStash = null
                    verseMa.mouse_modifiers_dbg = mouse.modifiers          // TEMP DIAGNOSTIC
                    _dbg("enter  shift=" + !!(mouse.modifiers & Qt.ShiftModifier)
                              + " ctrl=" + !!(mouse.modifiers & (Qt.ControlModifier | Qt.MetaModifier)))
                    if (mouse.modifiers & Qt.ShiftModifier) {
                        _extendRange()
                        _dbg("after:extendRange")                          // TEMP DIAGNOSTIC
                    } else if (mouse.modifiers & (Qt.ControlModifier | Qt.MetaModifier)) {
                        _toggleInSet()
                        _dbg("after:toggleInSet")                          // TEMP DIAGNOSTIC
                    } else {
                        const selArr = AppState.librarySelectedIndices[root.tabKey] || []
                        if (selArr.length > 0 && verseRow._highlighted) {
                            // Plain click on a member of an active multi-
                            // selection: collapse to just this verse NOW, so the
                            // operator gets instant feedback. Stash the prior set
                            // first — if this is actually click 1 of a double-
                            // click, onDoubleClicked restores it and projects the
                            // whole combined slide. Collapsing instantly (vs. a
                            // deferred timer) avoids a "did it register?" double-
                            // tap that would otherwise send the whole set Live.
                            verseMa._collapseStash = selArr.slice()
                            AppState.clearLibrarySelected(root.tabKey)
                            AppState.setLibraryFluid(root.tabKey, index)
                            AppState.setActiveFocus("library")
                            root.pushPreviewFor(index)
                            root._syncInputToVerse(index)
                            _dbg("after:collapse")                         // TEMP DIAGNOSTIC
                        } else {
                            _focus()
                            _dbg("after:focus")                            // TEMP DIAGNOSTIC
                        }
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
                    // If click 1 collapsed a multi-selection, restore it so the
                    // double-click projects the whole combined slide rather than
                    // only this verse. Preview is re-pushed to match Live.
                    if (verseMa._collapseStash && verseMa._collapseStash.length > 0) {
                        AppState.setLibrarySelected(root.tabKey, verseMa._collapseStash)
                    }
                    verseMa._collapseStash = null
                    AppState.setLibraryFluid(root.tabKey, index)
                    AppState.setActiveFocus("library")
                    root._syncInputToVerse(index)
                    root.pushPreviewFor(index)
                    root.pushLiveFor(index)
                }
            }
        }
    }

    // Survives the model-swap binding-break described above the ListView.
    // Without this, the ListView's internal setCurrentIndex(0) call during
    // a translation switch leaves currentIndex stuck at 0 forever; with it,
    // every fluidIndex change re-pushes into currentIndex.
    Binding {
        target: list
        property: "currentIndex"
        value: root.fluidIndex
        restoreMode: Binding.RestoreBindingOrValue
    }

    // Shift+Arrow — grow or shrink the selection instead of moving it. The
    // anchor (fluidIndex) is the fixed pivot, exactly as it is for
    // Shift+click; what moves is the far end of the range.
    //
    // That far end is not stored anywhere, so it is recovered from the set:
    // a range built this way always spans anchor..cursor, so whichever
    // endpoint is not the anchor IS the cursor. With no selection yet the
    // cursor starts on the anchor, which makes the first Shift+Arrow select
    // two rows rather than one.
    //
    // The reference input is deliberately left alone here. Rewriting it
    // would re-trigger the parse, and onParsedRangeChanged would then reset
    // the anchor to the low end of the range — extending upward would fight
    // itself after a single keypress.
    function _extendSelectionByKey(dir) {
        const n = currentVerses.length
        if (n === 0) return
        const anchor = fluidIndex >= 0 ? fluidIndex : 0
        const sel = AppState.librarySelectedIndices[tabKey] || []
        let cursor = anchor
        if (sel.length > 0) {
            let lo = sel[0], hi = sel[0]
            for (let i = 1; i < sel.length; ++i) {
                if (sel[i] < lo) lo = sel[i]
                if (sel[i] > hi) hi = sel[i]
            }
            cursor = (anchor === lo) ? hi : lo
        }
        const next = Math.max(0, Math.min(n - 1, cursor + dir))
        const from = Math.min(anchor, next)
        const to   = Math.max(anchor, next)
        const range = []
        for (let i = from; i <= to; ++i) range.push(i)
        _rangeFromInput = false
        AppState.setLibraryFluid(tabKey, anchor)
        AppState.setLibrarySelected(tabKey, range)
        AppState.setActiveFocus("library")
        list.positionViewAtIndex(next, ListView.Contain)
        pushPreviewFor(anchor)
    }

    // ── Keyboard navigation routed from TabSearchBar ────────────────────
    Connections {
        target: AppState
        function onLibraryNavigateDown(extend) {
            if (AppState.tabKeys[AppState.activeTab] !== root.tabKey) return
            if (root.currentVerses.length === 0) return
            if (extend) { root._extendSelectionByKey(1); return }
            // Plain arrow nav clears the multi-selection — operator is
            // moving the anchor, not extending the set. Shift+arrow takes
            // the branch above instead.
            AppState.clearLibrarySelected(root.tabKey)
            const next = Math.min((root.fluidIndex < 0 ? -1 : root.fluidIndex) + 1,
                                  root.currentVerses.length - 1)
            AppState.setLibraryFluid(root.tabKey, next)
            root.pushPreviewFor(next)
            root._syncInputToVerse(next)
        }
        function onLibraryNavigateUp(extend) {
            if (AppState.tabKeys[AppState.activeTab] !== root.tabKey) return
            if (root.currentVerses.length === 0) return
            if (extend) { root._extendSelectionByKey(-1); return }
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
