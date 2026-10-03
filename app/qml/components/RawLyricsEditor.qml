import QtQuick
import Crater

// Freeform lyrics editor: one scrolling WYSIWYG text box where `[Label]` on
// its own line starts a section and a blank line ends one. Shared by the
// song editor's "Raw text" mode and the schedule item editor, so typing or
// pasting a whole song works the same in both.
//
// The text on the wire is DSL (see LyricsDSL.h). setDsl() loads it, and
// dslEdited fires with the new DSL on every real edit. Formatting renders
// inline, so cursor positions are in plain-text space, not DSL space; that
// is why cursorMoved hands over the editor's plain text alongside the
// position.
//
// The parse / serialize helpers are plain functions over
// `{ label, lines: [] }` sections so each dialog can map them onto its own
// shape (song sections, schedule pages).
Rectangle {
    id: root

    property string placeholderText: ""
    // The TextEdit itself, for the shared LyricsToolbar's `target`.
    readonly property alias editor: rawArea

    signal dslEdited(string dsl)
    signal cursorMoved(int position, string plainText)
    signal activated()

    // ── DSL bridge ──────────────────────────────────────────────────────
    // Same echo guard as LyricSectionEditor: writing HTML into the editor
    // fires onTextChanged, which must not come back out as an edit.
    property bool   _settingText: false
    property string _lastEmittedDsl: ""

    function setDsl(dsl) {
        _settingText = true
        rawArea.text = LyricsService.dslToHtml(dsl || "")
        _settingText = false
        _lastEmittedDsl = dsl || ""
    }

    function focusEditor() { rawArea.forceActiveFocus() }

    // ── Sections <-> text ───────────────────────────────────────────────
    // Lines are opaque DSL strings. Marks never cross a line boundary, so
    // joining and splitting lines needs no DSL parsing.
    function serialize(sections) {
        let parts = []
        for (let i = 0; i < (sections || []).length; i++) {
            const s = sections[i] || {}
            const body = (s.lines || []).join("\n")
            parts.push(s.label ? ("[" + s.label + "]\n" + body) : body)
        }
        return parts.join("\n\n")
    }

    // A `[Label]` line opens a section, a blank line closes one, and text
    // before any label lands in an unlabelled section. Always returns at
    // least one section, each with at least one (possibly empty) line.
    function parse(text) {
        const lines = String(text || "").split("\n")
        let out = []
        let current = null
        for (let i = 0; i < lines.length; i++) {
            const line = lines[i]
            const trimmed = line.trim()
            const labelMatch = trimmed.match(/^\[(.*)\]$/)
            if (labelMatch) {
                current = { label: labelMatch[1], lines: [] }
                out.push(current)
            } else if (trimmed.length > 0) {
                if (!current) {
                    current = { label: "", lines: [] }
                    out.push(current)
                }
                current.lines.push(line)
            } else {
                current = null
            }
        }
        if (out.length === 0) out.push({ label: "", lines: [""] })
        for (let j = 0; j < out.length; j++)
            if (out[j].lines.length === 0) out[j].lines = [""]
        return out
    }

    // Index of the section holding `position`, walking the same rules as
    // parse() up to the end of the cursor's line. Clamped to [0, count).
    function sectionAt(position, text, count) {
        if (!text || position < 0) return 0
        // getText() reports the editor's line breaks as U+2028 (how Qt
        // stores <br>) or U+2029, never "\n". Swapping one character for
        // one keeps `position` lined up with the text.
        // Built with fromCharCode: U+2028 counts as a line terminator in JS
        // source, so it can't sit inside a regex literal.
        text = text.split(String.fromCharCode(0x2028)).join("\n")
                   .split(String.fromCharCode(0x2029)).join("\n")
        let endOfLine = text.indexOf("\n", position)
        if (endOfLine < 0) endOfLine = text.length
        const lines = text.substring(0, endOfLine).split("\n")
        let idx = -1
        let inSection = false
        for (let i = 0; i < lines.length; i++) {
            const trimmed = lines[i].trim()
            if (/^\[(.*)\]$/.test(trimmed)) {
                idx++
                inSection = true
            } else if (trimmed.length > 0) {
                if (!inSection) { idx++; inSection = true }
            } else {
                inSection = false
            }
        }
        return Math.max(0, Math.min(idx, count - 1))
    }

    // ── Layout ──────────────────────────────────────────────────────────
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

        // Keep the caret on screen while typing or arrowing past the fold.
        function revealCursor() {
            if (!rawArea.activeFocus) return
            const r = rawArea.cursorRectangle
            const pad = Theme.space.lg
            const maxY = Math.max(0, contentHeight - height)
            if (r.y - pad < contentY)
                contentY = Math.max(0, r.y - pad)
            else if (r.y + r.height + pad > contentY + height)
                contentY = Math.min(maxY, r.y + r.height + pad - height)
        }

        TextEdit {
            id: rawArea
            width: rawScroll.width
            // Fill the viewport so a click below the last line still lands
            // in the editor (and snaps the caret to the end) instead of on
            // dead background.
            height: Math.max(contentHeight, rawScroll.height)
            textFormat: TextEdit.RichText
            color: Theme.color.textPrimary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.bodySize
            selectByMouse: true
            wrapMode: TextEdit.Wrap

            onTextChanged: {
                if (root._settingText) return
                const dsl = LyricsService.htmlToDsl(text)
                if (dsl !== root._lastEmittedDsl) {
                    root._lastEmittedDsl = dsl
                    root.dslEdited(dsl)
                    // The caret moved before this edit was committed, so the
                    // host mapped it against the old section count. Typing
                    // a new [Label] block would leave the preview a section
                    // behind; report it again now the sections are current.
                    if (activeFocus)
                        root.cursorMoved(cursorPosition, rawArea.getText(0, rawArea.length))
                }
            }
            // Ctrl+V / Ctrl+Shift+V go through RichTextHelper so a page's
            // background, colours and fonts stay behind. Shift pastes plain
            // text. See RichTextHelper::pasteFiltered.
            Keys.onPressed: function(event) {
                if (event.key === Qt.Key_V
                    && (event.modifiers & Qt.ControlModifier)) {
                    RichTextHelper.pasteFiltered(
                        rawArea, !(event.modifiers & Qt.ShiftModifier))
                    event.accepted = true
                }
            }
            onActiveFocusChanged: if (activeFocus) root.activated()
            onCursorPositionChanged: {
                if (!activeFocus) return
                root.cursorMoved(cursorPosition, rawArea.getText(0, rawArea.length))
            }
            // Deferred so a newline that grows the text has updated
            // contentHeight before the clamp reads it.
            onCursorRectangleChanged: Qt.callLater(rawScroll.revealCursor)

            Text {
                // `length` is the plain-text count. In RichText mode `text`
                // is never empty, even for an empty document.
                visible: rawArea.length === 0 && !rawArea.activeFocus
                anchors.left: parent.left
                anchors.top: parent.top
                width: rawArea.width
                text: root.placeholderText
                color: Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize
                wrapMode: Text.WordWrap
            }
        }
    }
}
