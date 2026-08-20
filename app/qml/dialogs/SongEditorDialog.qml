import QtQuick
import QtQuick.Controls.Basic
import Crater

// Song editor — full structured/raw editor with live theme-rendered preview.
//
// Behavioral parity with electron/src/components/modals/SongEditor.tsx:
//   • title input + theme override picker + section count
//   • structured mode (per-section cards) and raw mode (single textarea
//     using `[Label]` markers for sections)
//   • undo/redo stack, dirty-state confirmation on close
//   • Ctrl+S = save, Ctrl+Z = undo, Ctrl+Y/Ctrl+Shift+Z = redo, Ctrl+M
//     toggle view mode (electron used Ctrl+Shift+M; we use Ctrl+M because
//     it doesn't collide with anything else in the operator console)
//   • live preview rendered through the same ThemedMonitor used by the
//     Preview/Live panels, so the editor shows what the projection will
//
// Persistence: Save calls SongService.update(...) for existing songs and
// SongService.createWithSections(...) for new ones. Both are atomic per the
// service implementation (single transaction, FTS row rebuilt on commit).
ModalShell {
    id: root

    // Plenty of room for two side-by-side panes + chrome.
    dialogWidth:  1100
    dialogHeight: 720

    // We render our own header inside the body so the title input, theme
    // picker, and view toggle can sit on one toolbar with proper spacing.
    showHeader: false

    // ── Mode + identity ─────────────────────────────────────────────────
    // songId comes from AppState.modalProps; -1 means "create new song".
    // Set once on construction; changing modalProps mid-edit is a no-op.
    readonly property int _songId:
        (AppState.modalProps && typeof AppState.modalProps.songId === "number")
            ? AppState.modalProps.songId
            : -1
    readonly property bool _isEditMode: _songId > 0

    // ── Working state ───────────────────────────────────────────────────
    property string _title: ""
    property string _author: ""
    property string _ccli: ""
    property int    _themeId: 0          // 0 = use default-for-kind
    property var    _sections: [{ label: "", kind: "other", lines: [""] }]
    property int    _currentSection: 0   // drives the live preview pane

    property string _viewMode: "structured"  // "structured" | "raw"
    property string _rawText: ""

    // ── Raw-mode WYSIWYG bridging state ─────────────────────────────────
    // Raw mode is a flat WYSIWYG editor (Phase 7+): the rawArea renders
    // formatting inline, so cursor positions are in plain-text space
    // (not DSL-source space). `_rawText` stays as the DSL form (source of
    // truth for round-trip / save / re-population); these flags break
    // the same feedback loop that LyricSectionEditor handles for its own
    // RichText editor — see the doc comment there for the full pattern.
    property bool   _settingRawText: false
    property string _lastEmittedRawDsl: ""

    // ── Shared-toolbar focus tracking ───────────────────────────────────
    // Holds the last TextEdit that gained focus in the lyric-editing
    // surface — either rawArea or one of the LyricSectionEditor's
    // linesEdit instances. The shared LyricsToolbar (one in structured
    // mode, one in raw mode) reads this as its `target`, so format
    // toggles always land on whichever editor the operator is actively
    // typing into.
    //
    // Keyboard shortcuts (Ctrl+B/I/U) use this PLUS an activeFocus check
    // so the shortcut is inert when focus has moved to a non-lyric
    // control (title input, theme dropdown, etc.).
    property var _focusedLyricEditor: null

    function _toolbarBold() {
        if (_focusedLyricEditor && _focusedLyricEditor.activeFocus) {
            RichTextHelper.toggleBold(_focusedLyricEditor)
        }
    }
    function _toolbarItalic() {
        if (_focusedLyricEditor && _focusedLyricEditor.activeFocus) {
            RichTextHelper.toggleItalic(_focusedLyricEditor)
        }
    }
    function _toolbarUnderline() {
        if (_focusedLyricEditor && _focusedLyricEditor.activeFocus) {
            RichTextHelper.toggleUnderline(_focusedLyricEditor)
        }
    }

    property bool   _titleError: false
    property bool   _isSaving:   false
    property bool   _isLoading:  false

    // Transient save-failure surface. SongService.update / createWithSections
    // can return false (e.g. the song was deleted from another path, a DB
    // constraint violated, etc.). Without this the failure is silent — the
    // operator clicks Save and the dialog just sits there.
    property string _saveError: ""
    Timer {
        id: saveErrorClearTimer
        interval: 5000
        onTriggered: root._saveError = ""
    }

    // ── Undo/redo (mirrors electron's history snapshot stack) ───────────
    // Each entry is a deep clone of _sections at that point in time. We
    // push a snapshot BEFORE every mutation so undo returns to the prior
    // state. _historyIndex == 0 == clean; > 0 == dirty.
    property var _history: []
    property int _historyIndex: -1
    readonly property bool _canUndo: _historyIndex > 0
    readonly property bool _canRedo: _historyIndex < _history.length - 1
    readonly property bool _isDirty: _historyIndex > 0

    // ── Theme list filtered to song-kind themes ─────────────────────────
    // Read once via ThemeService.allThemes and refiltered via the revision
    // bump so Save→close→reopen sees newly-created themes.
    property int _themeRevision: 0
    Connections {
        target: ThemeService
        function onAllThemesChanged() { root._themeRevision++ }
        function onDefaultsChanged()  { root._themeRevision++ }
    }
    readonly property var _songThemeOptions: {
        _themeRevision    // dependency
        const all = ThemeService.allThemes || []
        let out = [{ label: qsTr("Use default theme"), value: "0" }]
        for (let i = 0; i < all.length; i++) {
            const t = all[i]
            if (t && t.kind === "song") out.push({ label: t.name, value: String(t.id) })
        }
        return out
    }
    readonly property string _themeComboValue: String(_themeId)

    // ── Synthetic preview item ──────────────────────────────────────────
    // ThemedMonitor wants a canonical schedule-item shape. We re-derive it
    // whenever _sections / _currentSection / _themeId / _title change so the
    // preview reflects the live editor state.
    readonly property var _previewItem: {
        const pages = []
        for (let i = 0; i < _sections.length; i++) {
            const sec = _sections[i] || {}
            pages.push({
                label:   sec.label || "",
                content: (sec.lines && sec.lines.length > 0) ? sec.lines.join("\n") : ""
            })
        }
        if (pages.length === 0) pages.push({ label: "", content: _title || "" })
        return {
            kind:    "song",
            title:   _title || qsTr("Untitled song"),
            pages:   pages,
            songId:  _isEditMode ? _songId : 0,
            themeId: _themeId
        }
    }
    readonly property int _previewPage:
        Math.max(0, Math.min(_currentSection, _previewItem.pages.length - 1))

    // ── Lifecycle ───────────────────────────────────────────────────────
    Component.onCompleted: {
        // Reopen in the operator's last-used view mode. A raw-mode user
        // shouldn't be forced back to structured on every song open. Set
        // this BEFORE _loadExisting / _initFresh so any view-mode-dependent
        // staging in those paths sees the correct value.
        _viewMode = AppState.songEditorViewMode
        if (_isEditMode) _loadExisting(_songId)
        else             _initFresh()
        titleInput.forceActiveFocus()
    }

    function _initFresh() {
        _title  = ""
        _author = ""
        _ccli   = ""
        _themeId = 0
        const empty = [{ label: "", kind: "other", lines: [""] }]
        _sections = empty
        _history = [_clone(empty)]
        _historyIndex = 0
        _currentSection = 0
        _refreshRawText()
    }

    function _loadExisting(id) {
        _isLoading = true
        const song = SongService.fetchSong(id)
        if (!song || song.id === 0) {
            // Fall through to fresh — the songId in modalProps no longer
            // points at anything (deleted elsewhere). Better than a blank
            // dialog with no recoverable state.
            qmlWarn("SongEditorDialog: song " + id + " not found, opening fresh")
            _initFresh()
            _isLoading = false
            return
        }
        _title   = song.title || ""
        _author  = song.author || ""
        _ccli    = song.ccli || ""
        _themeId = song.themeId || 0

        const secs = []
        for (let i = 0; i < song.sections.length; i++) {
            const s = song.sections[i]
            secs.push({
                label: s.label || "",
                kind:  s.kind  || "other",
                lines: (s.lines && s.lines.length > 0) ? s.lines.slice() : [""]
            })
        }
        if (secs.length === 0) secs.push({ label: "", kind: "other", lines: [""] })
        _sections      = secs
        _history       = [_clone(secs)]
        _historyIndex  = 0
        _currentSection = 0
        _refreshRawText()
        _isLoading = false
    }

    // ── History helpers ─────────────────────────────────────────────────
    function _clone(secs) {
        // Deep clone — JSON round-trip is fine for the tiny section payload.
        return JSON.parse(JSON.stringify(secs || []))
    }
    function _snapshot() {
        const trunc = _history.slice(0, _historyIndex + 1)
        trunc.push(_clone(_sections))
        _history = trunc
        _historyIndex = trunc.length - 1
    }
    function _undo() {
        if (!_canUndo) return
        _historyIndex--
        _sections = _clone(_history[_historyIndex])
        _refreshRawText()
    }
    function _redo() {
        if (!_canRedo) return
        _historyIndex++
        _sections = _clone(_history[_historyIndex])
        _refreshRawText()
    }

    // ── Mutators (always snapshot first so undo works) ──────────────────
    function _setLabel(idx, value) {
        if (idx < 0 || idx >= _sections.length) return
        if (_sections[idx].label === value) return
        _snapshot()
        const next = _clone(_sections)
        next[idx].label = value
        _sections = next
    }
    function _setLines(idx, value) {
        if (idx < 0 || idx >= _sections.length) return
        const arr = (value === undefined || value === null) ? [""] : value.split("\n")
        const cur = _sections[idx].lines || []
        if (arr.length === cur.length && arr.every(function(l, i) { return l === cur[i] })) return
        _snapshot()
        const next = _clone(_sections)
        next[idx].lines = arr
        _sections = next
    }
    function _addSection() {
        _snapshot()
        const next = _clone(_sections)
        next.push({ label: "", kind: "other", lines: [""] })
        _sections = next
        _currentSection = next.length - 1
        // Defer focus until the Repeater has instantiated the new card.
        Qt.callLater(function() {
            const item = sectionsRepeater.itemAt(next.length - 1)
            if (item) item.focusLabel()
        })
    }
    function _duplicateSection(idx) {
        if (idx < 0 || idx >= _sections.length) return
        _snapshot()
        const next = _clone(_sections)
        const dup = _clone([next[idx]])[0]
        next.splice(idx + 1, 0, dup)
        _sections = next
        _currentSection = idx + 1
    }
    function _deleteSection(idx) {
        if (_sections.length <= 1) return
        _snapshot()
        const next = _clone(_sections)
        next.splice(idx, 1)
        _sections = next
        if (_currentSection >= next.length) _currentSection = next.length - 1
    }

    // ── Raw mode <-> structured ─────────────────────────────────────────
    //
    // The DSL contract (Phase 2+): each entry of `section.lines` is a DSL
    // string (e.g. "**Amazing** grace, how *sweet* the sound"). Plain text
    // is a valid DSL string with no markers, so existing songs round-trip
    // unchanged. The functions below treat lines as opaque DSL strings —
    // joining/splitting them does NOT require parsing the DSL, because
    // marks can't cross line boundaries (per the v1 grammar rule).
    function _refreshRawText() {
        let parts = []
        for (let i = 0; i < _sections.length; i++) {
            const s = _sections[i] || {}
            const body = (s.lines || []).join("\n")
            parts.push(s.label ? ("[" + s.label + "]\n" + body) : body)
        }
        _rawText = parts.join("\n\n")
        // Push the rebuilt DSL into the raw editor's HTML buffer. The
        // _settingRawText guard inside _applyRawDsl prevents the resulting
        // onTextChanged from echoing back as a new edit. This lets every
        // caller (undo / redo / section-add / section-delete / view-toggle)
        // sync the raw editor with one function call rather than each
        // remembering to also re-apply.
        _applyRawDsl(_rawText)
    }
    function _parseRawToSections(text) {
        const lines = text.split("\n")
        const out = []
        let current = null
        for (let i = 0; i < lines.length; i++) {
            const line = lines[i]
            const trimmed = line.trim()
            const labelMatch = trimmed.match(/^\[(.*)\]$/)
            if (labelMatch) {
                current = { label: labelMatch[1], kind: "other", lines: [] }
                out.push(current)
            } else if (trimmed.length > 0) {
                if (!current) {
                    current = { label: "", kind: "other", lines: [] }
                    out.push(current)
                }
                current.lines.push(line)
            } else if (current) {
                // Blank line breaks the section so the next non-blank starts a
                // new one. Matches electron's parseRawToLyrics behavior.
                current = null
            }
        }
        if (out.length === 0) out.push({ label: "", kind: "other", lines: [""] })
        // Make sure every section has at least an empty lines array so the
        // structured side renders a textarea (even for label-only sections).
        for (let j = 0; j < out.length; j++) {
            if (!out[j].lines || out[j].lines.length === 0) out[j].lines = [""]
        }
        return out
    }
    function _commitRawText(text) {
        const parsed = _parseRawToSections(text)
        // Compare against current — skip the snapshot if nothing actually
        // changed (e.g. whitespace-only diffs).
        const cur = JSON.stringify(_sections)
        const nxt = JSON.stringify(parsed)
        if (cur === nxt) return
        _snapshot()
        _sections = parsed
        if (_currentSection >= parsed.length) _currentSection = parsed.length - 1
    }

    // Find which section index the raw-mode cursor sits inside. Mirrors
    // the _parseRawToSections walking logic, counting sections as we go,
    // but stops at the line containing the cursor. Used by rawArea's
    // onCursorPositionChanged to keep the right-pane preview in sync
    // with whatever verse the operator is currently editing in raw mode.
    //
    // `textOverride` is the editor's PLAIN TEXT when raw mode runs in
    // RichText (Phase 7+) — cursor positions are plain-text indices in
    // that mode, NOT DSL-source indices, so we walk the plain text the
    // operator sees on screen. Section labels `[Verse 1]` are still
    // visible as plain text (sectioning DSL is operator-readable), so
    // the same regex match works on either input form.
    function _sectionAtRawCursor(cursorPos, textOverride) {
        const text = (textOverride !== undefined && textOverride !== null)
            ? textOverride : _rawText
        if (!text || cursorPos < 0) return 0
        // Take the slice up through the END of the cursor's line so the
        // line the cursor sits on is fully counted (not just the chars
        // before the cursor within that line).
        let endOfLine = text.indexOf("\n", cursorPos)
        if (endOfLine < 0) endOfLine = text.length
        const slice = text.substring(0, endOfLine)
        const lines = slice.split("\n")
        let sectionIdx = -1
        let inSection  = false
        for (let i = 0; i < lines.length; i++) {
            const trimmed = lines[i].trim()
            const isLabel = /^\[(.*)\]$/.test(trimmed)
            if (isLabel) {
                sectionIdx++
                inSection = true
            } else if (trimmed.length > 0) {
                if (!inSection) { sectionIdx++; inSection = true }
            } else {
                inSection = false
            }
        }
        if (sectionIdx < 0) sectionIdx = 0
        if (sectionIdx >= _sections.length) sectionIdx = _sections.length - 1
        return sectionIdx
    }

    // Push the current DSL form into the raw editor's HTML buffer. Used
    // on view-switch to raw, on initial dialog load if raw is the
    // default, and whenever sections change in structured mode while
    // raw mode is staged. The flag suppresses the onTextChanged echo
    // (same pattern as LyricSectionEditor's _applyDslToEditor).
    function _applyRawDsl(dsl) {
        _settingRawText = true
        rawArea.text = LyricsService.dslToHtml(dsl || "")
        _settingRawText = false
        _lastEmittedRawDsl = dsl || ""
    }

    function _toggleViewMode() {
        if (_viewMode === "structured") {
            // _refreshRawText also calls _applyRawDsl, so the raw editor
            // is staged with current content before we flip visibility.
            _refreshRawText()
            _viewMode = "raw"
        } else {
            // Commit any raw edits back into structured form before flipping.
            _commitRawText(_rawText)
            _viewMode = "structured"
        }
        // Remember for the next dialog open. AppState slot is session-only;
        // a SettingsService-backed persistent slot can replace it later.
        AppState.setSongEditorViewMode(_viewMode)
    }

    // ── Save & close ────────────────────────────────────────────────────
    function _saveSong() {
        const t = _title.trim()
        if (t.length === 0) {
            _titleError = true
            titleInput.forceActiveFocus()
            return
        }
        // Make sure raw-mode edits are reflected in _sections before persisting.
        if (_viewMode === "raw") _commitRawText(_rawText)

        _isSaving = true
        _saveError = ""
        let ok = false
        if (_isEditMode) {
            ok = SongService.update(_songId, t, _author, _ccli, _themeId, _sections)
        } else {
            const newId = SongService.createWithSections(t, _author, _ccli, _themeId, _sections)
            ok = newId > 0
        }
        _isSaving = false
        if (ok) {
            // Mark current state as the "clean baseline" so reopening doesn't
            // prompt about unsaved changes after a successful save.
            _history = [_clone(_sections)]
            _historyIndex = 0
            AppState.closeModal()
        } else {
            // Surface the failure: log to the Qt console for diagnosis, and
            // show a transient banner in the footer so the operator sees
            // something happened. SongService logs its own qWarning() to
            // stderr describing the root cause (DB error, deleted song, etc.).
            console.warn("SongEditorDialog: save failed"
                       + " mode=" + (_isEditMode ? "update" : "create")
                       + " songId=" + _songId
                       + " title=" + JSON.stringify(t)
                       + " sections=" + _sections.length)
            _saveError = _isEditMode
                ? qsTr("Could not save changes. See log for details.")
                : qsTr("Could not create song. See log for details.")
            saveErrorClearTimer.restart()
        }
    }

    function _requestClose() {
        if (!_isDirty) { AppState.closeModal(); return }
        // Stage a confirm dialog before tearing this one down. Closing the
        // current modal then opening the confirm one fires the Loader churn,
        // but our state vanishes with the dialog — so the onConfirm closure
        // captures _isDirty by value before the modal teardown.
        const sId = _songId
        AppState.openModal("confirm", {
            title:       qsTr("Discard changes?"),
            body:        qsTr("You have unsaved changes to this song. Close without saving?"),
            confirmText: qsTr("Discard"),
            onConfirm:   function() {
                // The confirm dialog calls closeModal() itself when its
                // onConfirm returns — nothing else to do here.
            }
        })
    }

    // ── Shortcuts (Qt.WindowShortcut while dialog is loaded) ────────────
    Shortcut { sequence: "Ctrl+S"; onActivated: root._saveSong() }
    Shortcut { sequence: "Ctrl+Z"; onActivated: root._undo() }
    Shortcut { sequence: "Ctrl+Y"; onActivated: root._redo() }
    Shortcut { sequence: "Ctrl+Shift+Z"; onActivated: root._redo() }
    Shortcut { sequence: "Ctrl+M"; onActivated: root._toggleViewMode() }
    // Ctrl+Tab toggles the editor's own view mode while the dialog is
    // up — Main.qml's window-level Ctrl+Tab (which cycles operator
    // console tabs) is disabled while activeModal !== "", so this is
    // the only handler that fires.
    Shortcut { sequence: "Ctrl+Tab";       onActivated: root._toggleViewMode() }
    Shortcut { sequence: "Ctrl+Shift+Tab"; onActivated: root._toggleViewMode() }

    // Rich-text shortcuts — apply formatting to the currently-focused
    // lyric editor. Each handler guards on `_focusedLyricEditor.activeFocus`
    // so the shortcut is a silent no-op if the operator is typing in the
    // title input, theme dropdown, or any other non-lyric control.
    Shortcut { sequence: "Ctrl+B"; onActivated: root._toolbarBold() }
    Shortcut { sequence: "Ctrl+I"; onActivated: root._toolbarItalic() }
    Shortcut { sequence: "Ctrl+U"; onActivated: root._toolbarUnderline() }

    // Escape via Modal backdrop is already handled by ModalShell; we add
    // a Shortcut so the editor's own form fields don't swallow Esc.
    Shortcut { sequence: "Escape"; onActivated: root._requestClose() }

    // ─── Custom header ──────────────────────────────────────────────────
    Item {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        // Taller header to accommodate the bigger title input row below
        // (row1 stays 44; row2 gets the extra height for a 44-tall input).
        height: 104

        // Row 1 — dialog title + section count + actions (undo/redo/close)
        Item {
            id: headerRow1
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: 44

            Row {
                anchors.left: parent.left
                anchors.leftMargin: Theme.space.lg
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.space.md

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root._isEditMode ? qsTr("Edit Song") : qsTr("Create New Song")
                    color: Theme.color.textPrimary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize + 3
                    font.weight: Theme.font.weightSemiBold
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root._sections.length + " " +
                          (root._sections.length === 1 ? qsTr("section") : qsTr("sections"))
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                }
                // Unsaved-changes indicator — mirrors electron's amber dot+label.
                Row {
                    visible: root._isDirty
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.space.xs
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 6; height: 6; radius: 3
                        color: Theme.color.brand
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Unsaved changes")
                        color: Theme.color.brand
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                    }
                }
            }

            // Right cluster: undo / redo / close
            Row {
                anchors.right: parent.right
                anchors.rightMargin: Theme.space.md
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.space.xs

                IconButton {
                    iconName: "undo-2"
                    iconSize: Theme.icon.sm
                    enabled: root._canUndo
                    onClicked: root._undo()
                }
                IconButton {
                    iconName: "redo-2"
                    iconSize: Theme.icon.sm
                    enabled: root._canRedo
                    onClicked: root._redo()
                }
                Item { width: Theme.space.sm; height: 1 }
                IconButton {
                    iconName: "x"
                    iconSize: Theme.icon.md
                    onClicked: root._requestClose()
                }
            }
        }

        // Row 2 — title input, theme combobox, view mode toggle
        Item {
            id: headerRow2
            anchors.top: headerRow1.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: Theme.space.lg
            anchors.rightMargin: Theme.space.lg

            // Title input — left, expands to fill. Taller + bigger font so
            // the song title reads as the dialog's primary identifier.
            Rectangle {
                id: titleWrap
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: viewToggleWrap.left
                anchors.rightMargin: Theme.space.md
                height: 44
                radius: 0
                color: Theme.color.canvas
                border.color: root._titleError ? Theme.color.live
                            : titleInput.activeFocus ? Theme.color.brand
                                                     : Theme.color.borderStrong
                border.width: 1
                Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }

                TextInput {
                    id: titleInput
                    anchors.left: parent.left
                    anchors.right: themeComboWrap.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    anchors.leftMargin: Theme.space.md
                    anchors.rightMargin: Theme.space.md
                    verticalAlignment: TextInput.AlignVCenter
                    color: Theme.color.textPrimary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize + 4
                    font.weight: Theme.font.weightSemiBold
                    selectByMouse: true
                    text: root._title
                    onTextEdited: { root._title = text; root._titleError = false }
                    onAccepted: root._saveSong()

                    Text {
                        visible: titleInput.text.length === 0
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Enter song title…")
                        color: Theme.color.textTertiary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.bodySize + 4
                        font.weight: Theme.font.weightSemiBold
                    }
                }

                // Theme combobox — inline on the right of the title row.
                // Taller (32) + wider (240) so the trigger feels like a peer
                // affordance, not a vestigial chip squeezed into a corner.
                Item {
                    id: themeComboWrap
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.rightMargin: Theme.space.sm
                    width: 240
                    height: 32

                    Combobox {
                        anchors.fill: parent
                        options: root._songThemeOptions
                        // Combobox uses the display label as `value`. We resolve
                        // the chosen label back to the theme id below.
                        value: {
                            const opts = root._songThemeOptions
                            for (let i = 0; i < opts.length; i++)
                                if (opts[i].value === root._themeComboValue) return opts[i].label
                            return opts.length > 0 ? opts[0].label : ""
                        }
                        placeholder: qsTr("Use default theme")
                        searchable: true
                        onValueSelected: function(v) {
                            // v is the option's `value` field — our numeric id string.
                            const id = parseInt(v, 10)
                            root._themeId = isNaN(id) ? 0 : id
                        }
                    }
                }
            }

            // View-mode toggle — segmented control, right side. Flat radii
            // match the rest of the modal's data-app aesthetic.
            Rectangle {
                id: viewToggleWrap
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: 180
                height: 32
                radius: 0
                color: Theme.color.canvas
                border.color: Theme.color.borderStrong
                border.width: 1

                Row {
                    anchors.fill: parent
                    anchors.margins: 2
                    spacing: 0

                    Rectangle {
                        width: (parent.width) / 2
                        height: parent.height
                        radius: 0
                        color: root._viewMode === "structured" ? Theme.color.raised : "transparent"
                        Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
                        Text {
                            anchors.centerIn: parent
                            text: qsTr("Structured")
                            color: root._viewMode === "structured" ? Theme.color.textPrimary
                                                                   : Theme.color.textSecondary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.smallSize
                            font.weight: Theme.font.weightMedium
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: if (root._viewMode !== "structured") root._toggleViewMode()
                        }
                    }
                    Rectangle {
                        width: (parent.width) / 2
                        height: parent.height
                        radius: 0
                        color: root._viewMode === "raw" ? Theme.color.raised : "transparent"
                        Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
                        Text {
                            anchors.centerIn: parent
                            text: qsTr("Raw text")
                            color: root._viewMode === "raw" ? Theme.color.textPrimary
                                                            : Theme.color.textSecondary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.smallSize
                            font.weight: Theme.font.weightMedium
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: if (root._viewMode !== "raw") root._toggleViewMode()
                        }
                    }
                }
            }
        }

        // Bottom divider
        Rectangle {
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: 1
            color: Theme.color.borderSubtle
        }
    }

    // ─── Body — split pane ──────────────────────────────────────────────
    Item {
        id: body
        anchors.top: header.bottom
        anchors.bottom: footer.top
        anchors.left: parent.left
        anchors.right: parent.right

        // Vertical divider between editor (left) and preview (right)
        Rectangle {
            id: splitter
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: parent.width * 0.55
            width: 1
            height: parent.height
            color: Theme.color.borderSubtle
        }

        // ── Left pane: structured or raw editor ─────────────────────────
        Item {
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: splitter.left

            // Structured mode — scrollable list of LyricSectionEditor cards
            // plus an "Add section" button at the bottom.
            Item {
                anchors.fill: parent
                visible: root._viewMode === "structured" && !root._isLoading

                // Shared formatting toolbar — sits above the section list,
                // always visible. Its `target` re-binds whenever the
                // operator clicks into a different section's lyric editor
                // (each section's LyricSectionEditor emits
                // `lyricEditorActivated` with its own linesEdit).
                LyricsToolbar {
                    id: structuredToolbar
                    target: root._focusedLyricEditor
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: Theme.space.lg
                    anchors.rightMargin: Theme.space.lg
                    anchors.topMargin: Theme.space.sm
                }

                Flickable {
                    id: sectionsScroll
                    anchors.top: structuredToolbar.bottom
                    anchors.topMargin: Theme.space.sm
                    anchors.bottom: parent.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: Theme.space.lg
                    anchors.rightMargin: Theme.space.lg
                    anchors.bottomMargin: Theme.space.lg
                    contentWidth:  sectionsCol.width
                    contentHeight: sectionsCol.height
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    Column {
                        id: sectionsCol
                        width: sectionsScroll.width
                        spacing: Theme.space.sm

                        Repeater {
                            id: sectionsRepeater
                            model: root._sections

                            // Inline wrapper so we can declare the index +
                            // modelData as required properties (Qt 6 idiom)
                            // and forward them to LyricSectionEditor without
                            // shadowing the delegate's `index` context property.
                            delegate: Item {
                                id: sectionItem
                                required property int index
                                required property var modelData

                                width:  sectionsCol.width
                                height: cardEditor.implicitHeight

                                // Forwarded so `_addSection` can do
                                // `sectionsRepeater.itemAt(i).focusLabel()`
                                // without having to dig through children.
                                function focusLabel() { cardEditor.focusLabel() }

                                LyricSectionEditor {
                                    id: cardEditor
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    index:     sectionItem.index
                                    label:     (sectionItem.modelData && sectionItem.modelData.label) || ""
                                    linesText: (sectionItem.modelData && sectionItem.modelData.lines)
                                        ? sectionItem.modelData.lines.join("\n") : ""
                                    canDelete: root._sections.length > 1
                                    active:    root._currentSection === sectionItem.index

                                    onLabelEdited: function(idx, value) { root._setLabel(idx, value) }
                                    onLinesEdited: function(idx, value) { root._setLines(idx, value) }
                                    onFocused:     function(idx)        { root._currentSection = idx }
                                    onDeleteRequested:    function(idx) { root._deleteSection(idx) }
                                    onDuplicateRequested: function(idx) { root._duplicateSection(idx) }
                                    // Re-target the dialog's shared
                                    // toolbar at the section's editor
                                    // whenever this one gains focus.
                                    onLyricEditorActivated: function(idx, editor) {
                                        root._focusedLyricEditor = editor
                                    }
                                }
                            }
                        }

                        // "Add section" button — dashed border ghost, full width
                        Rectangle {
                            width: sectionsCol.width
                            height: 44
                            radius: 0
                            color: addMa.containsMouse ? Theme.color.overlay : "transparent"
                            border.color: Theme.color.borderStrong
                            border.width: 1
                            Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

                            Row {
                                anchors.centerIn: parent
                                spacing: Theme.space.xs
                                AppIcon {
                                    anchors.verticalCenter: parent.verticalCenter
                                    name: "plus"
                                    size: Theme.icon.sm
                                    color: Theme.color.textSecondary
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: qsTr("Add section")
                                    color: Theme.color.textSecondary
                                    font.family: Theme.font.family
                                    font.pixelSize: Theme.font.bodySize
                                    font.weight: Theme.font.weightMedium
                                }
                            }

                            MouseArea {
                                id: addMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root._addSection()
                            }
                        }

                        // Footer hint mirroring electron's keyboard-shortcut row.
                        Item {
                            width: sectionsCol.width
                            height: 20
                            Text {
                                anchors.centerIn: parent
                                text: qsTr("Ctrl+S save · Ctrl+Z undo · Ctrl+M toggle view")
                                color: Theme.color.textTertiary
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.smallSize - 1
                            }
                        }
                    }
                }
            }

            // Raw mode — flat WYSIWYG textarea. Phase 7: formatting renders
            // inline (bold/italic/underline/color visible as rendered text,
            // not as DSL markers), and the LyricsToolbar drives it via the
            // same RichTextHelper paths the structured-mode cards use.
            // Section labels `[Verse 1]` stay as plain text — they're the
            // sectioning grammar, separate from the formatting grammar,
            // and operators still see/edit them as text.
            Item {
                anchors.fill: parent
                visible: root._viewMode === "raw" && !root._isLoading

                // Formatting toolbar — always visible at the top of the
                // raw pane. Targets `_focusedLyricEditor` (set when
                // rawArea gains focus below) rather than rawArea
                // directly, so the shared focus model is consistent
                // with structured mode.
                LyricsToolbar {
                    id: rawToolbar
                    target: root._focusedLyricEditor
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: Theme.space.lg
                    anchors.rightMargin: Theme.space.lg
                    anchors.topMargin: Theme.space.sm
                }

                Rectangle {
                    anchors.top: rawToolbar.bottom
                    anchors.topMargin: Theme.space.sm
                    anchors.bottom: parent.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: Theme.space.lg
                    anchors.rightMargin: Theme.space.lg
                    anchors.bottomMargin: Theme.space.lg
                    radius: 0
                    color: Theme.color.canvas
                    border.color: rawArea.activeFocus ? Theme.color.brand : Theme.color.borderStrong
                    border.width: 1
                    Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }

                    Flickable {
                        id: rawScroll
                        anchors.fill: parent
                        anchors.margins: Theme.space.md
                        contentWidth: width
                        contentHeight: Math.max(height, rawArea.contentHeight + Theme.space.lg)
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds

                        TextEdit {
                            id: rawArea
                            width: rawScroll.width
                            // Always fill the viewport at minimum so clicks
                            // below the last line still land on the editor.
                            // Qt's default click-past-text behavior snaps the
                            // cursor to end-of-text; without this the TextEdit
                            // shrinks to its text size and the rest of the box
                            // becomes inert background.
                            height: Math.max(contentHeight, rawScroll.height)
                            // RichText so inline DSL formatting renders
                            // WYSIWYG. The text on the wire stays DSL via
                            // the _applyRawDsl / htmlToDsl bridge below.
                            textFormat: TextEdit.RichText
                            color: Theme.color.textPrimary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.bodySize
                            selectByMouse: true
                            wrapMode: TextEdit.Wrap
                            onTextChanged: {
                                // Skip the echo from our own _applyRawDsl().
                                if (root._settingRawText) return
                                const dsl = LyricsService.htmlToDsl(text)
                                if (dsl !== root._lastEmittedRawDsl) {
                                    root._lastEmittedRawDsl = dsl
                                    root._rawText = dsl
                                    root._commitRawText(dsl)
                                }
                            }
                            // Ctrl+V / Ctrl+Shift+V go through RichTextHelper
                            // rather than TextEdit's built-in paste, which
                            // hands the clipboard's text/html straight to
                            // QTextDocument and so imports a source page's
                            // background slab, body colour, family and size
                            // along with the words. pasteFiltered keeps bold /
                            // italic / underline and re-applies this editor's
                            // own format to everything else. Shift = paste as
                            // plain text. See RichTextHelper.h.
                            Keys.onPressed: function(event) {
                                if (event.key === Qt.Key_V
                                    && (event.modifiers & Qt.ControlModifier)) {
                                    RichTextHelper.pasteFiltered(
                                        rawArea,
                                        !(event.modifiers & Qt.ShiftModifier))
                                    event.accepted = true
                                }
                            }
                            // Tell the dialog this editor is now the
                            // toolbar's target. Set on entry only — we
                            // intentionally DO NOT clear on loss of
                            // focus so the toolbar's `target` survives
                            // focus moves to the toolbar buttons. The
                            // shortcuts' activeFocus guard handles the
                            // "is the editor still the right surface"
                            // question independently.
                            onActiveFocusChanged: {
                                if (activeFocus) root._focusedLyricEditor = rawArea
                            }
                            // Track which section the cursor is inside so the
                            // right-pane preview shows that verse. Cursor is
                            // in PLAIN-TEXT space (RichText), so we walk the
                            // editor's plain text (via getText) rather than
                            // _rawText (which is DSL-form and indexes
                            // differently).
                            onCursorPositionChanged: {
                                if (!activeFocus) return
                                const plain = rawArea.getText(0, rawArea.length)
                                const idx = root._sectionAtRawCursor(cursorPosition, plain)
                                if (idx !== root._currentSection) {
                                    root._currentSection = idx
                                }
                            }

                            Text {
                                // `length` is the plain-text char count; in
                                // RichText mode `text` is HTML markup which
                                // is never empty even for an empty doc, so
                                // we'd never hide otherwise.
                                visible: rawArea.length === 0 && !rawArea.activeFocus
                                anchors.left: parent.left
                                anchors.top: parent.top
                                // Phase 7 placeholder — formatting goes
                                // through the toolbar (or keyboard
                                // shortcuts), not literal markers.
                                // Operators only type `[Label]` by hand
                                // for sectioning.
                                text: qsTr("Type lyrics here. Use [Label] on its own "
                                        + "line to start a section (e.g. [Verse 1], "
                                        + "[Chorus]). Apply bold, italic, underline "
                                        + "and color from the toolbar above.")
                                color: Theme.color.textTertiary
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.bodySize
                                wrapMode: Text.WordWrap
                                width: rawArea.width
                            }
                        }
                    }
                }
            }

            // Loading shimmer — shown while SongService.fetchSong runs (sync
            // today, but the LoadingState is here for when it goes async).
            Item {
                anchors.fill: parent
                visible: root._isLoading
                Text {
                    anchors.centerIn: parent
                    text: qsTr("Loading lyrics…")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize
                }
            }
        }

        // ── Right pane: live preview ─────────────────────────────────────
        Item {
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.left: splitter.right
            anchors.right: parent.right

            Rectangle {
                anchors.fill: parent
                color: Theme.color.bgContent
            }

            Column {
                anchors.fill: parent
                anchors.margins: Theme.space.lg
                spacing: Theme.space.sm

                Text {
                    text: qsTr("Live preview")
                    color: Theme.color.textSecondary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                    font.weight: Theme.font.weightMedium
                }

                // 16:9 letterboxed monitor — matches the projection aspect so
                // the operator sees what the audience would see at full size.
                Item {
                    width: parent.width
                    height: width * 9 / 16

                    Rectangle {
                        anchors.fill: parent
                        radius: 0
                        color: "#000000"
                        border.color: Theme.color.borderStrong
                        border.width: 1
                        clip: true

                        ThemedMonitor {
                            anchors.fill: parent
                            anchors.margins: 1
                            item: root._previewItem
                            pageIndex: root._previewPage
                            muted: true
                        }
                    }
                }

                // Section label hint — replaces the per-section dot row.
                // The preview is intentionally single-card: it always shows
                // whichever section the editor is focused on (or the
                // cursor sits inside, in raw mode). This label gives the
                // operator a small "you're previewing X" cue.
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: root._sections.length > 1
                    text: {
                        const idx = root._currentSection
                        const sec = root._sections[idx]
                        const label = sec && sec.label ? String(sec.label) : ""
                        return label.length > 0
                            ? qsTr("Previewing: %1").arg(label)
                            : qsTr("Previewing section %1").arg(idx + 1)
                    }
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                }
            }
        }
    }

    // ─── Footer ─────────────────────────────────────────────────────────
    Rectangle {
        id: footer
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 56
        color: "transparent"

        Rectangle {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: 1
            color: Theme.color.borderSubtle
        }

        // Transient save-failure banner — auto-clears after 5s. Sits on
        // the left so it doesn't crowd the Cancel/Save buttons. Hidden
        // when _saveError is empty so the footer stays clean in the
        // common case.
        Row {
            visible: root._saveError.length > 0
            anchors.left: parent.left
            anchors.leftMargin: Theme.space.lg
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.space.sm

            AppIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "alert-triangle"
                color: Theme.color.live
                size: Theme.icon.sm
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root._saveError
                color: Theme.color.live
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize
                font.weight: Theme.font.weightMedium
            }
        }

        Row {
            anchors.right: parent.right
            anchors.rightMargin: Theme.space.lg
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.space.sm

            GhostButton {
                text: qsTr("Cancel")
                onClicked: root._requestClose()
            }
            PrimaryButton {
                variant: "brand"
                text: root._isSaving
                    ? qsTr("Saving…")
                    : (root._isEditMode ? qsTr("Save Changes") : qsTr("Create Song"))
                enabled: !root._isSaving && root._title.trim().length > 0
                onClicked: root._saveSong()
            }
        }
    }

    function qmlWarn(msg) { console.warn(msg) }
}
