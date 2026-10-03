#pragma once

#include "crater/value/Book.h"
#include "crater/value/SearchHit.h"
#include "crater/value/Translation.h"
#include "crater/value/Verse.h"

#include <QFuture>
#include <QList>
#include <QObject>
#include <QString>
#include <QVariantMap>

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

    // Bumps whenever the installed set or its order changes. QML bindings
    // that call translations() read it as a dependency so they re-run.
    Q_PROPERTY(int translationsRevision READ translationsRevision NOTIFY translationsChanged)

public:
    explicit BibleService(QObject* parent = nullptr);
    ~BibleService() override;

    // List all installed translations, in the operator's order.
    Q_INVOKABLE QList<crater::Translation> translations();

    // Save the operator's translation order (sort_order). `codes` lists the
    // new order. Installed codes it leaves out keep their relative order
    // after the listed ones, and unknown codes are ignored, so a stale list
    // can never drop a translation. Returns false if the write failed.
    Q_INVOKABLE bool setTranslationOrder(QStringList codes);

    int translationsRevision() const { return m_translationsRevision; }

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
    //
    // Cached, because re-reading a whole Bible costs ~200 ms on the GUI
    // thread, a visible freeze on the projector at every translation
    // switch. Bible rows are only written by the first-run import, which
    // finishes before this service exists, so the cache never goes stale.
    // It holds the few most recently used translations (~13 MB each)
    // unless preloading is on; see setPreloadAll.
    Q_INVOKABLE QList<crater::Verse> allVerses(QString translationCode);

    // Row of a verse inside allVerses(translationCode), or -1 when that
    // translation doesn't carry it. Book names match case-insensitively.
    // Constant time after the first call per translation; walking the list
    // from QML instead costs ~200 ms because every element read copies a
    // Verse into a JS wrapper.
    Q_INVOKABLE int verseIndex(QString translationCode, QString bookName,
                               int chapter, int verseNumber);

    // Parse a shorthand reference ("Gen 1:1", "jn 3:16", "1 sa 1", "psalm 23")
    // into a single Verse via CanonicalBibleBooks. Missing verse defaults to 1.
    // Returns an invalid Verse (text.isEmpty()) when the input doesn't parse
    // or when the resolved book/chapter/verse doesn't exist.
    Q_INVOKABLE crater::Verse parseReference(QString input, QString translationCode);

    // Same grammar as parseReference, but reports the whole span the
    // operator typed rather than collapsing to the opening verse.
    // Returns a map: valid (bool), book, chapter, verseStart, verseEnd.
    // verseEnd equals verseStart when no range was given, so callers can
    // treat every reference as a span of at least one.
    //
    // Exists because the reference box is the fastest way to pull a
    // passage onto one slide: "John 3:16-18" should stage three verses,
    // and Verse (a single DB row) has nowhere to carry the second bound.
    // Returning a map keeps that parse-only field off the row type.
    //
    // Book resolution is translation-independent, so no translation code
    // is needed — the caller looks the text up afterwards.
    Q_INVOKABLE QVariantMap parseReferenceRange(QString input);

    // FTS5 trigram search across verses.text. Optional `translationCodeFilter`
    // narrows to a single translation. Hard-capped at 100 hits (bm25-ranked).
    Q_INVOKABLE QList<crater::SearchHit> search(QString query,
                                                 QString translationCodeFilter = {});

    // Drops and rebuilds the verses_fts table from scratch. Runs on a worker
    // thread with its own connection; returns a QFuture<void> that resolves
    // when the worker completes.
    Q_INVOKABLE QFuture<void> rebuildFtsIndex();

    // true: read every installed translation on a worker thread and keep
    // them all, so even the first switch to one is instant. Costs ~13 MB
    // per installed translation. false (the default): keep only the few
    // most recently used, and drop the rest now if they were preloaded.
    // Wired to SettingsService::preloadTranslations in main.cpp.
    void setPreloadAll(bool on);

signals:
    void translationsChanged();

private:
    int m_translationsRevision = 0;
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

}  // namespace crater
