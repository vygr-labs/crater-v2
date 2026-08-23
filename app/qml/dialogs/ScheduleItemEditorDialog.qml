import QtQuick
import QtQuick.Controls.Basic
import Crater

// Schedule item editor — edits ONE schedule row's own copy of its slides.
//
// This is the "temporary edit" surface: retime a song for this Sunday, or
// highlight the clause the sermon turns on, without rewriting the library
// record every future service inherits. It is the schedule-row analogue of
// SongEditorDialog (which edits the library song) and it deliberately
// reuses that dialog's editing machinery — LyricSectionEditor for the
// WYSIWYG body and the shared LyricsToolbar for B / I / U + the seven
// palette colors. Highlighting a phrase in a verse is exactly "select it,
// press a swatch": the toolbar writes {color=...} markers into the page's
// DSL, and every surface that renders a page (projection, the Preview /
// Live monitors, the page cards) already feeds content through
// LyricsService.dslToHtml — so a highlight made here needs no render-side
// work to reach the projector.
//
// ── Why edits stay on the row ────────────────────────────────────────────
// Schedule rows carry a *snapshot* of their source's content (a song row
// holds its lyrics inline — see ScheduleService.h), so a row can legally
// diverge from the library. Saving stamps `contentOverride` on the row,
// which tells AppState._songContentMerged to stop overwriting this row's
// pages when the library song changes. That mirrors the `titleOverride`
// flag renameScheduleItem already sets for the same reason.
//
// Scripture rows had no editor at all before this — "Edit…" only revealed
// the passage back in the Scripture tab. They edit here like any other
// text row; the verse text still comes from the immutable Bible DB, this
// only marks up the row's copy of it.
//
// ── Reset ────────────────────────────────────────────────────────────────
// The pre-edit pages are stashed on the row as `sourcePages` the first
// time it is saved, so "Reset to source" is a restore rather than a
// re-derivation. That matters for scripture: rebuilding a passage means
// re-running ScriptureTab's verse-numbering / highlight-mode composition,
// which lives in the tab and would have to be duplicated here. It also
// keeps Reset working when the library song has since been deleted.
//
// Not here yet: cross-field undo/redo (the body fields keep their own
// native undo; Reset and Cancel cover the rest).
ModalShell {
    id: root

    dialogWidth:  1000
    dialogHeight: 700

    // Own header, so the title input and the kind chip share one toolbar
    // row — same reasoning as SongEditorDialog.
    showHeader: false

    // ── Identity ────────────────────────────────────────────────────────
    readonly property int _index:
        (AppState.modalProps && typeof AppState.modalProps.itemIndex === "number")
            ? AppState.modalProps.itemIndex
            : -1

    // A snapshot taken once on load, NOT a live binding on
    // ScheduleService.currentItems. The schedule auto-saves every 5s and a
    // library edit rewrites song rows in place, either of which would swap
    // the row out from under an open editor and discard what was typed.
    property var _item: null

    readonly property string _kind: (root._item && root._item.kind) || ""
    readonly property bool _isSong: root._kind === "song"

    // ── Working state ───────────────────────────────────────────────────
    property string _title: ""
    property var    _pages: [{ label: "", content: "" }]
    property int    _currentPage: 0
    property bool   _isLoading: true
    property string _saveError: ""

    // Last body TextEdit to take focus, so the one shared toolbar always
    // formats whichever card the operator is typing in. Same contract as
    // SongEditorDialog._focusedLyricEditor.
    property var _focusedLyricEditor: null

    // Content digest of the row as it was opened. Drives the dirty check
    // and therefore the close confirmation.
    property string _baseline: ""

    function _clone(pages) {
        // JSON round-trip — the payload is a handful of short strings.
        return JSON.parse(JSON.stringify(pages || []))
    }

    // Order-stable digest. Built over an ARRAY rather than the maps so a
    // row that has been through C++ (alphabetically keyed QVariantMap)
    // digests the same as one built here in literal key order — the same
    // trap AppState._itemContentDigest documents.
    function _digest(title, pages) {
        let flat = []
        for (let i = 0; i < (pages || []).length; i++) {
            const p = pages[i] || {}
            flat.push([p.label || "", p.content || ""])
        }
        return JSON.stringify([title || "", flat])
    }

    readonly property bool _isDirty:
        !root._isLoading && root._digest(root._title, root._pages) !== root._baseline

    // ── Load ────────────────────────────────────────────────────────────
    Component.onCompleted: {
        const items = ScheduleService.currentItems
        if (root._index < 0 || root._index >= items.length) {
            // Nothing to edit — the row went away between opening the menu
            // and the dialog instantiating. Close rather than show an
            // editor bound to nothing.
            AppState.closeModal()
            return
        }
        const it = items[root._index]
        root._item = it

        let pages = root._clone(it.pages || [])
        if (pages.length === 0) pages = [{ label: "", content: "" }]
        root._pages = pages
        root._title = it.title || ""
        root._baseline = root._digest(root._title, root._pages)
        root._isLoading = false
        titleInput.text = root._title
    }

    // ── Mutators ────────────────────────────────────────────────────────
    // Each guards on "did anything actually change" before reassigning, so
    // an echo from the editor does not churn the array (and, through it,
    // the preview binding) on every keystroke.
    function _setLabel(idx, value) {
        if (idx < 0 || idx >= root._pages.length) return
        const v = String(value === undefined || value === null ? "" : value)
        if ((root._pages[idx].label || "") === v) return
        let next = root._clone(root._pages)
        next[idx].label = v
        root._pages = next
    }

    function _setContent(idx, value) {
        if (idx < 0 || idx >= root._pages.length) return
        const v = String(value === undefined || value === null ? "" : value)
        if ((root._pages[idx].content || "") === v) return
        let next = root._clone(root._pages)
        next[idx].content = v
        root._pages = next
    }

    function _addPage() {
        let next = root._clone(root._pages)
        next.push({ label: "", content: "" })
        root._pages = next
        root._currentPage = next.length - 1
    }

    function _deletePage(idx) {
        if (root._pages.length <= 1) return          // never leave a row slideless
        if (idx < 0 || idx >= root._pages.length) return
        let next = root._clone(root._pages)
        next.splice(idx, 1)
        root._pages = next
        if (root._currentPage >= next.length)
            root._currentPage = next.length - 1
    }

    function _duplicatePage(idx) {
        if (idx < 0 || idx >= root._pages.length) return
        let next = root._clone(root._pages)
        next.splice(idx + 1, 0, {
            label:   next[idx].label   || "",
            content: next[idx].content || ""
        })
        root._pages = next
        root._currentPage = idx + 1
    }

    // ── Reset ───────────────────────────────────────────────────────────
    // Restores the stash written on the first save. Before any save the row
    // still holds its original pages, so the stash is simply absent and the
    // row's own pages already are the source.
    readonly property bool _canReset: {
        if (!root._item) return false
        const src = root._item.sourcePages
        return !!(src && src.length > 0)
    }

    function _resetToSource() {
        if (!root._canReset) return
        let pages = root._clone(root._item.sourcePages)
        if (pages.length === 0) return
        root._pages = pages
        root._currentPage = 0
    }

    // ── Save ────────────────────────────────────────────────────────────
    // Builds the replacement row. `stampOverride` false is the
    // save-to-library path: the row's content now matches the library
    // again, so the override is cleared and the row re-links to its source.
    function _buildRow(stampOverride) {
        let next = {}
        for (const k in root._item) next[k] = root._item[k]

        const trimmed = String(root._title || "").trim()
        if (trimmed.length > 0 && trimmed !== (root._item.title || "")) {
            next.title = trimmed
            // Same reasoning as renameScheduleItem: a retitled row must not
            // have the library name restored under it on the next refresh.
            next.titleOverride = true
        }
        next.pages = root._clone(root._pages)

        if (stampOverride) {
            // Stash the pre-edit pages once, so Reset has something to go
            // back to no matter how many times the row is re-edited.
            if (!next.sourcePages || next.sourcePages.length === 0)
                next.sourcePages = root._clone(root._item.pages || [])
            next.contentOverride = true
        } else {
            delete next.contentOverride
            delete next.sourcePages
        }
        return next
    }

    function _save() {
        if (root._index < 0) { AppState.closeModal(); return }
        ScheduleService.replaceItem(root._index, root._buildRow(true))
        AppState.closeModal()
    }

    // Push the edited slides back onto the library song, then re-link the
    // row. Song rows only — scripture text belongs to the translation and
    // has no writable source.
    function _saveToLibrary() {
        if (!root._isSong) return
        const songId = Number((root._item && root._item.songId) || 0)
        if (songId <= 0) {
            root._saveError = qsTr("This row has no library song.")
            saveErrorTimer.restart()
            return
        }

        const fresh = SongService.fetchSong(songId)
        if (!fresh || !fresh.id) {
            root._saveError = qsTr("That song is no longer in the library.")
            saveErrorTimer.restart()
            return
        }

        // Schedule pages carry only label + content, so rebuilding sections
        // blind would flatten every verse / chorus to "other". Carry each
        // section's kind across by position, defaulting only for pages that
        // have no counterpart (ones added here).
        const prior = fresh.sections || []
        let sections = []
        for (let i = 0; i < root._pages.length; i++) {
            const p = root._pages[i] || {}
            sections.push({
                label: p.label || "",
                kind:  (i < prior.length && prior[i].kind) ? prior[i].kind : "other",
                lines: String(p.content || "").split("\n")
            })
        }

        const ok = SongService.update(songId, fresh.title, fresh.author,
                                      fresh.ccli, fresh.themeId || 0, sections)
        if (!ok) {
            console.warn("ScheduleItemEditorDialog: library save failed"
                       + " songId=" + songId + " pages=" + root._pages.length)
            root._saveError = qsTr("Could not save to the library. See log for details.")
            saveErrorTimer.restart()
            return
        }

        // Clear the override so this row follows the library again. The
        // allSongsChanged -> refreshStagedSong pass that SongService.update
        // triggers rebuilds the row from the very text just written, so the
        // row's content is unchanged by the round trip.
        ScheduleService.replaceItem(root._index, root._buildRow(false))
        AppState.closeModal()
    }

    Timer {
        id: saveErrorTimer
        interval: 5000
        onTriggered: root._saveError = ""
    }

    function _requestClose() {
        if (!root._isDirty) { AppState.closeModal(); return }
        // The confirm dialog replaces this one, taking our state with it —
        // so the discard branch has nothing left to do but close.
        AppState.openModal("confirm", {
            title:       qsTr("Discard changes?"),
            body:        qsTr("This item has unsaved edits. Closing will lose them."),
            confirmText: qsTr("Discard"),
            onConfirm:   function() { AppState.closeModal() }
        })
    }

    // ── Synthetic preview item ──────────────────────────────────────────
    // ThemedMonitor wants a canonical schedule-item shape. Rebuilt from the
    // live editor state so the monitor shows the highlight as the projector
    // will render it — the whole point of editing here rather than in a
    // plain text box.
    readonly property var _previewItem: {
        if (!root._item) return null
        let it = {}
        for (const k in root._item) it[k] = root._item[k]
        it.title = root._title || root._item.title || ""
        it.pages = root._pages
        return it
    }
    readonly property int _previewPage:
        Math.max(0, Math.min(root._currentPage, root._pages.length - 1))

    // ── Header ──────────────────────────────────────────────────────────
    Item {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 60

        Row {
            anchors.left: parent.left
            anchors.leftMargin: Theme.space.lg
            anchors.right: headerActions.left
            anchors.rightMargin: Theme.space.sm
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.space.sm

            AppIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: Theme.scheduleKindIcon(root._kind)
                color: Theme.color.textTertiary
                size: Theme.icon.md
            }

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: titleInput.width + Theme.space.md * 2
                height: 34
                radius: Theme.radius.sm
                color: titleInput.activeFocus ? Theme.color.raised : "transparent"
                border.color: titleInput.activeFocus ? Theme.color.brand
                                                     : Theme.color.borderSubtle
                border.width: 1

                TextInput {
                    id: titleInput
                    anchors.centerIn: parent
                    width: 360
                    clip: true
                    color: Theme.color.textPrimary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.titleSize
                    font.weight: Theme.font.weightSemiBold
                    selectByMouse: true
                    selectionColor: Theme.color.brandSubtle
                    // One-way on purpose: binding `text` to _title would
                    // fight the caret on every keystroke. Seeded once in
                    // Component.onCompleted.
                    onTextChanged: root._title = text
                }
            }
        }

        Row {
            id: headerActions
            anchors.right: parent.right
            anchors.rightMargin: Theme.space.lg
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.space.sm

            GhostButton {
                text: qsTr("Reset to source")
                enabled: root._canReset
                onClicked: root._resetToSource()
            }
        }
    }

    Rectangle {
        id: headerRule
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 1
        color: Theme.color.borderSubtle
    }

    // ── Body ────────────────────────────────────────────────────────────
    Item {
        id: body
        anchors.top: headerRule.bottom
        anchors.bottom: footer.top
        anchors.left: parent.left
        anchors.right: parent.right

        // Left — slide cards
        Item {
            id: editorPane
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            width: parent.width * 0.58

            LyricsToolbar {
                id: toolbar
                target: root._focusedLyricEditor
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Theme.space.lg
                anchors.rightMargin: Theme.space.md
                anchors.topMargin: Theme.space.sm
            }

            Flickable {
                id: pagesScroll
                anchors.top: toolbar.bottom
                anchors.topMargin: Theme.space.sm
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Theme.space.lg
                anchors.rightMargin: Theme.space.md
                anchors.bottomMargin: Theme.space.lg
                contentWidth:  pagesCol.width
                contentHeight: pagesCol.height
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                Column {
                    id: pagesCol
                    width: pagesScroll.width
                    spacing: Theme.space.sm

                    Repeater {
                        id: pagesRepeater
                        // Count-only, deliberately NOT `root._pages`. A
                        // Repeater bound to a JS array tears down and
                        // rebuilds every delegate whenever that array is
                        // reassigned — and _setContent reassigns on each
                        // keystroke, which would destroy the card holding
                        // the focused TextEdit (focus lost, caret to 0).
                        // Against the length, a content edit only
                        // re-evaluates the two strings below, the card
                        // survives, and LyricSectionEditor's
                        // _lastEmittedDsl guard absorbs the echo. Add /
                        // delete / duplicate change the count and do
                        // regenerate, which is correct.
                        model: root._pages.length

                        delegate: Item {
                            id: pageItem
                            required property int index
                            // Looked up rather than injected as modelData
                            // now the model is a count; `|| null` covers
                            // the beat during a delete where a doomed
                            // delegate re-evaluates past the new end.
                            readonly property var page:
                                root._pages[pageItem.index] || null

                            width:  pagesCol.width
                            height: cardEditor.implicitHeight

                            LyricSectionEditor {
                                id: cardEditor
                                anchors.left: parent.left
                                anchors.right: parent.right
                                index:     pageItem.index
                                label:     (pageItem.page && pageItem.page.label) || ""
                                linesText: (pageItem.page && pageItem.page.content) || ""
                                canDelete: root._pages.length > 1
                                active:    root._currentPage === pageItem.index

                                onLabelEdited: function(idx, value) { root._setLabel(idx, value) }
                                onLinesEdited: function(idx, value) { root._setContent(idx, value) }
                                onFocused:     function(idx)        { root._currentPage = idx }
                                onDeleteRequested:    function(idx) { root._deletePage(idx) }
                                onDuplicateRequested: function(idx) { root._duplicatePage(idx) }
                                onLyricEditorActivated: function(idx, editor) {
                                    root._focusedLyricEditor = editor
                                }
                            }
                        }
                    }

                    // Add slide — ghost row matching the song editor's
                    // "Add section" affordance.
                    Rectangle {
                        width: pagesCol.width
                        height: 40
                        radius: Theme.radius.sm
                        color: addMa.containsMouse ? Theme.color.overlay : "transparent"
                        border.color: Theme.color.borderSubtle
                        border.width: 1

                        Row {
                            anchors.centerIn: parent
                            spacing: Theme.space.xs
                            AppIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                name: "plus"
                                color: Theme.color.textTertiary
                                size: Theme.icon.sm
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: qsTr("Add slide")
                                color: Theme.color.textTertiary
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.bodySize
                            }
                        }

                        MouseArea {
                            id: addMa
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: root._addPage()
                        }
                    }
                }
            }
        }

        // Right — live preview
        Item {
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.left: editorPane.right
            anchors.right: parent.right
            anchors.topMargin: Theme.space.md
            anchors.rightMargin: Theme.space.lg
            anchors.bottomMargin: Theme.space.lg
            anchors.leftMargin: Theme.space.sm

            Column {
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                spacing: Theme.space.sm

                Rectangle {
                    width: parent.width
                    height: width * 9 / 16
                    // Pure black + borderStrong mirrors SongEditorDialog's
                    // preview well, so both editors letterbox identically.
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

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: root._pages.length > 1
                    text: {
                        const p = root._pages[root._currentPage]
                        const l = (p && p.label) ? String(p.label) : ""
                        return l.length > 0
                            ? qsTr("Previewing: %1").arg(l)
                            : qsTr("Previewing slide %1").arg(root._currentPage + 1)
                    }
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                }

                Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    horizontalAlignment: Text.AlignHCenter
                    text: root._isSong
                        ? qsTr("Edits stay on this schedule item. Use Save to Library to update the song everywhere.")
                        : qsTr("Edits stay on this schedule item. The passage itself is unchanged.")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                }
            }
        }
    }

    // ── Footer ──────────────────────────────────────────────────────────
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
            GhostButton {
                visible: root._isSong
                text: qsTr("Save to Library")
                enabled: Number((root._item && root._item.songId) || 0) > 0
                onClicked: root._saveToLibrary()
            }
            PrimaryButton {
                variant: "brand"
                text: qsTr("Save to Schedule")
                onClicked: root._save()
            }
        }
    }

    // Ctrl+S saves the row — the gesture an operator already has in the
    // song editor. Formatting shortcuts (Ctrl+B/I/U) are handled by
    // LyricSectionEditor on the focused body field.
    Shortcut {
        sequence: StandardKey.Save
        onActivated: root._save()
    }
}
