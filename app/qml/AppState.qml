pragma Singleton

import QtQuick

// AppState — single source of truth for transient UI state.
//
// Per ARCHITECTURE.md §9, anything that holds selected-row, hover, focus,
// or modal-open state lives in QML, not C++. This file is the QML side
// of that contract: no persistence, no DB, no IPC.
//
// All library data and the working schedule moved out to services:
//   - Songs           → SongService.allSongs
//   - Bible           → BibleService.translations() / books() / chapter() / search()
//   - Themes          → ThemeService.allThemes / defaultFor(kind)
//   - Schedule items  → ScheduleService.currentItems (+ savedSchedules, addItem, etc.)
//   - Projection      → ProjectionService (goLive, clear, page nav, theme)
// This file keeps only flow-control state (active tab, modal open, selection
// indices, search text) — things that vanish on quit and don't belong in a DB.
QtObject {
    id: state

    // ─── Tab navigation ─────────────────────────────────────────────────
    readonly property int tabCount: 5
    readonly property var tabKeys: ["songs", "scripture", "strongs", "media", "themes"]

    property int activeTab: 0
    property var viewedTabs: [0]   // tabs that have been visited (keeps Loaders alive)

    function setActiveTab(i) {
        if (i < 0 || i >= tabCount) return
        if (activeTab === i) return
        if (viewedTabs.indexOf(i) === -1) {
            viewedTabs = viewedTabs.concat([i])
        }
        activeTab = i
    }

    function cycleTab(dir) {
        const next = (activeTab + dir + tabCount) % tabCount
        setActiveTab(next)
    }

    // ─── Schedule selection & live state ────────────────────────────────
    // Selection indices live here (UI state); the schedule items themselves
    // live in ScheduleService.currentItems. Indices remain valid as long as
    // they're bounds-checked against currentItems.length.
    property int  selectedScheduleIndex: -1   // what's in Preview pane (-1 = nothing)
    property int  liveScheduleIndex:     -1   // what's on Live pane (-1 = nothing)
    property int  previewSubIndex:        0   // page within selected item shown in Preview
    property int  liveSubIndex:           0   // page within live item shown in Live
    property bool showLogo:           false   // Logo button toggled on/off
    property bool isClear:            false   // display cleared (overrides live content)

    // Projection window visibility. Toggled true only by goLive() (the
    // explicit "Go Live" button / Ctrl+L); reset by clearLive(). No other
    // click path — library double-click, schedule selection, logo toggle —
    // raises the projector. The operator decides when the audience sees it.
    property bool projectorVisible:   false

    // ─── Library-pane overrides (NEW) ───────────────────────────────────
    // The Electron app lets the operator click a song in the library and see
    // it immediately in Preview — without first adding it to the schedule.
    // Double-click then promotes it to Live. We replicate that behavior with
    // two override slots that PreviewPanel/LivePanel consult before falling
    // back to schedule-driven state.
    //
    //   libraryPreviewItem ─── canonical schedule-item shape ({kind, title,
    //                          subtitle, pages, songId/scriptureRef/mediaPath, …})
    //                          shown in Preview pane when non-null. Cleared
    //                          when the operator clicks a schedule row.
    //   libraryLiveActive  ─── true when ProjectionService.currentItem was
    //                          pushed straight from a library tab (not via
    //                          the schedule). LivePanel reads from
    //                          ProjectionService.currentItem in that case.
    property var  libraryPreviewItem: null
    property bool libraryLiveActive:  false

    function pushLibraryPreview(item) {
        libraryPreviewItem = item || null
        previewSubIndex = 0
    }

    function clearLibraryPreview() {
        libraryPreviewItem = null
    }

    function pushLibraryLive(item) {
        if (!item) return
        libraryPreviewItem = item     // mirror to preview so the panes agree
        libraryLiveActive  = true
        isClear            = false
        liveScheduleIndex  = -1       // signal: live did not come from schedule
        liveSubIndex       = 0
        previewSubIndex    = 0
        const theme = ThemeService.defaultFor(item.kind || "song")
        ProjectionService.goLive(item, 0, theme)
    }

    function selectScheduleItem(i) {
        // Clicking a schedule row implies the operator is now driving from the
        // schedule, not the library — drop any library-preview override so the
        // two panes don't fight.
        libraryPreviewItem = null

        const n = ScheduleService.currentItems.length
        if (i < 0 || i >= n) {
            selectedScheduleIndex = -1
            previewSubIndex = 0
            return
        }
        selectedScheduleIndex = i
        previewSubIndex = 0
    }

    function goLive() {
        // Promote the previewed item to live, and push it through to
        // ProjectionService so ProjectionWindow.qml re-renders on the second
        // monitor. Items in currentItems are already in canonical shape —
        // no translation needed, just resolve the default theme for the kind.
        //
        // Source preference matches the Preview pane: library override first,
        // then the schedule selection. This means the global "Go Live" button
        // and Ctrl+L work whether the operator is staging from the library or
        // the schedule.
        //
        // This function is the SINGLE entry point that raises the projector
        // (via projectorVisible = true at the bottom). Other live-state
        // mutators — pushLibraryLive on its own, toggleLogo, schedule clicks —
        // do not touch projectorVisible.
        if (libraryPreviewItem !== null) {
            pushLibraryLive(libraryPreviewItem)
            projectorVisible = true
            return
        }

        if (selectedScheduleIndex < 0) return
        const item = ScheduleService.currentItems[selectedScheduleIndex]
        if (!item) return

        liveScheduleIndex  = selectedScheduleIndex
        liveSubIndex       = previewSubIndex
        isClear            = false
        libraryLiveActive  = false   // schedule is driving live now

        const theme = ThemeService.defaultFor(item.kind || "song")
        ProjectionService.goLive(item, previewSubIndex, theme)
        projectorVisible = true
    }

    function clearLive() {
        // "Clear live" means: blank the projector content (hide all text /
        // images), but DO NOT close the projection window. If the projector
        // is currently raised it stays raised showing nothing; if it's
        // hidden it stays hidden. Only goLive() raises and only an explicit
        // "close projection" action would lower — Clear is purely about
        // content, not window visibility.
        //
        // ProjectionService.clear() is the C++ hook that hides the live
        // text/image. Stub for now — wire up actual rendering blanking when
        // ProjectionWindow.qml gets its render pipeline.
        isClear            = true
        liveScheduleIndex  = -1
        liveSubIndex       = 0
        libraryLiveActive  = false
        ProjectionService.clear()
    }

    function toggleLogo() {
        showLogo = !showLogo
        ProjectionService.setLogoVisible(showLogo)
    }

    // ─── Modal stack ────────────────────────────────────────────────────
    property string activeModal: ""        // "" | "settings" | "songEditor" | "naming" | "confirm" | "import" | "scheduleDropdown" | "contextMenu"
    property var    modalProps: ({})       // dict of props passed to the modal (title, body, callbacks, etc.)
    property string settingsSection: "appearance"  // current section in SettingsDialog

    function openModal(name, props) {
        modalProps = props || {}
        activeModal = name
    }

    function closeModal() {
        activeModal = ""
        modalProps = {}
    }

    // ─── Workspaces ─────────────────────────────────────────────────────
    // Workspaces are full-window UI surfaces that hide the normal operator
    // console behind them — bigger than a modal, suitable for canvas-based
    // editors (theme editor today; future song editor / video composer).
    // workspaceMode = "" means the operator console is shown.
    property string workspaceMode: ""           // "" | "themeEditor"
    property int    editorThemeId: -1           // -1 = new theme
    property string editorThemeKind: "song"     // used when creating a new theme

    function openThemeEditor(themeId, themeKind) {
        editorThemeId   = themeId !== undefined ? themeId : -1
        editorThemeKind = themeKind || "song"
        workspaceMode   = "themeEditor"
    }

    function closeThemeEditor() {
        workspaceMode   = ""
        editorThemeId   = -1
        editorThemeKind = "song"
    }

    // ─── Color picker history ───────────────────────────────────────────
    // Recent swatches shown in the custom ColorPicker. Transient; clears
    // on quit. Cap at 8 to keep the swatches row tidy.
    property var recentColors: []

    function pushRecentColor(c) {
        if (!c) return
        const next = [c]
        for (let i = 0; i < recentColors.length && next.length < 8; ++i) {
            if (recentColors[i] !== c) next.push(recentColors[i])
        }
        recentColors = next
    }

    // ─── Per-tab search & group selection ───────────────────────────────
    // Stored as JS objects keyed by tabKey. Switching tabs and back
    // preserves where you were.
    property var searchText: ({
        "songs": "", "scripture": "", "strongs": "", "media": "", "themes": ""
    })

    property var activeLibraryGroup: ({
        "songs":     "all-songs",
        "scripture": "kjv",
        "strongs":   "greek",
        "media":     "all-media",
        "themes":    "all-themes"
    })

    // Per-tab fluid-focus index — the row the operator is currently navigating
    // inside the library list (independent of selection). Arrow keys move it
    // without leaving the search input. -1 means no row is focused.
    property var libraryFluidIndex: ({
        "songs":     -1,
        "scripture": -1,
        "strongs":   -1,
        "media":     -1,
        "themes":    -1
    })

    // Search-mode keyed per tab. Songs supports title/lyrics/author/recent/
    // oldest/newest. Scripture supports reference/search. Media supports
    // title/search (in-row filter today).
    property var librarySearchMode: ({
        "songs":     "lyrics",
        "scripture": "reference",
        "media":     "title"
    })

    function setSearch(tabKey, text) {
        // Mutating a property var means reassigning the whole object so QML
        // emits the change signal. (Direct key mutation doesn't fire bindings.)
        let copy = Object.assign({}, searchText)
        copy[tabKey] = text
        searchText = copy
    }

    function setLibraryGroup(tabKey, group) {
        let copy = Object.assign({}, activeLibraryGroup)
        copy[tabKey] = group
        activeLibraryGroup = copy
    }

    function setLibraryFluid(tabKey, idx) {
        let copy = Object.assign({}, libraryFluidIndex)
        copy[tabKey] = idx
        libraryFluidIndex = copy
    }

    function setLibrarySearchMode(tabKey, mode) {
        let copy = Object.assign({}, librarySearchMode)
        copy[tabKey] = mode
        librarySearchMode = copy
    }

    // ─── Scripture reference-input sub-mode ─────────────────────────────
    // Two ways to enter "Genesis 1:1" in scripture/reference mode:
    //   "crater"     ─ free text + autocomplete on space + "Interpreted: …"
    //                  hint below the input. Closer to a search box.
    //   "controlled" ─ segmented stage editor: book → chapter → verse, each
    //                  segment auto-selected so the next keystroke replaces
    //                  it. Tab/Space advances; Backspace at stage start
    //                  retreats; click a segment to select it.
    //
    // Default "crater" because the gentle learning curve fits a first-launch
    // operator. Power users can flip via the scripture gear menu. When a
    // SettingsService lands this should persist across sessions; it's
    // transient per-session for now.
    property string scriptureInputMode: "crater"   // "crater" | "controlled"

    function setScriptureInputMode(mode) {
        if (mode !== "crater" && mode !== "controlled") return
        scriptureInputMode = mode
    }

    // ─── Media tab view state (transient UI choices only) ───────────────
    // The media library itself lives in crater::MediaService (see
    // ARCHITECTURE.md §1/§4/§9: file-backed data belongs in crater-core,
    // not QML). The projection's logo-background path lives in
    // ProjectionService (it's persisted user data). What stays here is
    // genuinely transient UI state — current view mode, grid density,
    // sort preferences, batch selection — exactly the kind §9 calls out
    // for QML/AppState ownership. These reset to defaults on app launch.
    //
    // When SettingsService lands these will move to it for persistence,
    // but they don't belong in MediaService either — a service should not
    // know whether the operator prefers grid view vs list view.
    property string mediaViewMode:   "grid"     // "grid" | "list"
    property int    mediaGridColumns: 6         // 4 / 6 / 8 / 10 / 12
    property string mediaSortField:  "name"     // "name" | "date" | "size" | "type"
    property string mediaSortOrder:  "asc"      // "asc" | "desc"
    property string mediaTypeFilter: "all"      // "all" | "image" | "video"

    // Batch selection — list of fluid-list indices currently checked. Plain
    // list rather than Set because QML's property var likes JSON-friendly
    // structures. Cleared whenever the operator switches tabs.
    property var mediaBatchSelection: []

    function clearMediaBatchSelection() { mediaBatchSelection = [] }

    // Sidebar group + media type filter move together: clicking "Images" in
    // the sidebar should both highlight the row (activeLibraryGroup) AND
    // narrow the grid to images (mediaTypeFilter). Wrapping both writes in
    // one function keeps the two slots from drifting out of sync.
    //
    // The "favorites" group does NOT touch mediaTypeFilter — favorites can
    // be a mix of images and videos, and the favorites filter is applied
    // separately inside MediaTab.filteredMedia.
    function setMediaGroup(groupId) {
        setLibraryGroup("media", groupId)
        mediaTypeFilter =
            groupId === "images" ? "image" :
            groupId === "videos" ? "video" :
                                   "all"
    }

    // ─── Library keyboard events ────────────────────────────────────────
    // The per-tab search input (TabSearchBar) lives in the sidebar but
    // keyboard navigation (arrow keys / Enter) should drive the active tab's
    // library list. We bridge the two via signals on this singleton: the
    // search input emits them; the active tab listens and reacts.
    //
    // Each tab guards its handler with `tabKeys[activeTab] === tabKey` so
    // background-loaded tabs ignore navigation meant for the foreground one.
    signal libraryNavigateUp()
    signal libraryNavigateDown()
    signal libraryNavigateLeft()
    signal libraryNavigateRight()
    signal libraryActivate()
    // Ctrl+T → "stage this": add the active library tab's currently fluid-
    // focused item to the schedule. Per-tab handlers (ScriptureTab, SongsTab,
    // MediaTab) gate themselves with `tabKeys[activeTab] === tabKey`. Tabs
    // without schedule semantics (Strongs, Themes) simply ignore the signal.
    signal libraryAddToSchedule()

    // ─── Active focus panel ─────────────────────────────────────────────
    // Names which UI surface currently "owns" keyboard navigation. The
    // window-level Up/Down/Delete shortcuts in Main.qml read this to decide
    // whether to route to the schedule list or the library list — so an
    // operator browsing scripture verses isn't moving the schedule selection
    // every time they press an arrow.
    //
    // Default "library" because TabSearchBar auto-focuses its input on tab
    // change (Component.onCompleted + onActiveTabChanged). Panel-level focus
    // handlers update it: search-input focus → "library", schedule row click
    // → "schedule". Future panels (preview, live) will claim it the same way.
    //
    // Analogous to electron's FocusContext.currentPanel().
    property string activeFocusPanel: "library"   // "library" | "schedule" | future: "preview" | "live"

    function setActiveFocus(panel) {
        if (!panel || panel === activeFocusPanel) return
        activeFocusPanel = panel
    }

    // ─── Cross-panel sync signals ───────────────────────────────────────
    // Schedule → Scripture: clicking a scripture row in the working schedule
    // should auto-scroll the scripture picker to that verse, switching
    // translation if needed. Emitted by SchedulePanel; consumed by ScriptureTab.
    // verse is `var` because the underlying field can be a number ("3") or a
    // string ("1-2", "2a") — see ScriptureTab.verseMatches().
    signal syncScriptureFromSchedule(string book, int chapter, var verse, string translation)

    // Translation dblclick → push live: double-clicking a translation row in
    // the sidebar should push the currently focused verse Live in the new
    // translation. LibrarySidebar emits, ScriptureTab handles (only it knows
    // which verse the operator is focused on).
    signal requestPushLiveInTranslation(string translationCode)

    // Convenience for the "Add to Schedule" right-click action — adds the
    // item AND selects it so the operator gets immediate visual feedback.
    function addItemToSchedule(item) {
        if (!item) return
        ScheduleService.addItem(item)
        // newly-added items append to the end
        selectedScheduleIndex = ScheduleService.currentItems.length - 1
        previewSubIndex = 0
        libraryPreviewItem = null   // schedule now wins the Preview pane
    }
}
