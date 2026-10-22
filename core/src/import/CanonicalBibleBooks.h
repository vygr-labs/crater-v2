#pragma once

#include <QList>
#include <QString>
#include <QStringView>

#include <optional>

namespace crater::import {

// Canonical Bible book metadata. Each book has a stable book_number (1..66 in
// the standard Protestant canon) and a fixed testament. Names and abbreviations
// come from the SBL Handbook of Style, with common alternates handled by the
// lookup function below.
struct BibleBookMeta {
    QString name;         // canonical title-case: "Genesis", "1 Samuel", "Revelation"
    QString abbrev;       // "Gen", "1Sam", "Rev"
    int     bookNumber;   // 1..66 in canonical order
    QString testament;    // "OT" or "NT"
};

// Returns metadata for a book name. Case-insensitive.
//
// Resolution is two-tier:
//   1. Exact match against canonical names, canonical abbrevs, and a small
//      alias table ("psalm", "song of songs", "canticles", "revelations",
//      plus tie-breakers like "jn"→John, "jud"→Jude).
//   2. On miss: fuzzy fallback that scores every book by prefix match,
//      subsequence match, and bounded edit distance. Picks up shortforms
//      operators routinely type (gn → Genesis, mt → Matthew, dt →
//      Deuteronomy) and typos (phillipians → Philippians) without an
//      alias-table entry per variant.
//
// Returns nullopt only when nothing clears the fuzzy quality gate.
std::optional<BibleBookMeta> lookupBook(QStringView nameOrAlt);

// For a book name read from a file rather than typed by the operator.
// Exact names, abbreviations and aliases as above, then only a close spelling
// of a full name: Latin letters, at least four, within a third of the name's
// length, ignoring diacritics ("Genezis", "Levitikus"). No shortform
// guessing, which would read a two-letter name in another script as Psalms,
// and nothing from the deuterocanon. nullopt when unsure.
std::optional<BibleBookMeta> lookupBookName(QStringView name);

// A looser guess at a name from a file, for when where the book sits already
// narrows down which it can be: lookupBook's shortform matching, but never
// for a number, a name in another script, or one from the deuterocanon.
std::optional<BibleBookMeta> guessBookName(QStringView name);

// All 66 books in canonical order.
const QList<BibleBookMeta>& allCanonicalBooks();

}  // namespace crater::import
