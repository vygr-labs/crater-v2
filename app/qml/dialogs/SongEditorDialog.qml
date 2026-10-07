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
    property string _copyright: ""
    property string _ccli: ""
    property int    _themeId: 0          // 0 = use default-for-kind
    property var    _sections: [{ label: "", kind: "other", lines: [""] }]
    property int    _currentSection: 0   // drives the live preview pane

    property string _viewMode: "structured"  // "structured" | "raw"
    property string _rawText: ""

    // ── Shared-toolbar focus tracking ───────────────────────────────────
    // Holds the last TextEdit that gained focus in the lyric-editing
    // surface — either the raw editor or one of the LyricSectionEditor's
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
    // Title, theme and the credit fields sit outside the section history,
    // so they are compared against what the song opened with.
    property string _baseTitle: ""
    property int    _baseThemeId: 0
    property string _baseAuthor: ""
    property string _baseCopyright: ""
    property string _baseCcli: ""
    readonly property bool _isDirty: _historyIndex > 0
                                     || _title !== _baseTitle
                                     || _themeId !== _baseThemeId
                                     || _author !== _baseAuthor
                                     || _copyright !== _baseCopyright
                                     || _ccli !== _baseCcli

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

    // Called by AppState.requestCloseModal (Escape, backdrop, X).
    function requestClose() { _requestClose() }
    // Called by the Ctrl+Enter double tap (AppState.saveAndCloseModal).
    // Same path as the Save button: an empty title is refused and the
    // dialog stays open. The discard prompt is dropped first so it cannot
    // sit over the title error.
    function requestSave() {
        discardConfirm.close()
        _saveSong()
    }

    function _initFresh() {
        _title  = ""
        _author = ""
        _copyright = ""
        _ccli   = ""
        _themeId = 0
        _baseTitle   = ""
        _baseThemeId = 0
        _baseAuthor    = ""
        _baseCopyright = ""
        _baseCcli      = ""
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
        _copyright = song.copyright || ""
        _ccli    = song.ccli || ""
        _themeId = song.themeId || 0
        _baseTitle   = _title
        _baseThemeId = _themeId
        _baseAuthor    = _author
        _baseCopyright = _copyright
        _baseCcli      = _ccli

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
    // Raw mode is RawLyricsEditor, which owns the `[Label]` text format.
    // `_rawText` keeps the DSL form of what it shows (the source of truth
    // for save and view switches). Each entry of `section.lines` is a DSL
    // string, and marks never cross a line, so lines pass through opaque.
    function _refreshRawText() {
        _rawText = rawEditor.serialize(_sections)
        // Push the rebuilt text into the raw editor too, so undo / redo /
        // add / delete / view-toggle all resync it with one call.
        rawEditor.setDsl(_rawText)
    }
    function _parseRawToSections(text) {
        // The text format has no section kinds, so parsed sections are
        // "other", the same as before the editor was shared.
        return rawEditor.parse(text).map(function(s) {
            return { label: s.label, kind: "other", lines: s.lines }
        })
    }
    function _commitRawText(text) {
        const parsed = _parseRawToSections(text)
        // Skip the snapshot when nothing changed (e.g. whitespace-only diffs).
        if (JSON.stringify(_sections) === JSON.stringify(parsed)) return
        _snapshot()
        _sections = parsed
        if (_currentSection >= parsed.length) _currentSection = parsed.length - 1
    }


    function _toggleViewMode() {
        if (_viewMode === "structured") {
            // _refreshRawText also loads the raw editor, so it
            // is staged with current content before we flip visibility.
            _refreshRawText()
            _viewMode = "raw"
            // Straight into the text so Ctrl+M, then typing, just works.
            // Deferred until the raw pane is visible, since a hidden item
            // can't take focus.
            Qt.callLater(function() { rawEditor.focusEditor() })
        } else {
            // Commit any raw edits back into structured form before flipping.
            _commitRawText(_rawText)
            _viewMode = "structured"
        }
        // Remember for the next dialog open. AppState slot is session-only;
        // a SettingsService-backed persistent slot can replace it later.
        AppState.setSongEditorViewMode(_viewMode)
    }

    // End of the header's Enter chain: into the lyrics of whichever view
    // is showing. Structured mode lands in the first section's lyrics, the
    // thing the operator came to type.
    function _focusLyrics() {
        if (_viewMode === "raw") { rawEditor.focusEditor(); return }
        const first = sectionsRepeater.itemAt(0)
        if (first) first.focusLines()
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
            ok = SongService.update(_songId, t, _author.trim(), _ccli.trim(), _themeId,
                                    _sections, _copyright.trim())
        } else {
            const newId = SongService.createWithSections(t, _author.trim(), _ccli.trim(),
                                                         _themeId, _sections, _copyright.trim())
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
        // A slow second Escape while the prompt is up backs out of the
        // prompt. A fast one is the double tap, which discards (AppState).
        if (discardConfirm.visible) { discardConfirm.close(); return }
        if (!_isDirty) { AppState.closeModal(); return }
        // Ask in place. The shared "confirm" modal would replace this
        // dialog (one modal slot), so Cancel there could never bring the
        // edits back.
        discardConfirm.openConfirm()
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

    // Escape is Main.qml's window-level Shortcut, which reaches
    // requestClose() through AppState.modalEscape and also carries the
    // double-tap discard. A Shortcut here would make the key ambiguous.

    // ─── Custom header ──────────────────────────────────────────────────
    Item {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        // Taller header to accommodate the bigger title input row below
        // (row1 stays 44; row2 gets the extra height for a 44-tall input;
        // row3 carries the author / copyright / CCLI credits).
        height: 148

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
            height: 60
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
                    // Enter moves on to the credits, the way it does down
                    // the rest of the header. Saving stays on the Save
                    // button and Ctrl+S, so a half-typed song isn't saved.
                    onAccepted: authorField.focusField()

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

            // View-mode toggle, right side.
            EditorViewToggle {
                id: viewToggleWrap
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                mode: root._viewMode
                onModeRequested: root._toggleViewMode()
            }
        }

        // Row 3 — credits. Imported songs arrive with these filled in;
        // this is where songs typed in by hand get them.
        Row {
            id: headerRow3
            anchors.top: headerRow2.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Theme.space.lg
            anchors.rightMargin: Theme.space.lg
            height: 32
            spacing: Theme.space.sm

            readonly property real _ccliWidth: 200
            readonly property real _flexWidth:
                (width - _ccliWidth - spacing * 2) / 2

            CreditField {
                id: authorField
                width: headerRow3._flexWidth
                caption: qsTr("Author")
                text: root._author
                onEdited: function(t) { root._author = t }
                onAdvance: copyrightField.focusField()
            }
            CreditField {
                id: copyrightField
                width: headerRow3._flexWidth
                caption: qsTr("Copyright")
                text: root._copyright
                onEdited: function(t) { root._copyright = t }
                onAdvance: ccliField.focusField()
            }
            CreditField {
                id: ccliField
                width: headerRow3._ccliWidth
                caption: qsTr("CCLI #")
                text: root._ccli
                // CCLI song numbers are digits only.
                validator: RegularExpressionValidator { regularExpression: /[0-9]*/ }
                onEdited: function(t) { root._ccli = t }
                onAdvance: root._focusLyrics()
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

    // One-line credit input: a muted caption on the left, the value after
    // it. Enter moves on to the next field (advance).
    component CreditField: Rectangle {
        id: credit
        property string caption: ""
        property alias  text: creditInput.text
        property alias  validator: creditInput.validator
        signal edited(string text)
        signal advance()

        function focusField() {
            creditInput.forceActiveFocus()
            creditInput.selectAll()
        }

        height: 32
        radius: 0
        color: Theme.color.canvas
        border.color: creditInput.activeFocus ? Theme.color.brand : Theme.color.borderStrong
        border.width: 1
        Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }

        // The whole box is the field: a click on the caption or the padding
        // focuses the input, which sits above this and keeps its own clicks.
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.IBeamCursor
            onPressed: {
                creditInput.forceActiveFocus()
                creditInput.cursorPosition = creditInput.text.length
            }
        }

        Text {
            id: creditCaption
            anchors.left: parent.left
            anchors.leftMargin: Theme.space.md
            anchors.verticalCenter: parent.verticalCenter
            text: credit.caption
            color: Theme.color.textTertiary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.smallSize
        }
        TextInput {
            id: creditInput
            anchors.left: creditCaption.right
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.leftMargin: Theme.space.sm
            anchors.rightMargin: Theme.space.md
            verticalAlignment: TextInput.AlignVCenter
            clip: true
            color: Theme.color.textPrimary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.bodySize
            selectByMouse: true
            onTextEdited: credit.edited(text)
            onAccepted: credit.advance()
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
                            // Count-only, deliberately NOT `root._sections`. A
                            // Repeater bound to a JS array rebuilds its whole
                            // delegate tree whenever that array is reassigned, and
                            // `_setLines` / `_setLabel` reassign on every keystroke
                            // — so each character destroyed every card and took the
                            // focused TextEdit with it (focus lost, caret back to 0).
                            // Against the length, a content edit only re-evaluates
                            // the two strings below and the card survives, leaving
                            // LyricSectionEditor's `_lastEmittedDsl` guard to absorb
                            // the echo as it was always meant to. Add / delete /
                            // duplicate still change the count and regenerate.
                            model: root._sections.length

                            // Inline wrapper so we can declare `index` as a required
                            // property (Qt 6 idiom) and forward it to
                            // LyricSectionEditor without shadowing the delegate's
                            // own `index`. The section is looked up rather than
                            // injected as `modelData` now that the model is a count;
                            // `|| null` covers the beat during a delete where a
                            // doomed delegate re-evaluates past the shortened end.
                            delegate: Item {
                                id: sectionItem
                                required property int index
                                readonly property var section:
                                    root._sections[sectionItem.index] || null

                                width:  sectionsCol.width
                                height: cardEditor.implicitHeight

                                // Forwarded so `_addSection` can do
                                // `sectionsRepeater.itemAt(i).focusLabel()`
                                // without having to dig through children.
                                function focusLabel() { cardEditor.focusLabel() }
                                function focusLines() { cardEditor.focusLines() }

                                LyricSectionEditor {
                                    id: cardEditor
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    index:     sectionItem.index
                                    label:     (sectionItem.section && sectionItem.section.label) || ""
                                    linesText: (sectionItem.section && sectionItem.section.lines)
                                        ? sectionItem.section.lines.join("\n") : ""
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
                // the raw editor gains focus below) rather than the editor
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

                RawLyricsEditor {
                    id: rawEditor
                    anchors.top: rawToolbar.bottom
                    anchors.topMargin: Theme.space.sm
                    anchors.bottom: parent.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: Theme.space.lg
                    anchors.rightMargin: Theme.space.lg
                    anchors.bottomMargin: Theme.space.lg
                    placeholderText: qsTr("Type lyrics here. Use [Label] on its own "
                            + "line to start a section (e.g. [Verse 1], "
                            + "[Chorus]). Apply bold, italic, underline "
                            + "and color from the toolbar above.")

                    onDslEdited: function(dsl) {
                        root._rawText = dsl
                        root._commitRawText(dsl)
                    }
                    // Set on entry only, so the toolbar keeps its target
                    // when focus moves onto a toolbar button.
                    onActivated: root._focusedLyricEditor = rawEditor.editor
                    // Preview follows the verse the caret is in.
                    onCursorMoved: function(position, plainText) {
                        const idx = rawEditor.sectionAt(position, plainText,
                                                        root._sections.length)
                        if (idx !== root._currentSection) root._currentSection = idx
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

    ConfirmationOverlay {
        id: discardConfirm
        anchors.fill: parent
        title:        qsTr("Discard changes?")
        body:         qsTr("You have unsaved changes to this song. Close without saving?")
        confirmLabel: qsTr("Discard")
        onConfirmed:  AppState.closeModal()
    }

    function qmlWarn(msg) { console.warn(msg) }
}
