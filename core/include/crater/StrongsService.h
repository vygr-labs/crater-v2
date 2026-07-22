#pragma once

#include "crater/value/StrongsBibleVerse.h"
#include "crater/value/StrongsEntry.h"
#include "crater/value/StrongsSection.h"
#include "crater/value/StrongsWord.h"

#include <QList>
#include <QObject>
#include <QString>
#include <QVariantMap>

#include <memory>

namespace crater {

namespace db { class Connection; }

// Strong's concordance — the lexicon (dictionary) plus the KJV-with-Strong's
// Bible used by the interlinear reader.
//
// Backed by two READ-ONLY SQLite files shipped beside the app
// (strongs-dictionary.sqlite, strongs-bible.sqlite). This is static reference
// data: never written, never migrated (unlike bibles.sqlite, which is imported
// into writable storage and carries an FTS index). Keyword search is a plain
// LIKE over ~14.7k rows — sub-millisecond, no FTS needed, matching the Electron
// behaviour.
//
// If either file is missing (e.g. a dev checkout without the electron repo, or
// a production install that didn't ship the data), the corresponding
// `hasDictionary` / `hasBible` stays false and its queries return empty. The
// tab surfaces a "data not found" state rather than crashing. Public methods
// are all sync (ARCHITECTURE.md §3): every query is an indexed point lookup or
// a ≤100-row scan.
class StrongsService : public QObject
{
    Q_OBJECT

    Q_PROPERTY(bool available     READ available     CONSTANT)
    Q_PROPERTY(bool hasDictionary READ hasDictionary CONSTANT)
    Q_PROPERTY(bool hasBible      READ hasBible      CONSTANT)

public:
    explicit StrongsService(QObject* parent = nullptr);
    ~StrongsService() override;

    bool available() const;       // true when both DBs opened
    bool hasDictionary() const;
    bool hasBible() const;

    // ── Dictionary (lexicon) ────────────────────────────────────────────

    // Exact lookup by Strong's number ("H430" / "G2424"). Case-insensitive.
    // Returns an invalid entry (word.isEmpty()) on miss.
    Q_INVOKABLE crater::StrongsEntry lookup(QString word);

    // Number-or-keyword search. A bare number ("H430" / "G2424") resolves to an
    // exact lookup; anything else runs a substring match over the number and
    // the definition text, capped at 100 rows and ordered by relativeOrder.
    // `language` optionally narrows to "hebrew" or "greek".
    Q_INVOKABLE QList<crater::StrongsEntry> search(QString query, QString language = {});

    // Ordered browse — the empty-query default view. ORDER BY relativeOrder.
    Q_INVOKABLE QList<crater::StrongsEntry> browse(int limit = 100,
                                                   int offset = 0,
                                                   QString language = {});

    // Split a word's definition into projectable slides (HTML stripped, packed
    // to a slide-sized character budget). Empty when the word isn't found.
    Q_INVOKABLE QList<crater::StrongsSection> sections(QString word);

    // ── Bible (KJV + Strong's) ──────────────────────────────────────────

    // Resolve a free-text reference ("jn 3:16", "Genesis 1", "psalm 23") into
    // { valid: bool, book: int(1..66), bookName: QString, chapter: int,
    //   verse: int }. `verse` defaults to 1 when omitted. `valid` is false when
    // the input doesn't parse to a known book.
    Q_INVOKABLE QVariantMap resolveReference(QString input);

    // All verses in a chapter, ordered by verse. `book` is the 1..66 canonical
    // number. Empty list on miss.
    Q_INVOKABLE QList<crater::StrongsBibleVerse> chapter(int book, int chapter);

    // Single verse. Returns an invalid verse (verse == 0) on miss.
    Q_INVOKABLE crater::StrongsBibleVerse verse(int book, int chapter, int verse);

    // Tokenize a raw verse text (Strong's tags + KJV markup) into words. Each
    // Strong's tag attaches its number to the word it immediately follows.
    Q_INVOKABLE QList<crater::StrongsWord> tokenize(QString verseText);

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

}  // namespace crater
