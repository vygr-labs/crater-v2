import QtQuick
import Crater

// Single song section in the structured editor. Mirrors electron's
// LyricEdit.tsx: number gutter on the left with duplicate/delete actions
// (revealed on hover), a flushed label TextInput, and a multi-line
// TextEdit for the lyric body. All mutations bubble up via signals —
// the parent SongEditorDialog owns the actual sections array (so it
// can push undo snapshots before mutating).
//
// We bind directly to `label` and `linesText` rather than to a section
// object so the parent can pass plain strings out of its Repeater
// model. `linesText` is the string-form (DSL lines joined with "\n");
// the parent splits it back into a QStringList before persisting.
//
// Phase 4: the body editor now runs in WYSIWYG mode — `linesEdit`
// uses `textFormat: TextEdit.RichText` and renders DSL formatting
// inline. We bridge between the parent's DSL string and the editor's
// HTML buffer via two helpers in LyricsService (dslToHtml / htmlToDsl).
// The `_lastEmittedDsl` flag breaks the feedback loop: when the parent
// echoes back our own emit, the new linesText equals what we just
// emitted, so we skip the re-init. Without it, every keystroke would
// reset the cursor to the start of the document.
Rectangle {
    id: root

    // ── Inputs ──────────────────────────────────────────────────────────
    property int    index: 0
    property string label: ""
    property string linesText: ""
    property bool   canDelete: true
    // Highlighted when the parent's "current section" pointer points at us.
    // Drives the live-preview update — clicking inside a section makes it
    // the previewed one even though we don't store that fact ourselves.
    property bool   active: false

    // ── Signals ─────────────────────────────────────────────────────────
    signal labelEdited(int idx, string value)
    signal linesEdited(int idx, string value)
    signal focused(int idx)
    signal deleteRequested(int idx)
    signal duplicateRequested(int idx)
    // Emitted when this section's lyric body editor becomes active so the
    // parent dialog can re-target its shared toolbar at this linesEdit.
    // `editor` is the actual TextEdit QQuickItem — RichTextHelper takes
    // it by pointer via the property system.
    signal lyricEditorActivated(int idx, var editor)

    // Forward-edge accessor used by the parent so it can focus the label
    // input of a freshly-added section after the Repeater has built it.
    function focusLabel() { labelInput.forceActiveFocus() }

    // ── WYSIWYG bridging state ──────────────────────────────────────────
    // _settingText: true while we're writing HTML into linesEdit from the
    //   parent's linesText. Suppresses the onTextChanged emit that would
    //   otherwise re-feed the parent its own value.
    // _lastEmittedDsl: the DSL we last emitted via linesEdited. When the
    //   parent's linesText changes back to this same value (the normal
    //   echo cycle), we skip re-init to preserve the cursor position.
    //   When linesText changes to something ELSE (undo/redo, song reload,
    //   section split), we DO re-init.
    property bool   _settingText: false
    property string _lastEmittedDsl: ""

    function _applyDslToEditor(dsl) {
        // Replace the editor buffer with the HTML rendering of `dsl`.
        // The flag suppresses the onTextChanged emit that would otherwise
        // bounce this same value back to the parent and into the undo
        // history. Once HTML is in place, we record the DSL we just
        // settled on so the next echo check has a stable comparator.
        _settingText = true
        linesEdit.text = LyricsService.dslToHtml(dsl || "")
        _settingText = false
        _lastEmittedDsl = dsl || ""
    }

    Component.onCompleted: _applyDslToEditor(root.linesText)
    onLinesTextChanged: {
        // Skip re-init when the incoming value is what we just emitted.
        // That's the parent echoing our own change back; the editor's
        // buffer already reflects it and re-applying would lose the
        // cursor. Other transitions (undo, song reload, section split)
        // produce a different linesText and DO need a re-init.
        if (linesText === _lastEmittedDsl) return
        _applyDslToEditor(linesText)
    }

    // ── Layout ──────────────────────────────────────────────────────────
    implicitHeight: gutter.height
    color: Theme.color.canvas
    // Flat to match the song editor modal's data-app aesthetic — the dialog
    // dropped its rounded chrome and these cards follow suit.
    radius: 0
    border.color: root.active        ? Theme.color.brand
                : hoverArea.containsMouse ? Theme.color.borderStrong
                                          : Theme.color.borderSubtle
    border.width: 1
    clip: true

    Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }

    // Hover proxy — drives `_isHovered` for the action buttons. Sits behind
    // the inputs (z: -1) so it doesn't swallow clicks; hoverEnabled bubbles
    // hover state up while leaving press/click events untouched.
    MouseArea {
        id: hoverArea
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        z: -1
    }

    // Number + action gutter (mirrors electron's left rail)
    Rectangle {
        id: gutter
        anchors.left: parent.left
        anchors.top: parent.top
        width: 36
        height: Math.max(64, fieldsCol.implicitHeight + Theme.space.md * 2)
        color: Theme.color.raised
        radius: parent.radius
        // Right-edge is a vertical divider, not a rounded corner — flatten it.
        Rectangle {
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 1
            color: Theme.color.borderSubtle
        }

        Text {
            anchors.top: parent.top
            anchors.topMargin: Theme.space.sm
            anchors.horizontalCenter: parent.horizontalCenter
            text: (root.index + 1).toString()
            color: Theme.color.textTertiary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.smallSize
            font.weight: Theme.font.weightSemiBold
        }

        Column {
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Theme.space.sm
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 2
            opacity: hoverArea.containsMouse ? 1.0 : 0.0
            Behavior on opacity { NumberAnimation { duration: Theme.motion.instant } }

            IconButton {
                iconName: "copy"
                iconSize: Theme.icon.sm
                onClicked: root.duplicateRequested(root.index)
            }
            IconButton {
                visible: root.canDelete
                iconName: "trash"
                iconSize: Theme.icon.sm
                tint: Theme.color.live          // red affordance for destructive
                tintHover: Qt.lighter(Theme.color.live, 1.12)
                onClicked: root.deleteRequested(root.index)
            }
        }
    }

    // Body — label + lyric textarea, stacked
    Column {
        id: fieldsCol
        anchors.left: gutter.right
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.leftMargin: Theme.space.sm
        anchors.rightMargin: Theme.space.sm
        anchors.topMargin: Theme.space.sm
        spacing: Theme.space.xs

        // Label input — flushed (no fill, just bottom-border hover treatment)
        Rectangle {
            id: labelWrap
            width: parent.width
            height: 28
            radius: 0
            color: labelInput.activeFocus ? Theme.color.raised : "transparent"
            border.color: labelInput.activeFocus ? Theme.color.brand : "transparent"
            border.width: 1

            Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
            Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }

            TextInput {
                id: labelInput
                anchors.fill: parent
                anchors.leftMargin: Theme.space.sm
                anchors.rightMargin: Theme.space.sm
                verticalAlignment: TextInput.AlignVCenter
                color: Theme.color.textPrimary
                font.family: Theme.font.family
                // bodySize matches the song-title input and the rest of the
                // app's primary text controls. smallSize made the section
                // label feel like UI chrome instead of an editable field.
                font.pixelSize: Theme.font.bodySize
                font.weight: Theme.font.weightMedium
                selectByMouse: true
                text: root.label
                onTextEdited: root.labelEdited(root.index, text)
                onActiveFocusChanged: if (activeFocus) root.focused(root.index)

                // Placeholder
                Text {
                    visible: labelInput.text.length === 0 && !labelInput.activeFocus
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Section label (e.g., Verse 1, Chorus)")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize
                }
            }
        }

        // Phase 7+: formatting toolbar is no longer per-section. The
        // SongEditorDialog hosts a single shared toolbar at the top of
        // the structured pane, retargeted to whichever linesEdit has
        // focus via the `lyricEditorActivated` signal below.

        // Lyric textarea — multi-line WYSIWYG editor. Renders DSL
        // formatting (bold/italic/underline/color) inline as the operator
        // types or via the toolbar above. The text on the wire (between
        // editor and parent) stays in DSL form — see _applyDslToEditor
        // and the onTextChanged handler below.
        Rectangle {
            id: linesWrap
            width: parent.width
            // Implicit height tracks the TextEdit's content height — matches
            // electron's `autoresize` Textarea. Floor at ~3 line-heights so a
            // brand-new empty section is comfortable to click into.
            height: Math.max(60, linesEdit.contentHeight + Theme.space.sm * 2)
            radius: 0
            color: linesEdit.activeFocus ? Theme.color.raised : "transparent"
            border.color: linesEdit.activeFocus ? Theme.color.brand : "transparent"
            border.width: 1

            Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
            Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }

            TextEdit {
                id: linesEdit
                anchors.fill: parent
                anchors.margins: Theme.space.sm
                // RichText so inline <b>/<i>/<u>/<span style="color:…">
                // tags from LyricsService.dslToHtml render as WYSIWYG.
                // The Run.text values come through with the proper marks
                // baked into the document's QTextCharFormats.
                textFormat: TextEdit.RichText
                color: Theme.color.textPrimary
                font.family: Theme.font.family
                // bodySize — matches the title input above and the raw-mode
                // textarea, so the operator's typing experience is uniform
                // across the editor.
                font.pixelSize: Theme.font.bodySize
                selectByMouse: true
                wrapMode: TextEdit.Wrap
                onTextChanged: {
                    // Skip echoes from our own _applyDslToEditor() writes.
                    if (root._settingText) return
                    const dsl = LyricsService.htmlToDsl(text)
                    if (dsl !== root._lastEmittedDsl) {
                        root._lastEmittedDsl = dsl
                        root.linesEdited(root.index, dsl)
                    }
                }
                onActiveFocusChanged: {
                    if (activeFocus) {
                        root.focused(root.index)
                        // Tell the parent dialog which TextEdit to re-target
                        // the shared toolbar at. Carries `linesEdit` as the
                        // actual QQuickItem so RichTextHelper can pull
                        // textDocument + selection state from it.
                        root.lyricEditorActivated(root.index, linesEdit)
                    }
                }

                // Placeholder — TextEdit doesn't ship one, so we overlay
                // a Text when empty + unfocused. Use `length` (plain-text
                // char count) not `text.length` — the latter is the size
                // of the HTML buffer and is never 0 in RichText mode.
                Text {
                    visible: linesEdit.length === 0 && !linesEdit.activeFocus
                    anchors.left: parent.left
                    anchors.top: parent.top
                    text: qsTr("Enter lyrics here…")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize
                }
            }
        }

        // Bottom padding inside the card.
        Item { width: parent.width; height: Theme.space.sm }
    }
}
