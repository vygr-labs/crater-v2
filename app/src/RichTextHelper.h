#pragma once

#include <QObject>
#include <QString>

class QQuickItem;

namespace crater {

// QML-callable helper that bridges the song editor's formatting toolbar
// to Qt's QTextCursor / QTextCharFormat APIs. Each method takes a target
// QQuickItem (the live `TextEdit { textFormat: RichText }` instance) and
// applies its operation to whatever's currently selected — or to the
// cursor position if there's no selection, in which case the next typed
// character inherits the new format.
//
// Why this lives in the app target (not crater-core):
//   - It depends on QQuickItem + QQuickTextDocument (Qt6::Quick).
//   - ARCHITECTURE.md §1 forbids crater-core from linking Qt6::Quick.
// Same justification as FileDialogService — UI glue belongs in app.
//
// Registered in app/src/main.cpp as a QML singleton under the `Crater`
// URI, so the toolbar calls `RichTextHelper.toggleBold(linesEdit)` etc.
//
// All methods are stateless and reentrant. The helper holds no live
// reference to the target — every call reads `textDocument`,
// `selectionStart`, and `selectionEnd` fresh from the item, so multiple
// toolbars driving different editors compose cleanly.
class RichTextHelper : public QObject
{
    Q_OBJECT

public:
    explicit RichTextHelper(QObject* parent = nullptr);

    // ─── Mutators ─────────────────────────────────────────────────────
    // Toggle the named mark on the current selection. Toggle direction
    // is decided by the format at the anchor (selection start): if the
    // anchor is currently bold, the toggle removes bold from the whole
    // selection. For mixed selections this is consistent with how every
    // mainstream word processor behaves.
    Q_INVOKABLE void toggleBold(QQuickItem* textEdit);
    Q_INVOKABLE void toggleItalic(QQuickItem* textEdit);
    Q_INVOKABLE void toggleUnderline(QQuickItem* textEdit);

    // Apply a foreground color to the current selection. `colorNameOrHex`
    // accepts a named color from the lyrics palette ("red", "blue", …)
    // or a hex code ("#c33", "#ff0000"). Unknown values are no-ops so
    // accidental swatch lookups can't blank the operator's text.
    //
    // No "clear color" operation in v1 — QTextCharFormat::mergeCharFormat
    // is additive and can't easily un-set a property. Workaround: re-type
    // the text or apply white (the default theme text color).
    Q_INVOKABLE void setSelectionColor(QQuickItem* textEdit,
                                       const QString& colorNameOrHex);

    // ─── State queries ────────────────────────────────────────────────
    // Returns the format state at the anchor of the current selection.
    // The toolbar reads these to drive button highlight states. They're
    // const so multiple toolbars can poll on cursor/selection changes
    // without racing.
    Q_INVOKABLE bool    isBold     (QQuickItem* textEdit) const;
    Q_INVOKABLE bool    isItalic   (QQuickItem* textEdit) const;
    Q_INVOKABLE bool    isUnderline(QQuickItem* textEdit) const;

    // Returns the current foreground color as "#rrggbb", or "" if no
    // explicit color is set (i.e. inheriting from the document default).
    Q_INVOKABLE QString currentColor(QQuickItem* textEdit) const;

    // ─── Paste ────────────────────────────────────────────────────────
    // Replace the selection with the clipboard's contents, filtered down
    // to what a lyric can actually carry.
    //
    // TextEdit's built-in Ctrl+V hands the clipboard's text/html straight
    // to QTextDocument, which faithfully reproduces every declaration the
    // source page carried — background-color, font-family, font-size,
    // foreground color, margins. Copying a verse off a lyrics site
    // therefore dropped a slab of white page background into a dark
    // editor, and baked the site's grey body color into the DSL as an
    // explicit {color=#…} run that then overrode the theme on the
    // projector.
    //
    // This path rebuilds the pasted text run by run instead. It carries
    // over ONLY bold / italic / underline (the marks the DSL supports and
    // the ones a Crater-to-Crater copy is meant to keep) and re-applies
    // the destination's own char format to everything else, so pasted
    // text arrives looking like the text already in the card. Newlines
    // land as U+2028 line separators — the same shape dslToHtml's <br>
    // parses to — so htmlToDsl reads them back as DSL line breaks.
    //
    // keepMarks=false is the "paste without formatting" variant bound to
    // Ctrl+Shift+V: plain text, destination format, nothing else.
    Q_INVOKABLE void pasteFiltered(QQuickItem* textEdit, bool keepMarks = true);
};

}  // namespace crater
