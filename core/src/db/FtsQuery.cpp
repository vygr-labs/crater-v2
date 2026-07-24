#include "db/FtsQuery.h"

#include <QChar>
#include <QList>
#include <utility>

namespace crater::db {

namespace {

// One lexical token from the raw query, plus whether it came from a "quoted
// phrase" (phrases keep their internal spaces and are never treated as
// operator keywords).
struct Token
{
    QString text;
    bool    isPhrase = false;
};

// Split the raw query on whitespace, keeping "double quoted phrases" intact.
// An unterminated quote runs to end-of-string (so a half-typed `"lo` still
// searches for `lo` rather than erroring).
QList<Token> tokenize(const QString& raw)
{
    QList<Token> tokens;
    const int n = raw.size();
    int i = 0;
    while (i < n) {
        const QChar c = raw.at(i);
        if (c.isSpace()) {
            ++i;
            continue;
        }
        if (c == QLatin1Char('"')) {
            ++i;  // consume opening quote
            QString buf;
            while (i < n && raw.at(i) != QLatin1Char('"')) {
                buf.append(raw.at(i));
                ++i;
            }
            if (i < n) ++i;  // consume closing quote
            const QString t = buf.trimmed();
            if (!t.isEmpty()) tokens.append({t, true});
        } else {
            QString buf;
            while (i < n && !raw.at(i).isSpace() && raw.at(i) != QLatin1Char('"')) {
                buf.append(raw.at(i));
                ++i;
            }
            if (!buf.isEmpty()) tokens.append({buf, false});
        }
    }
    return tokens;
}

// Wrap a term as an FTS5 string literal: surround with double quotes and
// escape any embedded double quote by doubling it. Inside an FTS5 string
// literal only `"` is special, so this fully neutralizes operator characters
// (`*`, `:`, `^`, `(`, `)`, `-`, `+`, `AND`/`OR`/`NOT`, …).
QString quoteFts(const QString& term)
{
    QString escaped = term;
    escaped.replace(QLatin1Char('"'), QStringLiteral("\"\""));
    return QLatin1Char('"') + escaped + QLatin1Char('"');
}

// Strip apostrophes / single-quotes so a stray or missing quote can never
// change matching. The trigram tokenizer treats an apostrophe as an ordinary
// character, so "God's" indexes trigrams containing the quote — a query for
// "gods" (or a typo'd "i's") would then miss. We normalise BOTH sides: the
// indexed content strips the SAME two characters in SQL (the song FTS
// statements, BibleService::rebuildFtsIndex, the ElectronDataImporter, and the
// re-index migrations), so index and query always agree.
//
// NOTE: the on-screen highlighter (SearchFormat.qml) deliberately does NOT
// strip — it searches the DISPLAYED text, which keeps its apostrophes, so a
// search for "God's" still bolds the literal "God's" on screen. Matching
// (here) and highlighting (there) have different jobs; only matching needs
// the index and query to agree.
QString stripApostrophes(QString s)
{
    s.remove(QLatin1Char('\''));   // U+0027 APOSTROPHE
    s.remove(QChar(0x2019));       // U+2019 RIGHT SINGLE QUOTATION MARK
    return s;
}

}  // namespace

FtsQuery buildFtsQuery(const QString& raw)
{
    FtsQuery q;
    if (raw.trimmed().isEmpty()) return q;

    const QList<Token> tokens = tokenize(raw);

    QStringList include;   // quoted FTS literals joined by AND/OR
    QStringList exclude;   // quoted FTS literals, subtracted via NOT (…)
    bool useOr      = false;
    bool negateNext = false;

    for (const Token& tok : tokens) {
        QString text = tok.text;

        if (!tok.isPhrase) {
            // Bareword operator keywords (uppercase, as the user types them).
            if (text == QLatin1String("OR"))  { useOr = true;      continue; }
            if (text == QLatin1String("AND")) {                    continue; }  // default
            if (text == QLatin1String("NOT")) { negateNext = true; continue; }
            // A leading '-' negates the term (a bare "-" is just dropped).
            while (text.startsWith(QLatin1Char('-'))) {
                negateNext = true;
                text = text.mid(1);
            }
        }

        // Normalise apostrophes out before the length check so index and query
        // agree: "i's" collapses to "is" (then dropped below as sub-trigram),
        // "God's" to "gods" — matching the apostrophe-stripped FTS content.
        text = stripApostrophes(text);

        // Trigram floor: a term shorter than 3 chars produces no trigrams and
        // can never match; including it would zero an implicit-AND query, so
        // drop it (and clear any pending negation it carried).
        if (text.size() < kTrigramFloor) {
            negateNext = false;
            continue;
        }

        const QString literal = quoteFts(text);
        if (negateNext) {
            exclude.append(literal);
            negateNext = false;
        } else {
            include.append(literal);
            q.terms.append(text.toLower());
        }
    }

    // A pure-exclude query ("just -foo") has nothing positive to match on, so
    // there is no useful result set — treat it as unsearchable.
    if (include.isEmpty()) return q;

    const QString joiner = useOr ? QStringLiteral(" OR ") : QStringLiteral(" AND ");
    QString match = include.join(joiner);
    if (!exclude.isEmpty()) {
        if (include.size() > 1) match = QLatin1Char('(') + match + QLatin1Char(')');
        match += QStringLiteral(" NOT (") + exclude.join(QStringLiteral(" OR "))
               + QLatin1Char(')');
    }
    q.match = std::move(match);
    return q;
}

}  // namespace crater::db
