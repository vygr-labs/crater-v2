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
//
// Bibles added from files can also hold the deuterocanon: the books Catholic
// Bibles add, and the further ones of Orthodox Bibles and the KJV's
// Apocrypha, numbered 67 up in the order USFM lists them. Only the 66 ship
// with Crater, so a reference to one of these finds a verse only in a
// translation that has it.
struct BibleBookMeta {
    QString name;         // canonical title-case: "Genesis", "1 Samuel", "Revelation"
    QString abbrev;       // "Gen", "1Sam", "Rev"
    int     bookNumber;   // 1..66 in canonical order, 67 up for the deuterocanon
    QString testament;    // "OT" or "NT"
};

// Book numbers past the 66.
inline constexpr int kFirstDeuterocanonical = 67;
inline constexpr int kLastBookNumber        = 85;
// Psalm 151, which USFM and OSIS give a code of its own and most Bibles
// number as a psalm. Readers store it as Psalms 151; no book has this number.
inline constexpr int kPsalm151 = 84;

// Returns metadata for a book name. Case-insensitive.
//
// Resolution is three-tier:
//   1. Exact match against canonical names, canonical abbrevs, and a small
//      alias table ("psalm", "song of songs", "canticles", "revelations",
//      plus tie-breakers like "jn"→John, "jud"→Jude). The deuterocanon's
//      names and abbreviations are in it too ("Tobit", "Sir", "1 Macc").
//   2. The start of a deuterocanonical name ("tobi", "1 macca"), when it
//      isn't the start of one of the 66 as well.
//   3. On miss: fuzzy fallback that scores every one of the 66 by prefix
//      match, subsequence match, and bounded edit distance. Picks up
//      shortforms operators routinely type (gn → Genesis, mt → Matthew, dt →
//      Deuteronomy) and typos (phillipians → Philippians) without an
//      alias-table entry per variant. The deuterocanon never takes part, so
//      a shortform keeps meaning what it always has.
//
// Returns nullopt only when nothing clears the fuzzy quality gate.
std::optional<BibleBookMeta> lookupBook(QStringView nameOrAlt);

// For a book name read from a file rather than typed by the operator.
// Exact names, abbreviations and aliases as above, then the deuterocanon by
// the stems its names share across languages ("Tobiáš", "Eclesiástico",
// "1. Makabejcov"), then only a close spelling of one of the 66: Latin
// letters, at least four, within a third of the name's length, ignoring
// diacritics ("Genezis", "Levitikus"). No shortform guessing, which would
// read a two-letter name in another script as Psalms. A numbered Esdras is
// Ezra and Nehemiah in Catholic Bibles and two other books in the KJV's
// Apocrypha, so it says nothing. nullopt when unsure.
std::optional<BibleBookMeta> lookupBookName(QStringView name);

// A looser guess at a name from a file, for when where the book sits already
// narrows down which it can be: lookupBook's shortform matching, but never
// for a number or a name in another script.
std::optional<BibleBookMeta> guessBookName(QStringView name);

// A book from a file that Crater doesn't hold under any number: the Odes,
// the Psalms of Solomon, Laodiceans, Enoch and the like. Placing books by
// their order must never give one of these a number.
bool isUnheldBookName(QStringView name);

// 1 Esdras (81) or 2 Esdras (82) for a numbered Esdras where it can only be
// one of the KJV's Apocrypha (a Zefania book numbered past 66), else 0.
int apocryphalEsdras(QStringView name);

// All 66 books in canonical order.
const QList<BibleBookMeta>& allCanonicalBooks();

// The deuterocanon, 67 up (Psalm 151's number excepted, see kPsalm151).
const QList<BibleBookMeta>& deuterocanonicalBooks();

// Any book Crater holds, by number, or nullptr.
const BibleBookMeta* bookByNumber(int bookNumber);

// Where a book sits when a translation's books are listed: the 66 in their
// order, with the deuterocanon where a Catholic Bible puts it (Tobit and
// Judith after Nehemiah, Wisdom and Sirach after the Song of Songs).
int bookListPosition(int bookNumber);

}  // namespace crater::import
