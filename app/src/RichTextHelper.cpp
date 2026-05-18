#include "RichTextHelper.h"

#include "crater/LyricsDSL.h"

#include <QBrush>
#include <QColor>
#include <QFont>
#include <QQuickItem>
#include <QQuickTextDocument>
#include <QTextCharFormat>
#include <QTextCursor>
#include <QTextDocument>

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

}  // namespace crater
