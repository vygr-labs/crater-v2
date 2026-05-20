#include "import/Rtf.h"

#include <QChar>
#include <QList>
#include <QString>
#include <QStringList>

namespace crater::rtf {

namespace {

// Windows-1252 mappings for the 0x80-0x9F range, where cp1252 diverges from
// Latin-1. EasyWorship writes its RTF in cp1252, so \'93 / \'94 / \'96 must
// decode to curly quotes / en-dash here rather than to C1 control characters.
// Indexed by (byte - 0x80). The five undefined cp1252 slots (0x81, 0x8D,
// 0x8F, 0x90, 0x9D) map to the byte value unchanged — a harmless fallback.
const ushort kCp1252High[32] = {
    0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
    0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
};

QChar decodeCp1252(int byte)
{
    byte &= 0xFF;
    if (byte < 0x80 || byte > 0x9F) return QChar(ushort(byte));
    return QChar(kCp1252High[byte - 0x80]);
}

// Destination control words whose entire group is non-content. A group whose
// FIRST token is one of these (or the \* ignorable marker) is skipped whole.
bool isSkippableDestination(const QString& keyword)
{
    static const QStringList kSkip = {
        QStringLiteral("fonttbl"),            QStringLiteral("colortbl"),
        QStringLiteral("stylesheet"),         QStringLiteral("info"),
        QStringLiteral("pict"),               QStringLiteral("generator"),
        QStringLiteral("themedata"),          QStringLiteral("colorschememapping"),
        QStringLiteral("listtable"),          QStringLiteral("listoverridetable"),
        QStringLiteral("rsidtbl"),            QStringLiteral("latentstyles"),
    };
    return kSkip.contains(keyword);
}

struct GroupState
{
    bool ignored       = false;  // text inside this group is discarded
    bool sawFirstToken = false;  // first token decides whether the group is a destination
    int  ucValue       = 1;      // \uc — fallback characters to skip after a \u
};

}  // namespace

QString toPlainText(const QString& rtf)
{
    // Not RTF — hand it back as plain text so callers can treat it as lyrics.
    if (!rtf.contains(QStringLiteral("\\rtf")))
        return rtf.trimmed();

    QString out;
    out.reserve(rtf.size() / 2);

    QList<GroupState> stack;
    stack.append(GroupState{});  // implicit root, tolerant of a sloppy document

    int unicodeSkip = 0;         // fallback "characters" still to swallow after a \u

    const int n = rtf.size();
    int i = 0;
    while (i < n) {
        const QChar c = rtf.at(i);

        if (c == QLatin1Char('{')) {
            const GroupState parent = stack.last();
            GroupState g;
            g.ignored = parent.ignored;   // ignore-state is inherited by children
            g.ucValue = parent.ucValue;   // \uc is inherited by children
            stack.append(g);
            unicodeSkip = 0;
            ++i;
            continue;
        }
        if (c == QLatin1Char('}')) {
            if (stack.size() > 1) stack.removeLast();
            unicodeSkip = 0;
            ++i;
            continue;
        }

        if (c == QLatin1Char('\\')) {
            if (i + 1 >= n) { ++i; continue; }
            const QChar next = rtf.at(i + 1);

            // ── Control symbol (a non-letter follows the backslash) ──────────
            if (!next.isLetter()) {
                if (next == QLatin1Char('\'')) {
                    // \'hh — a hex byte, decoded as cp1252.
                    if (i + 3 < n) {
                        bool ok = false;
                        const int byte = rtf.mid(i + 2, 2).toInt(&ok, 16);
                        if (ok) {
                            if (unicodeSkip > 0)            --unicodeSkip;
                            else if (!stack.last().ignored) out.append(decodeCp1252(byte));
                        }
                        i += 4;
                        continue;
                    }
                    i += 2;
                    continue;
                }
                if (next == QLatin1Char('*')) {
                    // {\* ...} — an ignorable destination group.
                    GroupState& g = stack.last();
                    if (!g.sawFirstToken) { g.sawFirstToken = true; g.ignored = true; }
                    i += 2;
                    continue;
                }
                stack.last().sawFirstToken = true;
                if (unicodeSkip > 0) {
                    --unicodeSkip;
                } else if (!stack.last().ignored) {
                    if (next == QLatin1Char('\\') || next == QLatin1Char('{')
                        || next == QLatin1Char('}')) {
                        out.append(next);                     // escaped literal
                    } else if (next == QLatin1Char('~')) {
                        out.append(QLatin1Char(' '));         // non-breaking space
                    } else if (next == QLatin1Char('_')) {
                        out.append(QLatin1Char('-'));         // non-breaking hyphen
                    }
                    // \- (optional hyphen) and any other symbol emit nothing.
                }
                i += 2;
                continue;
            }

            // ── Control word: letters, then an optional numeric parameter ────
            int j = i + 1;
            while (j < n && rtf.at(j).isLetter()) ++j;
            const QString keyword = rtf.mid(i + 1, j - (i + 1));

            bool hasParam = false;
            int  param    = 0;
            const int paramStart = j;
            if (j < n && (rtf.at(j) == QLatin1Char('-') || rtf.at(j).isDigit())) {
                if (rtf.at(j) == QLatin1Char('-')) ++j;
                while (j < n && rtf.at(j).isDigit()) ++j;
                hasParam = true;
                param = rtf.mid(paramStart, j - paramStart).toInt();
            }
            // A single trailing space is the control-word delimiter — consume it.
            if (j < n && rtf.at(j) == QLatin1Char(' ')) ++j;

            GroupState& g = stack.last();
            const bool firstInGroup = !g.sawFirstToken;
            g.sawFirstToken = true;
            if (firstInGroup && isSkippableDestination(keyword))
                g.ignored = true;

            if (unicodeSkip > 0) {
                --unicodeSkip;                 // a control word counts as one fallback char
            } else if (keyword == QStringLiteral("uc")) {
                if (hasParam && param >= 0) g.ucValue = param;
            } else if (keyword == QStringLiteral("u")) {
                if (!g.ignored && hasParam) {
                    int code = param;
                    if (code < 0) code += 65536;          // RTF \u is a signed 16-bit value
                    out.append(QChar(ushort(code)));
                }
                unicodeSkip = g.ucValue;
            } else if (!g.ignored) {
                if (keyword == QStringLiteral("par") || keyword == QStringLiteral("line")
                    || keyword == QStringLiteral("sect") || keyword == QStringLiteral("cell")
                    || keyword == QStringLiteral("row")) {
                    out.append(QLatin1Char('\n'));
                } else if (keyword == QStringLiteral("tab")) {
                    out.append(QLatin1Char('\t'));
                }
                // Every other control word is formatting — consumed, no output.
            }
            i = j;
            continue;
        }

        // ── Plain text ───────────────────────────────────────────────────────
        if (c == QLatin1Char('\r') || c == QLatin1Char('\n')) {
            ++i;                               // line breaks in RTF source are not content
            continue;
        }
        if (unicodeSkip > 0) {
            --unicodeSkip;
        } else if (!stack.last().ignored) {
            stack.last().sawFirstToken = true;
            out.append(c);
        }
        ++i;
    }

    return out;
}

}  // namespace crater::rtf
