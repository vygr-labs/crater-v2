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

// Strict near-miss resolver, for text nobody typed.
//
// lookupBook() is tuned for an operator at a search box, where a wrong guess
// costs one keystroke to correct. That tolerance is wrong for speech: it
// accepts subsequences and edit distance up to three, so "page" resolves to
// Jude and "in" to 1 Kings. A speech recogniser's mistakes do not look like
// that — it substitutes a phoneme, and "join" for "john" is one edit.
//
// So this variant drops the prefix and subsequence tiers entirely, takes
// `maxDistance` as a hard cap the caller chooses, and matches canonical names
// only (nobody says "Phlm" out loud). It also refuses ambiguity: when two
// different books tie at the best distance there is no evidence to choose
// between them, and returning nothing is the honest answer.
//
// Exact table hits — including the aliases lookupBook knows — still resolve,
// so this is a strictly narrower door into the same room.
std::optional<BibleBookMeta> lookupBookNearMiss(QStringView nameOrAlt, int maxDistance);

// All 66 books in canonical order.
const QList<BibleBookMeta>& allCanonicalBooks();

}  // namespace crater::import
