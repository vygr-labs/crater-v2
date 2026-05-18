#include "crater/LyricsDSL.h"

#include <QChar>
#include <QHash>
#include <QStringView>
#include <QTextBlock>
#include <QTextCharFormat>
#include <QTextDocument>
#include <QTextFragment>

namespace crater::lyrics {

// ─── Named-color palette ─────────────────────────────────────────────────
// The seven v1 named colors, mapped to hex codes. These were picked to be
// distinguishable on a typical dark stage backdrop (no pure pastels, no
// near-blacks). When a theme system grows palette-override support, this
// table becomes the fallback rather than the source of truth — but for
// v1 it's enough.
namespace {

const QHash<QString, QString>& palette()
{
    // Constructed on first access (Meyers singleton). Lower-case keys; the
    // resolver lower-cases inputs before lookup.
    static const QHash<QString, QString> p = {
        { QStringLiteral("red"),    QStringLiteral("#e53935") },
        { QStringLiteral("orange"), QStringLiteral("#fb8c00") },
        { QStringLiteral("yellow"), QStringLiteral("#fdd835") },
        { QStringLiteral("green"),  QStringLiteral("#43a047") },
        { QStringLiteral("blue"),   QStringLiteral("#1e88e5") },
        { QStringLiteral("purple"), QStringLiteral("#8e24aa") },
        { QStringLiteral("gray"),   QStringLiteral("#757575") },
    };
    return p;
}

// Order matters — used by namedColors() and (indirectly) the toolbar swatch.
const QStringList& orderedNames()
{
    static const QStringList n = {
        QStringLiteral("red"),
        QStringLiteral("orange"),
        QStringLiteral("yellow"),
        QStringLiteral("green"),
        QStringLiteral("blue"),
        QStringLiteral("purple"),
        QStringLiteral("gray"),
    };
    return n;
}

// True for "#rgb" or "#rrggbb" form. We don't recognize 4 or 8-digit hex
// (alpha) in v1 — opacity is a theme decision.
bool isValidHexColor(QStringView s)
{
    if (s.isEmpty() || s[0] != QLatin1Char('#')) return false;
    const int n = s.size();
    if (n != 4 && n != 7) return false;
    for (int i = 1; i < n; ++i) {
        const QChar c = s[i].toLower();
        const bool isHex = (c >= QLatin1Char('0') && c <= QLatin1Char('9'))
                        || (c >= QLatin1Char('a') && c <= QLatin1Char('f'));
        if (!isHex) return false;
    }
    return true;
}

}  // namespace

QString resolveColor(const QString& nameOrHex)
{
    const QString s = nameOrHex.trimmed();
    if (s.isEmpty()) return QString();

    if (isValidHexColor(s)) {
        return s.toLower();
    }

    const auto it = palette().constFind(s.toLower());
    return it != palette().constEnd() ? it.value() : QString();
}

QStringList namedColors()
{
    return orderedNames();
}

// ─── Parser ──────────────────────────────────────────────────────────────
namespace {

// Returns true and advances `i` past `token` when `source` matches `token`
// at position `i`. Otherwise returns false and leaves `i` unchanged.
//
// Note: QStringView (UTF-16) and QLatin1String (Latin1) have different
// storage, so we can't wrap the QLatin1String in a QStringView constructor
// — but Qt 6 has heterogeneous comparison operators between the two view
// types, so we can compare directly.
bool consume(QStringView source, int& i, QLatin1String token)
{
    if (i + token.size() > source.size()) return false;
    if (source.mid(i, token.size()) != token) return false;
    i += token.size();
    return true;
}

// Flush `accum` as a Run with the current mark state, then clear `accum`.
// No-op if `accum` is empty so we don't emit zero-width runs.
void flushRun(QString& accum, Line& line,
              bool bold, bool italic, bool underline, const QString& color)
{
    if (accum.isEmpty()) return;
    Run r;
    r.text      = accum;
    r.bold      = bold;
    r.italic    = italic;
    r.underline = underline;
    r.color     = color;
    line.append(r);
    accum.clear();
}

}  // namespace

Doc parseDSL(const QString& source)
{
    Doc doc;
    Line currentLine;
    QString accum;

    // Mark state. Reset at every line boundary so a missing close marker
    // can never "leak" formatting into the next line — see header doc.
    bool bold      = false;
    bool italic    = false;
    bool underline = false;
    QString color;

    auto endLine = [&]() {
        flushRun(accum, currentLine, bold, italic, underline, color);
        doc.append(currentLine);
        currentLine.clear();
        bold      = false;
        italic    = false;
        underline = false;
        color.clear();
    };

    const QStringView src(source);
    const int n = src.size();
    int i = 0;
    while (i < n) {
        const QChar c = src[i];

        // Backslash escape — next char is literal regardless of meaning.
        // Trailing lone "\" at end of input is dropped silently; matches
        // CommonMark behavior and keeps unfinished operator typing from
        // crashing the parser.
        if (c == QLatin1Char('\\') && i + 1 < n) {
            accum.append(src[i + 1]);
            i += 2;
            continue;
        }

        // Newline terminates the line — flush, reset marks.
        if (c == QLatin1Char('\n')) {
            endLine();
            ++i;
            continue;
        }

        // Color open: {color=...}
        // Must check before generic "{" handling. The value is anything up
        // to the next "}" — we don't allow nested braces in v1 (no use case).
        if (c == QLatin1Char('{') && consume(src, i, QLatin1String("{color="))) {
            const int closeBrace = source.indexOf(QLatin1Char('}'), i);
            if (closeBrace > 0) {
                flushRun(accum, currentLine, bold, italic, underline, color);
                color = source.mid(i, closeBrace - i).trimmed();
                i = closeBrace + 1;
                continue;
            }
            // No closing "}": rewind and emit the consumed "{color=" as text.
            // This is the graceful-degradation path for half-typed input.
            i -= QLatin1String("{color=").size();
            accum.append(src[i]);
            ++i;
            continue;
        }

        // Color close: {/color}
        if (c == QLatin1Char('{') && consume(src, i, QLatin1String("{/color}"))) {
            flushRun(accum, currentLine, bold, italic, underline, color);
            color.clear();
            continue;
        }

        // Bold (**) — must be checked before italic (*) so the greedy
        // match takes the 2-char form when both could apply.
        if (consume(src, i, QLatin1String("**"))) {
            flushRun(accum, currentLine, bold, italic, underline, color);
            bold = !bold;
            continue;
        }

        // Italic (*).
        if (c == QLatin1Char('*')) {
            flushRun(accum, currentLine, bold, italic, underline, color);
            italic = !italic;
            ++i;
            continue;
        }

        // Underline (++).
        if (consume(src, i, QLatin1String("++"))) {
            flushRun(accum, currentLine, bold, italic, underline, color);
            underline = !underline;
            continue;
        }

        // Plain character.
        accum.append(c);
        ++i;
    }

    // Tail line. We always call endLine() even if the source didn't end
    // with "\n", so a one-line source produces a one-Line Doc rather than
    // an empty one. An empty source produces a Doc containing one empty
    // Line — convenient for editors so even fresh songs have a row to
    // type into.
    endLine();

    return doc;
}

// ─── Serializer ──────────────────────────────────────────────────────────
namespace {

// Layer ordering — outer to inner: color > bold > italic > underline.
// This is the canonical nesting we emit. It MUST match the close-then-
// open logic below; if you change one, change the other.
enum Layer : int { LayerColor = 0, LayerBold = 1, LayerItalic = 2, LayerUnderline = 3, LayerCount = 4 };

// Returns the FIRST layer (outermost-priority) at which `prev` and `cur`
// differ, or LayerCount if they're identical at every layer. The serializer
// uses this to compute the "common prefix" of marks that stays open
// between adjacent runs — closing only the layers from this point inward.
int firstDifferingLayer(const Run& prev, const Run& cur)
{
    if (prev.color     != cur.color)     return LayerColor;
    if (prev.bold      != cur.bold)      return LayerBold;
    if (prev.italic    != cur.italic)    return LayerItalic;
    if (prev.underline != cur.underline) return LayerUnderline;
    return LayerCount;
}

// Per-character escape. Conservatively escapes any char that COULD start
// a DSL token at this position — false positives are harmless (parser
// strips the leading "\"), false negatives would corrupt round-trips.
QString escapeText(const QString& s)
{
    QString out;
    out.reserve(s.size() + 4);
    for (const QChar c : s) {
        if (c == QLatin1Char('\\') || c == QLatin1Char('*')
         || c == QLatin1Char('+')  || c == QLatin1Char('{')) {
            out.append(QLatin1Char('\\'));
        }
        out.append(c);
    }
    return out;
}

void emitOpenMarks(QString& out, const Run& r, int fromLayer)
{
    // Open from `fromLayer` outward to innermost — i.e. emit color open
    // before bold open before italic open before underline open. Only
    // emit a layer's open marker if that mark is actually on for `r`.
    if (fromLayer <= LayerColor && !r.color.isEmpty()) {
        out.append(QLatin1String("{color="));
        out.append(r.color);
        out.append(QLatin1Char('}'));
    }
    if (fromLayer <= LayerBold      && r.bold)      out.append(QLatin1String("**"));
    if (fromLayer <= LayerItalic    && r.italic)    out.append(QLatin1String("*"));
    if (fromLayer <= LayerUnderline && r.underline) out.append(QLatin1String("++"));
}

void emitCloseMarks(QString& out, const Run& state, int toLayer)
{
    // Close from innermost down to `toLayer` — reverse of opening order.
    // Only emit a layer's close marker if THAT mark is currently on in
    // `state` (i.e. has an open marker that needs balancing).
    if (toLayer <= LayerUnderline && state.underline)      out.append(QLatin1String("++"));
    if (toLayer <= LayerItalic    && state.italic)         out.append(QLatin1String("*"));
    if (toLayer <= LayerBold      && state.bold)           out.append(QLatin1String("**"));
    if (toLayer <= LayerColor     && !state.color.isEmpty()) out.append(QLatin1String("{/color}"));
}

}  // namespace

QString serializeDSL(const Doc& doc)
{
    QString out;

    for (int li = 0; li < doc.size(); ++li) {
        if (li > 0) out.append(QLatin1Char('\n'));

        const Line& line = doc.at(li);
        // `state` tracks which marks are currently open in the output.
        // Initialized to "nothing open" at the start of each line — marks
        // never cross line boundaries (DSL rule v1).
        Run state;

        for (const Run& r : line) {
            const int diffLayer = firstDifferingLayer(state, r);

            // Close from innermost down to (diffLayer)
            emitCloseMarks(out, state, diffLayer);
            // Open from diffLayer outward to innermost
            emitOpenMarks(out, r, diffLayer);

            out.append(escapeText(r.text));
            state = r;
        }

        // End of line — close anything still open (always layer 0 = color).
        emitCloseMarks(out, state, LayerColor);
    }

    return out;
}

QString flattenText(const Doc& doc)
{
    QString out;
    bool first = true;
    for (const Line& line : doc) {
        if (!first) out.append(QLatin1Char('\n'));
        first = false;
        for (const Run& r : line) {
            out.append(r.text);
        }
    }
    return out;
}

// ─── HTML emission ───────────────────────────────────────────────────────
namespace {

// Escape the three HTML special characters that can break inline embedding.
// We deliberately do NOT escape quotes — they only matter inside attribute
// values, and our attribute values are controlled hex colors that never
// contain quotes.
QString htmlEscape(const QString& s)
{
    QString out;
    out.reserve(s.size());
    for (const QChar c : s) {
        if      (c == QLatin1Char('<')) out.append(QLatin1String("&lt;"));
        else if (c == QLatin1Char('>')) out.append(QLatin1String("&gt;"));
        else if (c == QLatin1Char('&')) out.append(QLatin1String("&amp;"));
        else                            out.append(c);
    }
    return out;
}

}  // namespace

QString runsToHtml(const Line& runs)
{
    QString out;
    for (const Run& r : runs) {
        // Skip zero-width runs — they'd produce empty tag pairs that bloat
        // the HTML and serve no purpose. parseDSL should already skip
        // these (see flushRun), but be defensive in case callers hand us
        // a hand-built run list.
        if (r.text.isEmpty()) continue;

        // Resolve color lazily. An unknown color name yields an empty
        // string from resolveColor — we treat that as "no color override"
        // so the surrounding Text element's color shows through, rather
        // than emitting an invalid CSS attribute.
        const QString resolvedColor = r.color.isEmpty() ? QString() : resolveColor(r.color);

        // Open marks outer-to-inner: color > bold > italic > underline.
        // Matches DSL canonical nesting so an HTML reader and a DSL reader
        // see the same logical wrapping order.
        if (!resolvedColor.isEmpty()) {
            out.append(QLatin1String("<span style=\"color:"));
            out.append(resolvedColor);
            out.append(QLatin1String(";\">"));
        }
        if (r.bold)      out.append(QLatin1String("<b>"));
        if (r.italic)    out.append(QLatin1String("<i>"));
        if (r.underline) out.append(QLatin1String("<u>"));

        out.append(htmlEscape(r.text));

        // Close in reverse order — innermost first.
        if (r.underline) out.append(QLatin1String("</u>"));
        if (r.italic)    out.append(QLatin1String("</i>"));
        if (r.bold)      out.append(QLatin1String("</b>"));
        if (!resolvedColor.isEmpty()) out.append(QLatin1String("</span>"));
    }
    return out;
}

QString dslLineToHtml(const QString& dslLine)
{
    // parseDSL always returns at least one Line (empty input yields a Doc
    // of one empty Line), so the indexed access here is safe.
    const Doc d = parseDSL(dslLine);
    return runsToHtml(d.first());
}

QString linesToHtml(const QStringList& dslLines)
{
    QString out;
    for (int i = 0; i < dslLines.size(); ++i) {
        if (i > 0) out.append(QLatin1String("<br>"));
        out.append(dslLineToHtml(dslLines.at(i)));
    }
    return out;
}

QString flattenLine(const QString& dslLine)
{
    // Single-line version of flattenText. We could implement it as
    // flattenText(parseDSL(dslLine)) but that allocates a full Doc just to
    // discard it — for FTS, which calls this once per line per song, the
    // direct path is preferable.
    const Doc d = parseDSL(dslLine);
    if (d.isEmpty()) return QString();
    QString out;
    for (const Run& r : d.first()) {
        out.append(r.text);
    }
    return out;
}

// ─── dslToHtml — combined parse + case-transform + HTML emit ────────────
namespace {

// Capitalize the first letter of each word in `s`. Word boundary = any
// non-alphanumeric character (whitespace, punctuation, DSL escapes already
// stripped by the parser). Mirrors CSS's "capitalize" semantics; not a
// linguistic title-case (would need locale rules — out of scope for v1).
QString capitalizeWords(const QString& s)
{
    QString out;
    out.reserve(s.size());
    bool atBoundary = true;
    for (const QChar c : s) {
        if (atBoundary && c.isLetter()) {
            out.append(c.toUpper());
        } else {
            out.append(c);
        }
        atBoundary = !c.isLetterOrNumber();
    }
    return out;
}

}  // namespace

QString dslToHtml(const QString& dsl, const QString& textTransform)
{
    Doc d = parseDSL(dsl);

    // Apply case transform to Run.text only — preserves markers and color
    // values, which were already consumed by the parser and won't survive
    // round-tripping through .toUpper() anyway.
    if (!textTransform.isEmpty()) {
        const QString t = textTransform.toLower();
        if (t == QLatin1String("uppercase")) {
            for (Line& line : d)
                for (Run& r : line) r.text = r.text.toUpper();
        } else if (t == QLatin1String("lowercase")) {
            for (Line& line : d)
                for (Run& r : line) r.text = r.text.toLower();
        } else if (t == QLatin1String("capitalize")) {
            for (Line& line : d)
                for (Run& r : line) r.text = capitalizeWords(r.text);
        }
        // Any other value: treat as no-op. Themes evolve; we'd rather
        // render the text un-transformed than refuse to render at all.
    }

    QString out;
    for (int i = 0; i < d.size(); ++i) {
        if (i > 0) out.append(QLatin1String("<br>"));
        out.append(runsToHtml(d.at(i)));
    }
    return out;
}

// ─── htmlToDsl — Qt RichText document → canonical DSL ────────────────────
QString htmlToDsl(const QString& html)
{
    QTextDocument doc;
    doc.setHtml(html);

    Doc result;
    QTextBlock block = doc.firstBlock();
    while (block.isValid()) {
        // Within a block, fragments carry distinct char formats. We also
        // need to split on U+2028 (LINE SEPARATOR) — Qt's parsed form of
        // `<br>` — because those represent DSL line breaks within a single
        // QTextBlock. Accumulator pattern: build the current Line until we
        // hit a separator, then push it and start a new one.
        Line currentLine;

        for (auto it = block.begin(); !it.atEnd(); ++it) {
            const QTextFragment frag = it.fragment();
            if (!frag.isValid()) continue;
            const QString fragText = frag.text();
            if (fragText.isEmpty()) continue;

            const QTextCharFormat fmt = frag.charFormat();
            const bool bold      = fmt.fontWeight() >= QFont::Bold;
            const bool italic    = fmt.fontItalic();
            const bool underline = fmt.fontUnderline();

            // Color extraction. We only store a color when the brush is
            // an explicit solid pattern with a valid color — NoBrush means
            // "inherit from parent," and we want that case to round-trip
            // as "no color override" rather than serializing the inherited
            // hex into the DSL.
            QString color;
            const QBrush fg = fmt.foreground();
            if (fg.style() != Qt::NoBrush) {
                const QColor c = fg.color();
                if (c.isValid()) {
                    color = c.name();  // canonical "#rrggbb"
                }
            }

            // Split on U+2028 — each piece becomes its own line. The runs
            // inherit the same char format across the split (you can't
            // have one half of a `<br>` boundary be bold and the other
            // not, since the markup applies to the whole fragment).
            const QStringList parts = fragText.split(QChar::LineSeparator);
            for (int pi = 0; pi < parts.size(); ++pi) {
                if (pi > 0) {
                    result.append(currentLine);
                    currentLine.clear();
                }
                if (parts[pi].isEmpty()) continue;

                Run r;
                r.text      = parts[pi];
                r.bold      = bold;
                r.italic    = italic;
                r.underline = underline;
                r.color     = color;
                currentLine.append(r);
            }
        }

        result.append(currentLine);
        block = block.next();
    }

    if (result.isEmpty()) result.append(Line{});
    return serializeDSL(result);
}

}  // namespace crater::lyrics
