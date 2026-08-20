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
    // tabKeys is reactive on SettingsService.showStrongsTab — flipping
    // the operator's "Show Strong's tab" setting drops/adds the strongs
    // slot. activeTab fix-up lives in Main.qml's Connections (QtObject
    // can't host child objects, so the bookkeeping moves up to the
    // ApplicationWindow which can).
    readonly property var tabKeys: SettingsService.showStrongsTab
        ? ["songs", "scripture", "strongs", "media", "themes"]
        : ["songs", "scripture", "media", "themes"]
    readonly property int tabCount: tabKeys.length

    property int activeTab: 0
    // Keys of tabs visited this session — LibraryContent keeps a tab's Loader
    // alive once its key appears here. Stored as keys, NOT indices: a tab's
    // index shifts when the Strong's tab is shown/hidden, so an index is not
    // stable identity across that toggle — a key is.
    property var viewedTabs: ["songs"]

    // Internal helper called by Main.qml's Connections when Strong's
    // visibility flips. Strong's lives canonically at index 2 — hiding
    // pushes tabs >= 2 down (or drops to Songs if Strong's was active);
    // re-showing pushes tabs >= 2 back up by one. Implemented as a
    // function rather than a signal handler because QtObject (the root
    // of a QML singleton) refuses non-property children.
    function _onStrongsTabVisibilityChanged() {
        if (SettingsService.showStrongsTab) {
            if (activeTab >= 2) activeTab = activeTab + 1
        } else {
            if (activeTab === 2)      activeTab = 0
            else if (activeTab > 2)   activeTab = activeTab - 1
        }
    }

    function setActiveTab(i) {
        if (i < 0 || i >= tabCount) return
        if (activeTab === i) return
        const key = tabKeys[i]
        if (viewedTabs.indexOf(key) === -1) {
            viewedTabs = viewedTabs.concat([key])
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
    //
    // Two-level model: `selectedScheduleIndex` is the primary / anchor (drives
    // Preview pane + Shift+click range pivot). `selectedScheduleIndices` is
    // the full multi-set (drives Delete batch + per-row "selected" badging).
    // Helpers below keep the two in sync: a single-select click resets the
    // array to one element; Ctrl+click toggles; Shift+click extends the range.
    property int  selectedScheduleIndex: -1   // anchor (drives Preview pane)
    property var  selectedScheduleIndices: [] // multi-selection set; always includes the anchor
    property int  liveScheduleIndex:     -1   // what's on Live pane (-1 = nothing)
    property int  previewSubIndex:        0   // page within selected item shown in Preview
    property int  liveSubIndex:           0   // page within live item shown in Live

    // Operator's staged crop for the previewed image / PDF, in normalized
    // 0..1 coordinates. PreviewPanel mirrors the CroppableMediaPreview's
    // rectangle into this so EVERY go-live entry point — Enter, the TopBar
    // Go Live button, schedule double-click, Ctrl+L — can apply the same
    // crop. Defaults to full-frame; text kinds ignore it entirely.
    property rect previewCropRect: Qt.rect(0, 0, 1, 1)
    property bool showLogo:           false   // Logo button toggled on/off
    property bool isClear:            false   // display cleared (overrides live content)

    // NDI blank is now the C++ NdiService.blank property — intercepts at
    // the frame-send boundary so the toggle works regardless of which
    // capture pipeline is active (legacy grabToImage / headless QRhi) and
    // regardless of single vs dual output mode. The earlier QML-side
    // ndiOpacity property only reached one of those paths; consolidated
    // here as a comment marker so future hackers don't reintroduce it.

    // Projection window visibility — independent of what's on the live channel.
    // Raised by openProjector() (the TopBar "Go Live" button, whose only job is
    // to show the audience window) and by the schedule context-menu's "Send to
    // Live" (goLive(true) — commit that row AND raise). Lowered by endLive()
    // (the windowed projector's close button, its Esc shortcut, or the button's
    // "End Live" face). clearLive() blanks content but does NOT lower the
    // projector. Content-commit gestures (Enter, preview/schedule double-click,
    // library push) deliberately do NOT raise — they call goLive(false) /
    // pushLibraryLive — so staging during rehearsal never pops the audience
    // screen.
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

    function pushLibraryPreview(item, page) {
        libraryPreviewItem = item || null
        // `page` is optional (defaults to 0). The global-search palette passes
        // the matched / operator-selected lyric section so Preview opens jumped
        // to that slide with its card highlighted, not always the first.
        previewSubIndex = (page === undefined || page < 0) ? 0 : page
    }

    function clearLibraryPreview() {
        libraryPreviewItem = null
    }

    // Canonical song → schedule-item builder. Lives here rather than in a tab
    // because three surfaces need the identical shape: SongsTab (library rows),
    // GlobalSearchOverlay (palette hits), and refreshStagedSong() below. Those
    // first two each carried their own verbatim copy, so a change to subtitle
    // composition or page mapping had to be made twice or it silently drifted.
    //
    // Subtitle composition is gated by the operator's Song > Show author /
    // Show CCLI number toggles. Each part is independently suppressible, joined
    // by " · " for any surviving pairs. Empty when both toggles are off —
    // ProjectionWindow renders an empty subtitle cleanly.
    function buildSongItem(song) {
        if (!song || !song.id) return null
        let pages = []
        for (let i = 0; i < song.sections.length; i++) {
            const sec = song.sections[i]
            pages.push({
                label:   sec.label || "",
                content: (sec.lines && sec.lines.length > 0) ? sec.lines.join("\n") : ""
            })
        }
        if (pages.length === 0)
            pages = [{ label: "", content: song.title + (song.author ? "\n" + song.author : "") }]
        let subtitleParts = []
        if (SettingsService.showSongAuthor && song.author) subtitleParts.push(song.author)
        if (SettingsService.showSongCcli && song.ccli)     subtitleParts.push("CCLI " + song.ccli)
        return {
            kind:     "song",
            title:    song.title,
            subtitle: subtitleParts.join(" · "),
            pages:    pages,
            songId:   song.id,
            // Carried through to resolveItemTheme() so Go Live honors the
            // per-song theme override (set via the editor). 0 means "use the
            // user's default for kind=song" — the fallback case.
            themeId:  song.themeId || 0
        }
    }

    // Re-read the staged preview item from the DB after its song was edited.
    //
    // libraryPreviewItem is a plain JS snapshot taken when the operator picked
    // the song, so a later SongService.update() left it stale: double-clicking
    // a lyric card pushed PRE-EDIT content Live, and the only way out was to
    // select a different song and come back (which re-ran fetchSong). The C++
    // side already invalidates its cache and emits allSongsChanged() — nothing
    // on the QML side was listening. Main.qml wires that signal to this.
    //
    // Live is deliberately NOT re-pushed here. ProjectionService snapshots on
    // goLive so an in-progress edit can't reach the audience screen mid-service
    // (see ProjectionService.h). The operator's next Go Live picks up the
    // refreshed item, which is the gesture they were already making.
    function refreshStagedSong() {
        _refreshStagedPreviewSong()
        _refreshScheduleSongs()
    }

    function _refreshStagedPreviewSong() {
        const staged = libraryPreviewItem
        if (!staged || staged.kind !== "song" || !staged.songId) return

        const fresh = SongService.fetchSong(staged.songId)
        if (!fresh || !fresh.id) {
            // Song was deleted out from under the preview — drop the override
            // rather than leave a pane bound to a row that no longer exists.
            clearLibraryPreview()
            return
        }

        const rebuilt = buildSongItem(fresh)
        if (!rebuilt) return
        libraryPreviewItem = rebuilt
        // Hold the operator on the same slide across the edit. Clamp when the
        // edit removed sections so the index never points past the end.
        if (previewSubIndex >= rebuilt.pages.length)
            previewSubIndex = Math.max(0, rebuilt.pages.length - 1)
    }

    // Same staleness, one layer down. Schedule rows store a song's lyrics
    // INLINE (see ScheduleService), so a song edit left every schedule row
    // quoting the pre-edit text — and Preview / Live both read schedule rows
    // when the operator is driving from the schedule rather than the library.
    // Rebuild each affected row in place; ScheduleService.replaceItem no-ops
    // when the rebuilt row is byte-identical, so an unrelated song edit does
    // not dirty the schedule.
    function _refreshScheduleSongs() {
        const items = ScheduleService.currentItems
        for (let i = 0; i < items.length; i++) {
            const merged = _songContentMerged(items[i])
            if (merged) ScheduleService.replaceItem(i, merged)
        }
        // Clamp the staged page when the edit shortened the selected row.
        const sel = (selectedScheduleIndex >= 0
                     && selectedScheduleIndex < ScheduleService.currentItems.length)
                        ? ScheduleService.currentItems[selectedScheduleIndex] : null
        if (sel && sel.pages && previewSubIndex >= sel.pages.length)
            previewSubIndex = Math.max(0, sel.pages.length - 1)
    }

    // Re-read `row`'s song from the library and fold the fresh lyrics back
    // into a COPY of the row. Returns null when there is nothing to do — the
    // row is not a song, the song is gone, or its content is unchanged.
    //
    // Merging rather than substituting matters: a schedule row carries fields
    // buildSongItem knows nothing about — ScheduleService stamps every row
    // with a uuid `id`, and the row may hold a per-item `themeId` override the
    // song itself does not have. Replacing the row wholesale would drop both.
    // A deleted song leaves its row alone: pulling rows out from under the
    // operator mid-service is worse than a stale one, and the row is still
    // removable by hand.
    function _songContentMerged(row) {
        if (!row || row.kind !== "song" || !row.songId) return null
        const fresh = SongService.fetchSong(row.songId)
        if (!fresh || !fresh.id) return null
        const rebuilt = buildSongItem(fresh)
        if (!rebuilt) return null

        let merged = {}
        for (const k in row) merged[k] = row[k]
        merged.title    = rebuilt.title
        merged.subtitle = rebuilt.subtitle
        merged.pages    = rebuilt.pages
        // The row's own theme pin wins; adopt the song's only when the row
        // never had one.
        if (!merged.themeId) merged.themeId = rebuilt.themeId

        if (_itemContentDigest(merged) === _itemContentDigest(row)) return null
        return merged
    }

    // Stable content digest for a canonical item. Order-independent of the
    // map's key order, which matters because an item that has been through
    // C++ comes back as an alphabetically-keyed QVariantMap while a freshly
    // built one carries its literal key order — JSON.stringify would call
    // those two different even when they hold identical content.
    function _itemContentDigest(item) {
        if (!item) return ""
        const pages = item.pages || []
        let flat = []
        for (let i = 0; i < pages.length; i++) {
            const p = pages[i] || {}
            flat.push([p.label || "", p.content || ""])
        }
        // JSON over an ARRAY, not the map: array order is ours, so the digest
        // is stable no matter which side built the item.
        return JSON.stringify([item.title || "", item.subtitle || "",
                               item.themeId || 0, flat])
    }

    // Live-pane commit — "the audience sees this page now".
    //
    // A bare ProjectionService.setPage() re-uses whatever was snapshotted at
    // the last go-live. That snapshot is deliberate (ProjectionService.h: an
    // in-progress edit must not leak to the audience), but it stranded the
    // operator after a song edit: Preview showed the new lyrics, the projector
    // kept the old ones, and clicking the same verse changed nothing because
    // the page index had not moved. The only way out was to step to another
    // verse and back.
    //
    // Clicking or arrowing onto a live card IS an explicit commit, so re-read
    // the song first and re-stage when its content actually changed. Anything
    // else — media, scripture, an unedited song — falls through to the cheap
    // setPage() path, so live behaviour is otherwise untouched.
    function commitLivePage(i) {
        liveSubIndex = i
        const restaged = _songContentMerged(ProjectionService.currentItem)
        if (restaged) _projectItemLive(restaged, i)
        else          ProjectionService.setPage(i)
    }

    // Route a go-live through the crop-aware overload for media items so a
    // crop survives EVERY entry point — Enter, the TopBar Go Live button,
    // schedule double-click, Ctrl+L. Two crop sources by kind:
    //   • PDF   — the transient Preview cropper (previewCropRect), framed
    //             ad-hoc per go-live.
    //   • image/video — the item's SAVED crop (item.cropRect, set in the media
    //             edit modal and persisted per item). There is no transient
    //             image/video cropper, so the saved rect is authoritative;
    //             reading previewCropRect here would leak a stale PDF crop.
    // Text kinds use the plain overload, which resets the crop to full-frame
    // (correct — they have no crop concept, and the reset stops a stale media
    // crop from leaking onto a text render).
    function _projectItemLive(item, page) {
        if (!item) { ProjectionService.goLive(item, page); return }
        if (item.kind === "pdf") {
            ProjectionService.goLiveWithCrop(item, page, previewCropRect)
        } else if (item.kind === "image" || item.kind === "video") {
            ProjectionService.goLiveWithCrop(item, page,
                                             item.cropRect || Qt.rect(0, 0, 1, 1))
        } else {
            ProjectionService.goLive(item, page)
        }
    }

    function pushLibraryLive(item, page) {
        if (!item) return
        // `page` is optional and defaults to 0 for the original "library
        // row double-click to push straight to live" callers (MediaTab /
        // SongsTab / ScriptureTab). The preview-card double-click passes
        // the operator's selected page so live picks up the same card the
        // operator was looking at — not always page 0.
        if (page === undefined) page = 0
        // isClear is deliberately left untouched. Clear is a sticky overlay —
        // ProjectionService.goLiveWithCrop preserves it — so staging new content
        // while blanked keeps the screen blanked until an explicit unclear
        // (clearLive / Ctrl+C). The operator's clear survives go-live.
        libraryPreviewItem = item     // mirror to preview so the panes agree
        libraryLiveActive  = true
        liveScheduleIndex  = -1       // signal: live did not come from schedule
        liveSubIndex       = page
        previewSubIndex    = page
        // Theme is resolved reactively by ProjectionWindow.qml — it reads
        // the item's themeId override and ThemeService.defaultFor(kind),
        // so default changes update the live render without re-Go-Live.
        _projectItemLive(item, page)
    }

    function selectScheduleItem(i) {
        // Clicking a schedule row implies the operator is now driving from the
        // schedule, not the library — drop any library-preview override so the
        // two panes don't fight.
        libraryPreviewItem = null

        const n = ScheduleService.currentItems.length
        if (i < 0 || i >= n) {
            selectedScheduleIndex = -1
            selectedScheduleIndices = []
            previewSubIndex = 0
            return
        }
        selectedScheduleIndex = i
        selectedScheduleIndices = [i]
        previewSubIndex = 0
    }

    // Ctrl+click — toggle membership in the multi-set. Anchor follows the
    // last toggled-on row so subsequent Shift+click pivots feel natural; if
    // we toggled the anchor itself off, fall back to the last remaining
    // element or -1.
    function toggleScheduleSelection(i) {
        if (i < 0) return
        libraryPreviewItem = null
        const n = ScheduleService.currentItems.length
        if (i >= n) return
        let s = selectedScheduleIndices.slice()
        const at = s.indexOf(i)
        if (at >= 0) {
            s.splice(at, 1)
            selectedScheduleIndex = (s.length > 0) ? s[s.length - 1] : -1
        } else {
            s.push(i)
            selectedScheduleIndex = i
        }
        selectedScheduleIndices = s
        previewSubIndex = 0
    }

    // Shift+click — replace the multi-set with the contiguous range from
    // the current anchor to i. If there's no anchor, pivot from row 0.
    function extendScheduleSelectionTo(i) {
        if (i < 0) return
        libraryPreviewItem = null
        const n = ScheduleService.currentItems.length
        if (i >= n) return
        const anchor = selectedScheduleIndex >= 0 ? selectedScheduleIndex : 0
        const lo = Math.min(anchor, i)
        const hi = Math.max(anchor, i)
        let s = []
        for (let k = lo; k <= hi; k++) s.push(k)
        selectedScheduleIndices = s
        selectedScheduleIndex = i
        previewSubIndex = 0
    }

    function clearScheduleSelection() {
        selectedScheduleIndex = -1
        selectedScheduleIndices = []
    }

    // Resolve the effective theme for a schedule item — three-tier priority:
    //   1. Per-item override stored on the item itself
    //   2. Per-output, PER-KIND theme pinned on the OutputBinding registered
    //      with OutputService. The outputId argument identifies which
    //      registry row to consult — "primary" by default. item.kind picks
    //      one of {song, scripture, presentation} within that output's
    //      themes slot.
    //
    //      outputMode collapses NDI / Stage onto Primary in "single" mode —
    //      in that mode NDI mirrors the projection scene, so it should
    //      resolve against the same per-kind slots Primary uses. In "dual"
    //      mode each output stands alone.
    //   3. Per-kind default from ThemeService.defaultFor(kind)
    //
    // The sentinel-check on t.id at each tier handles the case where the
    // referenced theme was deleted; we fall through to the next tier rather
    // than render a bogus theme.
    //
    // outputId defaults to "primary" so existing callers (ThemedMonitor,
    // and any future consumer that doesn't know about per-output themes)
    // get the same behavior they had before this signature change.
    function resolveItemTheme(item, outputId) {
        if (outputId === undefined) outputId = "primary"

        const overrideId = (item && typeof item.themeId === "number") ? item.themeId : 0
        if (overrideId > 0) {
            const t = ThemeService.theme(overrideId)
            if (t.id > 0) return t
        }

        const kind = (item && item.kind) || "song"

        // Single-mode collapse: NDI / Stage have no independent scene, so
        // they read from Primary's per-kind slots. Dual-mode lets each
        // output stand alone.
        let effectiveId = outputId
        if (SettingsService.outputMode !== "dual"
            && (outputId === "ndi" || outputId === "stage")) {
            effectiveId = "primary"
        }

        const pinned = OutputService.themeIdFor(effectiveId, kind)
        if (pinned > 0) {
            const t = ThemeService.theme(pinned)
            if (t.id > 0) return t
        }

        return ThemeService.defaultFor(kind)
    }

    function goLive(raise) {
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
        // `raise` controls whether the projection window is ALSO brought up.
        // Only the schedule context-menu's "Send to Live" passes true (commit
        // that row AND show it). Every other caller passes false — Enter, the
        // preview-card double-click, and the schedule double-click all stage to
        // the live channel without popping the audience window. The TopBar "Go
        // Live" button no longer routes here at all; it calls openProjector(),
        // which raises the window without committing anything.
        if (raise === undefined) raise = true

        if (libraryPreviewItem !== null) {
            // Pass the operator's currently-selected preview page so a
            // mid-list double-click sends *that* page to live, not page 0.
            pushLibraryLive(libraryPreviewItem, previewSubIndex)
            if (raise) projectorVisible = true
            return
        }

        if (selectedScheduleIndex < 0) return
        const item = ScheduleService.currentItems[selectedScheduleIndex]
        if (!item) return

        liveScheduleIndex  = selectedScheduleIndex
        liveSubIndex       = previewSubIndex
        libraryLiveActive  = false   // schedule is driving live now
        // isClear left untouched — clear is sticky across go-live (see pushLibraryLive).

        // Theme resolution moved into ProjectionWindow — see pushLibraryLive.
        // Crop-aware: a PDF/image staged with a crop keeps it when the
        // operator hits the Go Live button rather than Enter.
        _projectItemLive(item, previewSubIndex)
        if (raise) projectorVisible = true
    }

    function clearLive() {
        // Toggle "cleared" — hides text on the projector when set,
        // restores text when cleared again. Theme background and logo
        // (if on) stay visible across both states. The live channel itself
        // is never collapsed; we deliberately do NOT touch
        // liveScheduleIndex / liveSubIndex / libraryLiveActive.
        //
        // Clear is independent of content: go-live and page nav are
        // clear-agnostic (ProjectionService.goLiveWithCrop / setPage preserve
        // m_isClear), so this toggle is the only way in or out. unclear() flips
        // m_isClear=false and the text fades back in over the existing
        // background via NodeRenderer's clear-fade — no re-stage, so the live
        // crop / page / item are left intact.
        //
        // Projector window visibility is independent. Only goLive() with
        // raise=true raises; only endLive() lowers.
        if (isClear) {
            ProjectionService.unclear()
            isClear = false
        } else {
            ProjectionService.clear()
            isClear = true
        }
    }

    function openProjector() {
        // Raise the audience projection window WITHOUT touching the live
        // channel. This is the TopBar "Go Live" button's sole job: make the
        // audience screen visible, showing whatever was last committed to live
        // — or the logo / blank theme background if nothing has been pushed
        // yet. Content reaches the live channel through SEPARATE gestures
        // (Enter or a preview-card / schedule double-click → goLive(false); a
        // library row → pushLibraryLive), so "show the screen" and "send the
        // content" are independent actions. That mirrors how operators work:
        // bring the screen up on the pre-service logo, then trigger slides into
        // it. Idempotent — already-open stays open. endLive() is the inverse.
        projectorVisible = true
    }

    function endLive() {
        // Inverse of openProjector() / goLive(true): lower the projection
        // window. ProjectionService content state is preserved — a subsequent
        // raise picks back up where it left off without re-rendering. Distinct
        // from clearLive(), which blanks content but keeps the window raised.
        // Entry points: the windowed projector's close (X) button, the
        // projection window's Esc shortcut, and the TopBar button's "End Live"
        // face (it flips to End Live whenever the projector is open — TopBar.qml).
        projectorVisible = false
    }

    function toggleLogo() {
        showLogo = !showLogo
        ProjectionService.setLogoVisible(showLogo)
    }

    // ─── Modal stack ────────────────────────────────────────────────────
    property string activeModal: ""        // "" | "settings" | "songEditor" | "naming" | "confirm" | "import" | "scheduleDropdown" | "contextMenu"
    property var    modalProps: ({})       // dict of props passed to the modal (title, body, callbacks, etc.)
    property string settingsSection: "appearance"  // current section in SettingsDialog

    // Last theme export error, written by ExportThemeDialog when
    // ThemeService.exportTheme returns false. ThemesTab polls this on
    // modal close so the dialog itself doesn't need to know about the
    // tab's banner UI. Cleared by the tab after surfacing.
    property string lastThemeExportError: ""

    function openModal(name, props) {
        modalProps = props || {}
        activeModal = name
    }

    function closeModal() {
        activeModal = ""
        modalProps = {}
    }

    // Open a context menu anchored at a mouse position inside `originItem`.
    // Replaces the boilerplate every call site used to repeat:
    //
    //     const p = mapToItem(null, mouse.x, mouse.y)
    //     AppState.openModal("contextMenu", {
    //         anchorX: p.x, anchorY: p.y, menuWidth: 220, items: items })
    //
    // `opts` is optional and may carry: `menuWidth` (default 220),
    // `dx` / `dy` (offsets added to the mapped point — handy for menus
    // anchored relative to a button corner, e.g. dx: -220 to right-align).
    function openContextMenuAt(originItem, mouseX, mouseY, items, opts) {
        if (!originItem) return
        const o = opts || {}
        const p = originItem.mapToItem(null, mouseX, mouseY)
        openModal("contextMenu", {
            anchorX:   p.x + (o.dx || 0),
            anchorY:   p.y + (o.dy || 0),
            menuWidth: o.menuWidth || 220,
            items:     items
        })
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

    // Seed the active scripture translation from the persisted operator default
    // (SettingsService.defaultScriptureVersion). The literal "kjv" above is the
    // first-run fallback; this overrides it with the saved choice on startup —
    // but only when that translation is actually installed, so a default left
    // pointing at a since-removed version never strands the scripture tab on an
    // empty corpus. Mid-session sidebar switches stay independent: they write
    // activeLibraryGroup directly without touching the saved default. Live
    // re-application when the operator picks a new default is driven from the
    // Settings dropdown (a QtObject can't host a Connections child here).
    Component.onCompleted: {
        const want = (SettingsService.defaultScriptureVersion || "").toLowerCase()
        if (want.length === 0) return
        const trs = BibleService.translations()
        for (let i = 0; i < trs.length; ++i) {
            if (String(trs[i].code).toLowerCase() === want) {
                setLibraryGroup("scripture", want)
                return
            }
        }
    }

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

    // Per-tab multi-selection — additional row indices beyond the fluid anchor
    // that are also "selected" for batch actions (push live, add to schedule).
    // Empty array = no multi-selection; the fluid anchor alone is the implicit
    // single selection. Always sorted ascending. Read alongside libraryFluidIndex,
    // not as a replacement — tabs decide their own merge policy. Today only
    // ScriptureTab consumes it (shift+click for ranges, ctrl/cmd+click for
    // individual extras), but the slot is per-tab so other library tabs can
    // opt in later without a schema bump.
    property var librarySelectedIndices: ({
        "songs":     [],
        "scripture": [],
        "strongs":   [],
        "media":     [],
        "themes":    []
    })

    // Search-mode keyed per tab. Songs supports title/lyrics/author (filter
    // mode — drives the input placeholder + filter logic). Scripture supports
    // reference/search. Media supports title/search (in-row filter today).
    //
    // Songs' sort mode is intentionally split into librarySortMode (below).
    // Previously the gear-menu sort items hijacked librarySearchMode which
    // also changed the input placeholder — picking "Sort by Newest" from the
    // gear made the placeholder read "Filter newest songs…", which surprised
    // operators who just wanted to sort. Two slots → two intents, no collision.
    property var librarySearchMode: ({
        "songs":     "all",
        "scripture": "reference",
        "media":     "title"
    })

    // Per-mode remembered input for tabs that flip between distinct search
    // modes (today: scripture's reference ↔ search). Operators commonly want
    // to compare a filter result ("Gen 1:1") against an FTS hit ("For God")
    // and toggle back and forth; clearing on every flip throws away that
    // context. setLibrarySearchModeWithMemory stashes the current text under
    // the *previous* mode and rehydrates the input from the new mode's slot.
    //
    // Songs' mode flip (title/lyrics/author) does NOT route through here —
    // its input is shared across modes (changing mode just changes what the
    // text filters against), so there's nothing to remember separately.
    property var searchTextByMode: ({
        "scripture": { "reference": "", "search": "" }
    })

    // Sort-mode keyed per tab. "none" preserves natural ordering (title for
    // songs); other modes drive ORDER BY on the filtered list inside the tab.
    // Songs supports: "none" | "recent" (updated_at DESC) | "oldest"
    // (created_at ASC) | "newest" (created_at DESC).
    property var librarySortMode: ({
        "songs": "none"
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

    function setLibrarySelected(tabKey, indicesArray) {
        let copy = Object.assign({}, librarySelectedIndices)
        // Defensive copy + sort so callers can pass any iterable. Dedup via
        // Set: shift+click ranges can overlap a prior ctrl+click and we don't
        // want duplicate index entries to confuse downstream consumers.
        const sorted = Array.from(new Set(indicesArray || []))
                        .filter(function(i) { return Number.isInteger(i) && i >= 0 })
                        .sort(function(a, b) { return a - b })
        copy[tabKey] = sorted
        librarySelectedIndices = copy
    }

    function clearLibrarySelected(tabKey) {
        if ((librarySelectedIndices[tabKey] || []).length === 0) return
        setLibrarySelected(tabKey, [])
    }

    function setLibrarySearchMode(tabKey, mode) {
        let copy = Object.assign({}, librarySearchMode)
        copy[tabKey] = mode
        librarySearchMode = copy
    }

    // Memory-aware mode flip. Stashes the current input under the outgoing
    // mode's slot, then writes the incoming mode's remembered text BEFORE
    // flipping the mode so binding cascades observe a consistent (text, mode)
    // pair — most importantly TabSearchBar.onIsControlledModeChanged, which
    // hydrates segmented state from searchText when it fires.
    function setLibrarySearchModeWithMemory(tabKey, nextMode) {
        const prevMode = librarySearchMode[tabKey]
        if (prevMode === nextMode) return

        let byMode = Object.assign({}, searchTextByMode)
        let tabMem = Object.assign({}, byMode[tabKey] || {})
        tabMem[prevMode] = searchText[tabKey] || ""
        byMode[tabKey]   = tabMem
        searchTextByMode = byMode

        setSearch(tabKey, tabMem[nextMode] || "")
        setLibrarySearchMode(tabKey, nextMode)
    }

    function setLibrarySortMode(tabKey, mode) {
        let copy = Object.assign({}, librarySortMode)
        copy[tabKey] = mode
        librarySortMode = copy
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

    // FTS search scope: when false (default) scripture search is scoped to the
    // active translation; when true it searches across every imported
    // translation at once (each hit carries its own translation chip).
    // Session-only, flipped from the scripture gear menu.
    property bool scriptureSearchAllTranslations: false

    function setScriptureSearchAllTranslations(on) {
        scriptureSearchAllTranslations = !!on
    }

    // ── Recent searches (per tab, session-only) ─────────────────────────────
    // A short most-recent-first history of committed queries per library tab,
    // surfaced as suggestions when the search box is focused and empty. Not
    // persisted (mirrors scriptureInputMode); a SettingsService slot can back
    // it later. Capped so the suggestion row stays compact.
    property var recentSearches: ({
        "songs": [], "scripture": [], "strongs": [], "media": []
    })

    readonly property int recentSearchLimit: 8

    function recentSearchesFor(tabKey) {
        return recentSearches[tabKey] || []
    }

    function pushRecentSearch(tabKey, text) {
        var t = (text || "").trim()
        if (t.length < 3) return
        var cur = recentSearches[tabKey] || []
        // De-dupe case-insensitively, newest first.
        var next = [t]
        var tl = t.toLowerCase()
        for (var i = 0; i < cur.length && next.length < recentSearchLimit; i++) {
            if (cur[i].toLowerCase() !== tl) next.push(cur[i])
        }
        var copy = {}
        for (var k in recentSearches) copy[k] = recentSearches[k]
        copy[tabKey] = next
        recentSearches = copy
    }

    function clearRecentSearches(tabKey) {
        var copy = {}
        for (var k in recentSearches) copy[k] = recentSearches[k]
        copy[tabKey] = []
        recentSearches = copy
    }

    // Last view mode the song editor was in. Re-opened editors should
    // land in the operator's last choice rather than always defaulting to
    // structured — a raw-mode user shouldn't have to flip the toggle on
    // every song. Session-only (same pattern as scriptureInputMode); a
    // SettingsService-backed persistent slot can replace this later
    // without touching the editor wiring.
    property string songEditorViewMode: "structured"   // "structured" | "raw"

    function setSongEditorViewMode(mode) {
        if (mode !== "structured" && mode !== "raw") return
        songEditorViewMode = mode
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
    // `extend` carries the Shift modifier through to the tab. Tabs with a
    // multi-selection model (ScriptureTab today) grow the set from the
    // anchor instead of moving it, so an operator can build a combined
    // passage from the keyboard the way Shift+click already does with the
    // mouse. Tabs without one ignore the argument and keep single-row
    // navigation — a QML signal handler is free to omit trailing params.
    signal libraryNavigateUp(bool extend)
    signal libraryNavigateDown(bool extend)
    signal libraryNavigateLeft()
    signal libraryNavigateRight()
    signal libraryActivate()
    // Ctrl+T → "stage this": add the active library tab's currently fluid-
    // focused item to the schedule. Per-tab handlers (ScriptureTab, SongsTab,
    // MediaTab) gate themselves with `tabKeys[activeTab] === tabKey`. Tabs
    // without schedule semantics (Strongs, Themes) simply ignore the signal.
    signal libraryAddToSchedule()

    // ─── Preview / Live page navigation ─────────────────────────────────
    // Emitted by Main.qml's Up/Down shortcuts when activeFocusPanel is
    // "preview" or "live". The respective panel owns the clamp logic
    // because the page count is filtered locally (empty-content pages
    // are stripped out before display) and only the panel knows the
    // visible length.
    signal previewNavigateUp()
    signal previewNavigateDown()
    signal liveNavigateUp()
    signal liveNavigateDown()
    // Enter on a preview card → push to live. Same call path as the
    // existing preview-card double-click (goLive(false), no projector
    // raise). PreviewPanel owns the handler so it can read its own
    // previewSubIndex / selectedItem at activation time.
    signal previewActivate()

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
    property string activeFocusPanel: "library"   // "library" | "schedule" | "preview" | "live"

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

    // Schedule → Songs: clicking a song row in the schedule should scroll the
    // songs library to that song so the operator sees what they're editing.
    // Emitted by SchedulePanel when the clicked item.kind === "song"; consumed
    // by SongsTab. var (not qint64) so the signal handler gets the raw value
    // regardless of whether the schedule item carries it as int or string.
    signal syncSongFromSchedule(var songId)

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
        // selectScheduleItem keeps the multi-set in sync with the primary
        // index and clears any active library-preview override.
        selectScheduleItem(ScheduleService.currentItems.length - 1)
    }

    // ─── Global search (command palette, Ctrl+K) ─────────────────────────
    // A cross-library search overlay. Driven through the modal stack
    // (activeModal === "globalSearch") so Escape-to-close and the ModalLayer
    // z-order come for free. The query lives here rather than inside the
    // overlay so it survives close/re-open within a session ("remember last
    // query"); it is deliberately session-only, never persisted.
    property string globalSearchQuery: ""

    function openGlobalSearch() {
        // Don't stack the palette on top of another modal (settings, editor):
        // the Ctrl+K shortcut is already gated on activeModal === "", but keep
        // the guard so programmatic callers can't wedge the modal stack.
        if (activeModal !== "" && activeModal !== "globalSearch") return
        openModal("globalSearch", {})
    }

    function closeGlobalSearch() {
        if (activeModal === "globalSearch") closeModal()
    }

    // Resolve a library tabKey to its live tab index. tabKeys shifts when the
    // Strong's tab is hidden, so an index can't be hard-coded. Returns -1 when
    // the tab isn't currently present (e.g. a Strong's hit while the tab is
    // off — the caller falls back to a no-op reveal).
    function tabIndexFor(tabKey) {
        const keys = tabKeys
        for (let i = 0; i < keys.length; i++)
            if (keys[i] === tabKey) return i
        return -1
    }

    // Reveal a global-search result in its own library tab: switch tabs, then
    // surface the item — jump the scripture / song lists via the existing
    // schedule-sync signals, or seed the filter-based tabs' search box so the
    // list narrows to the hit. Closes the palette so focus lands in the tab.
    //
    // `result` is the overlay's row shape:
    //   { type, title, item, scriptureRef?, songId?, revealQuery? }
    // where `type` is both the SettingsService action key AND the library
    // tabKey (the two vocabularies share the same strings).
    function revealResult(result) {
        if (!result) return
        closeGlobalSearch()
        const idx = tabIndexFor(result.type)
        if (idx >= 0) setActiveTab(idx)
        if (result.type === "scripture" && result.scriptureRef) {
            const r = result.scriptureRef
            setLibraryGroup("scripture", String(r.translationCode || "").toLowerCase())
            syncScriptureFromSchedule(r.book, r.chapter, r.verse, r.translationCode || "")
        } else if (result.type === "songs" && result.songId) {
            syncSongFromSchedule(result.songId)
        } else if (result.revealQuery !== undefined) {
            setSearch(result.type, result.revealQuery)
        }
    }

    // Fire a global-search result's action. With no override, the per-type
    // primary from SettingsService.globalSearchActions applies (what Enter /
    // row-click does); the row's secondary buttons pass an explicit override
    // ("preview" | "reveal" | "golive" | "schedule").
    function runGlobalSearchAction(result, actionOverride) {
        if (!result) return
        let action = actionOverride || ""
        if (action === "") {
            const map = SettingsService.globalSearchActions || ({})
            action = map[result.type] || "reveal"
        }
        // Themes carry no projectable content — preview / golive have nothing
        // to stage, so they collapse to reveal.
        if (result.type === "themes" && (action === "preview" || action === "golive"))
            action = "reveal"

        if (action === "reveal") { revealResult(result); return }

        // The projectable actions need the built canonical schedule-item. If a
        // row somehow lacks one, fall back to revealing it rather than no-op.
        const item = result.item
        if (!item) { revealResult(result); return }

        if (action === "golive") {
            closeGlobalSearch()
            pushLibraryLive(item, result.page || 0)
        } else if (action === "schedule") {
            // Keep the palette open so the operator can queue several items in
            // a row without re-opening it each time.
            addItemToSchedule(item)
        } else { // "preview"
            // Songs & scriptures aren't just staged — they're also revealed and
            // highlighted in their own library tab, so the palette hit behaves
            // like "take me to this item": the row lights up in Songs/Scripture
            // AND the slide lands in Preview.
            if (result.type === "songs") {
                revealResult(result)                       // switch tab + highlight the song row (closes palette)
                pushLibraryPreview(item, result.page || 0) // stage, jumped to the matched / selected lyric section
                setActiveFocus("preview")                  // so that section's card shows the full active highlight
            } else if (result.type === "scripture") {
                // revealResult already stages the verse to Preview (via the
                // Scripture tab's pushPreviewFor) AND highlights its row, with
                // the tab's richer item (carries copyText for the copy button).
                revealResult(result)
            } else {
                closeGlobalSearch()
                pushLibraryPreview(item, result.page || 0)
            }
        }
    }
}
