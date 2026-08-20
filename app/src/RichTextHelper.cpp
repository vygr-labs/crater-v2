#include "RichTextHelper.h"

#include "crater/LyricsDSL.h"

#include <QBrush>
#include <QClipboard>
#include <QColor>
#include <QFont>
#include <QGuiApplication>
#include <QMimeData>
#include <QQuickItem>
#include <QTextBlock>
#include <QQuickTextDocument>
#include <QTextCharFormat>
#include <QTextCursor>
#include <QTextDocument>
#include <QTextFragment>

namespace crater {

namespace {

// Bundle the QTextDocument + selection range pulled from a QML TextEdit
// item. `valid` is false when the caller passed a non-TextEdit Item (or
// nullptr) — every public method early-returns in that case so QML can't
// crash the app by binding `target:` to the wrong control.
struct EditorAccess
{
    QTextDocument* doc      = nullptr;
    int            selStart = 0;
    int            selEnd   = 0;
    bool           valid    = false;
};

EditorAccess pull(QQuickItem* item)
{
    EditorAccess a;
    if (!item) return a;

    // Qt's QML TextEdit exposes the underlying QTextDocument via the
    // `textDocument` property, typed as QQuickTextDocument* (a thin
    // adapter). Grab it via the property system rather than a static_cast
    // — that way callers can also pass TextField or any other QQuickItem
    // subclass that exposes a textDocument, without us needing to know
    // the concrete type.
    auto qqtd = item->property("textDocument").value<QQuickTextDocument*>();
    if (!qqtd) return a;

    a.doc = qqtd->textDocument();
    if (!a.doc) return a;

    a.selStart = item->property("selectionStart").toInt();
    a.selEnd   = item->property("selectionEnd").toInt();
    a.valid    = true;
    return a;
}

QTextCursor cursorOver(const EditorAccess& a)
{
    QTextCursor c(a.doc);
    c.setPosition(a.selStart);
    c.setPosition(a.selEnd, QTextCursor::KeepAnchor);
    return c;
}

// Build a cursor that's guaranteed to span a non-empty range — used by the
// toolbar mutator paths. Why: our cursor is a FRESH QTextCursor on the
// document (not the editor's internal cursor), so `mergeCharFormat` on a
// zero-width cursor changes the local cursor's format and then the cursor
// dies when our function returns. The editor sees no change. With a
// selection, the format additionally applies to the document range, which
// IS persistent. So when the operator clicks Bold without an explicit
// selection, we widen to "word under cursor" first — Qt's standard
// RichText editor example uses exactly this pattern. Toggling Bold while
// the cursor sits inside a word toggles the whole word, which is what
// every word processor does.
QTextCursor mutatorCursor(const EditorAccess& a)
{
    QTextCursor c = cursorOver(a);
    if (!c.hasSelection()) {
        c.select(QTextCursor::WordUnderCursor);
    }
    return c;
}

}  // namespace

RichTextHelper::RichTextHelper(QObject* parent)
    : QObject(parent)
{}

// ─── Mutators ────────────────────────────────────────────────────────────

void RichTextHelper::toggleBold(QQuickItem* item)
{
    const EditorAccess a = pull(item);
    if (!a.valid) return;
    QTextCursor c = mutatorCursor(a);

    QTextCharFormat fmt;
    const bool currentlyBold = c.charFormat().fontWeight() >= QFont::Bold;
    fmt.setFontWeight(currentlyBold ? QFont::Normal : QFont::Bold);
    c.mergeCharFormat(fmt);
}

void RichTextHelper::toggleItalic(QQuickItem* item)
{
    const EditorAccess a = pull(item);
    if (!a.valid) return;
    QTextCursor c = mutatorCursor(a);

    QTextCharFormat fmt;
    fmt.setFontItalic(!c.charFormat().fontItalic());
    c.mergeCharFormat(fmt);
}

void RichTextHelper::toggleUnderline(QQuickItem* item)
{
    const EditorAccess a = pull(item);
    if (!a.valid) return;
    QTextCursor c = mutatorCursor(a);

    QTextCharFormat fmt;
    fmt.setFontUnderline(!c.charFormat().fontUnderline());
    c.mergeCharFormat(fmt);
}

void RichTextHelper::setSelectionColor(QQuickItem* item, const QString& colorNameOrHex)
{
    const EditorAccess a = pull(item);
    if (!a.valid) return;

    const QString hex = lyrics::resolveColor(colorNameOrHex);
    if (hex.isEmpty()) return;  // unknown color → no-op, don't blank text

    QTextCursor c = mutatorCursor(a);
    QTextCharFormat fmt;
    fmt.setForeground(QColor(hex));
    c.mergeCharFormat(fmt);
}

// ─── State queries ───────────────────────────────────────────────────────

bool RichTextHelper::isBold(QQuickItem* item) const
{
    const EditorAccess a = pull(item);
    if (!a.valid) return false;
    return cursorOver(a).charFormat().fontWeight() >= QFont::Bold;
}

bool RichTextHelper::isItalic(QQuickItem* item) const
{
    const EditorAccess a = pull(item);
    if (!a.valid) return false;
    return cursorOver(a).charFormat().fontItalic();
}

bool RichTextHelper::isUnderline(QQuickItem* item) const
{
    const EditorAccess a = pull(item);
    if (!a.valid) return false;
    return cursorOver(a).charFormat().fontUnderline();
}

QString RichTextHelper::currentColor(QQuickItem* item) const
{
    const EditorAccess a = pull(item);
    if (!a.valid) return QString();
    const QBrush fg = cursorOver(a).charFormat().foreground();
    if (fg.style() == Qt::NoBrush) return QString();
    return fg.color().name();
}

// ─── Paste ───────────────────────────────────────────────────────────────

namespace {

// Insert `text` at the cursor using `fmt`, mapping every newline shape the
// clipboard might carry onto U+2028 LINE SEPARATOR. Why U+2028 and not a
// paragraph break: dslToHtml emits `<br>` between DSL lines, Qt parses that
// to U+2028, and htmlToDsl splits on it. Keeping the whole paste inside one
// QTextBlock therefore round-trips through the DSL unchanged. Inserting
// paragraph breaks instead would still parse, but it would fragment the
// block structure differently from everything the editor writes itself.
void insertRunText(QTextCursor& c, QString text, const QTextCharFormat& fmt)
{
    // CR, LF, CRLF and U+2029 all collapse to one U+2028. Written as
    // explicit code points rather than escapes so the intent is unambiguous
    // when reading the CRLF-folding branch.
    const QChar cr = QChar(0x000D);
    const QChar lf = QChar(0x000A);
    QString out;
    out.reserve(text.size());
    for (int i = 0; i < text.size(); ++i) {
        const QChar ch = text.at(i);
        if (ch == cr) {
            if (i + 1 < text.size() && text.at(i + 1) == lf) ++i;
            out.append(QChar(QChar::LineSeparator));
        } else if (ch == lf || ch == QChar(QChar::ParagraphSeparator)) {
            out.append(QChar(QChar::LineSeparator));
        } else {
            out.append(ch);
        }
    }
    if (out.isEmpty()) return;
    c.insertText(out, fmt);
}

}  // namespace

void RichTextHelper::pasteFiltered(QQuickItem* item, bool keepMarks)
{
    const EditorAccess a = pull(item);
    if (!a.valid) return;

    const QClipboard* clip = QGuiApplication::clipboard();
    if (!clip) return;
    const QMimeData* md = clip->mimeData();
    if (!md) return;

    QTextCursor c = cursorOver(a);

    // The destination's own formatting, which every inserted run inherits.
    // charFormat() reports the format of the character before the cursor, so
    // pasting mid-line adopts the surrounding text and pasting into an empty
    // card falls back to the document default (no explicit foreground — the
    // TextEdit's own `color` property paints it). Either way nothing from the
    // source document's palette survives. Background is cleared outright:
    // it is the single most visible piece of imported page chrome and the
    // DSL has no way to represent it, so it could only ever be noise.
    QTextCharFormat base = c.charFormat();
    base.clearBackground();

    c.beginEditBlock();
    if (c.hasSelection()) c.removeSelectedText();

    if (!keepMarks || !md->hasHtml()) {
        insertRunText(c, md->text(), base);
        c.endEditBlock();
        return;
    }

    // Re-parse the clipboard markup with Qt's own HTML reader, then walk it
    // and re-emit only the three marks the DSL carries. Anything else the
    // source declared — family, size, colors, alignment, list decoration,
    // images — has no representation here and is dropped by construction
    // rather than by an ever-growing blocklist.
    QTextDocument src;
    src.setHtml(md->html());

    bool firstBlock = true;
    for (QTextBlock b = src.firstBlock(); b.isValid(); b = b.next()) {
        // Block boundaries in the source (paragraphs, list rows, table
        // cells) become line breaks here — a lyric is a flat run of lines.
        if (!firstBlock) c.insertText(QString(QChar(QChar::LineSeparator)), base);
        firstBlock = false;

        for (auto it = b.begin(); !it.atEnd(); ++it) {
            const QTextFragment frag = it.fragment();
            if (!frag.isValid()) continue;
            const QString text = frag.text();
            if (text.isEmpty()) continue;

            const QTextCharFormat sf = frag.charFormat();
            QTextCharFormat fmt = base;
            fmt.setFontWeight(sf.fontWeight() >= QFont::Bold ? QFont::Bold
                                                             : QFont::Normal);
            fmt.setFontItalic(sf.fontItalic());
            fmt.setFontUnderline(sf.fontUnderline());
            insertRunText(c, text, fmt);
        }
    }
    c.endEditBlock();
}

}  // namespace crater
