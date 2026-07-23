#pragma once

#include <QString>
#include <QStringList>

namespace crater::db {

// A raw user query transformed into a SAFE FTS5 MATCH expression.
//
// The library FTS tables (verses_fts, songs_fts) use the `trigram` tokenizer,
// which substring-matches tokens of 3+ characters. Binding raw user input
// straight to `... MATCH ?` is unsafe on two counts:
//   1. A stray quote / operator char is an FTS5 syntax error. Callers swallow
//      it, so the user just sees zero results with no idea why.
//   2. A sub-3-char word ("is", "of") tokenizes to nothing under trigram and
//      zeroes an otherwise-good implicit-AND query ("God is love" → nothing).
//
// buildFtsQuery() fixes both: every term is emitted as a quoted FTS5 string
// literal (so operator characters are inert), terms the trigram tokenizer
// cannot match are dropped, and a small, intentional operator set is honored:
//
//   "quoted phrase"   → matched as a literal substring (spaces included)
//   a OR b            → OR join instead of the default AND
//   -term / NOT term  → exclude rows containing the term
//
// `match` is empty when nothing searchable remains (query blank, or every term
// shorter than the 3-char trigram floor). Callers should treat an empty match
// as "no results" and skip the FTS query entirely rather than binding "".
struct FtsQuery
{
    QString     match;    // safe MATCH expression, or "" when unsearchable
    QStringList terms;    // plain lowercased include terms — for snippet/highlight

    bool isEmpty() const { return match.isEmpty(); }
};

// Minimum term length the trigram tokenizer can index/match.
inline constexpr int kTrigramFloor = 3;

FtsQuery buildFtsQuery(const QString& raw);

}  // namespace crater::db
