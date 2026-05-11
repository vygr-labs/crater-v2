#pragma once

#include "crater/value/Book.h"
#include "crater/value/SearchHit.h"
#include "crater/value/Translation.h"
#include "crater/value/Verse.h"

#include <QFuture>
#include <QList>
#include <QObject>
#include <QString>

#include <memory>

namespace crater {

namespace db { class Connection; }

// All Bible queries — translations, books, chapters, verses, FTS search.
//
// Public methods are sync (per ARCHITECTURE.md §3 — every operation here
// completes in <1ms with our prepared-statement cache + FTS5 trigram index).
// The single async operation is `rebuildFtsIndex()`, which runs on a worker
// thread (multi-second on a full Bible) and returns a QFuture.
//
// Threading: this service is owned by the main thread. SQLite connection
// affinity is enforced via SQLITE_OPEN_FULLMUTEX in our Connection wrapper —
// but UI code should never call into BibleService off the main thread anyway.
class BibleService : public QObject
{
    Q_OBJECT

public:
    explicit BibleService(QObject* parent = nullptr);
    ~BibleService() override;

    // List all installed translations.
    Q_INVOKABLE QList<crater::Translation> translations();

    // Books for a specific translation, in canonical order. `chapterCount` is
    // populated via a MAX(chapter) subquery — single indexed lookup per book.
    Q_INVOKABLE QList<crater::Book> books(QString translationCode);

    // Single-verse lookup. Returns an empty Verse (text.isEmpty()) on miss.
    Q_INVOKABLE crater::Verse verse(QString translationCode,
                                    QString bookName,
                                    int     chapter,
                                    int     verseNumber);

    // All verses in a chapter, in order. Empty list on miss.
    Q_INVOKABLE QList<crater::Verse> chapter(QString translationCode,
                                             QString bookName,
                                             int     chapter);

    // Every verse for a translation, sorted by canonical book order then
    // (chapter, verse). KJV-scale call returns ~31k rows in one indexed scan.
    // ListView consumes the returned QList directly; only visible delegates
    // are instantiated so memory is bounded by row count, not list length.
    Q_INVOKABLE QList<crater::Verse> allVerses(QString translationCode);

    // Parse a shorthand reference ("Gen 1:1", "jn 3:16", "1 sa 1", "psalm 23")
    // into a single Verse via CanonicalBibleBooks. Missing verse defaults to 1.
    // Returns an invalid Verse (text.isEmpty()) when the input doesn't parse
    // or when the resolved book/chapter/verse doesn't exist.
    Q_INVOKABLE crater::Verse parseReference(QString input, QString translationCode);

    // FTS5 trigram search across verses.text. Optional `translationCodeFilter`
    // narrows to a single translation. Hard-capped at 100 hits (bm25-ranked).
    Q_INVOKABLE QList<crater::SearchHit> search(QString query,
                                                 QString translationCodeFilter = {});

    // Drops and rebuilds the verses_fts table from scratch. Runs on a worker
    // thread with its own connection; returns a QFuture<void> that resolves
    // when the worker completes.
    Q_INVOKABLE QFuture<void> rebuildFtsIndex();

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

}  // namespace crater
