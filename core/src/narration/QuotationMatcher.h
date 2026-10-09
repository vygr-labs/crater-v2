#pragma once

#include "crater/value/HeardReference.h"
#include "crater/value/SearchHit.h"

#include <QList>
#include <QSet>
#include <QString>
#include <QStringList>

#include <functional>

namespace crater::narration {

// Verbatim quotation detection. docs/narration.md §2, the second of the three
// paths, and the cheapest: the FTS5 trigram index over verses.text already
// exists and is already tuned, so this path costs a query rather than a model.
//
// Preachers quote scripture constantly without naming it, and a congregation
// hearing "For God so loved the world" expects the verse on the screen even
// though nobody said "John three sixteen". The citation path is blind to all
// of it.
//
// ── Why uniqueness rather than a BM25 threshold ──────────────────────────
//
// BibleService::search issues an implicit AND across terms, so a query of six
// distinctive words from a verse asks "which verses contain all six of these".
// When the answer is exactly one verse out of 31,102, that is near-conclusive
// on its own — and it is conclusive for a reason no tuned score can claim: it
// is a property of the corpus, not of a threshold somebody picked.
//
// That matters because a BM25 cutoff would need re-tuning per translation, per
// index rebuild, and per verse length, and every one of those re-tunings is an
// opportunity to quietly start firing on ordinary speech. Uniqueness has no
// such knob. A phrase generic enough to match many verses is, by definition,
// not a quotation of any one of them.
//
// ── Why coverage decides the tier ────────────────────────────────────────
//
// "The LORD is my shepherd, I shall not want" carries only three words a
// stopword filter keeps — but those three ARE the verse, and no other verse
// contains all of them. A word count alone would demote the second most
// quoted verse in the Bible. So the tier asks a better question: how much of
// the matched verse did the preacher actually say? Saying most of a verse is
// quotation. Sharing three words with a long verse is coincidence.
//
// Pure and injectable: the search function is supplied by the caller, exactly
// as CitationDetector takes a validator, so this is testable against a
// handful of fixture verses with no database present.
class QuotationMatcher
{
public:
    struct Config
    {
        // Cheap pre-filter, not the real gate. Below three content words a
        // query is not worth issuing; above it, uniqueness does the deciding.
        int minContentWords = 3;

        // Words per query window. Long enough to be distinctive, short enough
        // that one mangled word does not poison every window — the AND is
        // unforgiving, so a transcript error kills any window containing it.
        // Overlapping windows are how the phrase survives that.
        int maxWindowWords = 8;
        int windowStep     = 3;

        // Queries per utterance. Each is an FTS5 AND over a 285 MB index and
        // the whole detector pass has a 20 ms budget (docs/narration.md §9),
        // so this is a latency bound, not a quality one.
        int maxWindows = 4;

        // References this path may contribute from one utterance. A preacher
        // reading a passage aloud would otherwise fill the queue one verse per
        // window.
        int maxEmits = 2;

        // Tier promotion (see the header comment). Either the preacher said
        // enough distinctive words to stand on their own, or they said
        // essentially all of the ones the verse has.
        int   highWordCount    = 5;
        qreal highCoverage     = 0.8;
        qreal minCoverage      = 0.34;
    };

    using SearchFn = std::function<QList<crater::SearchHit>(const QString& andQuery)>;

    explicit QuotationMatcher(Config cfg = {});

    void setSearch(SearchFn fn) { m_search = std::move(fn); }
    bool hasSearch() const      { return bool(m_search); }

    const Config& config() const { return m_cfg; }
    void setConfig(Config cfg)   { m_cfg = cfg; }

    // Detect quotations in one utterance. Returns an empty list when no
    // search function is installed, so the pipeline runs unchanged in a build
    // or a test with no Bible database.
    QList<crater::HeardReference> match(const QString& utterance, qint64 nowMs);

    // Utterance to the words worth searching on: lowercased, punctuation
    // stripped, stopwords removed, spoken and written numbers dropped.
    //
    // Numbers go because they belong to the other path. "John three sixteen
    // for God so loved the world" is a citation followed by a quotation, and
    // leaving "three sixteen" in the window would AND digits against verse
    // prose and match nothing.
    static QStringList contentWords(const QString& utterance);

    // Content words of a verse, for the coverage test. Same filter as above so
    // the two sides are comparable.
    static QSet<QString> verseContentWords(const QString& verseText);

private:
    Config   m_cfg;
    SearchFn m_search;
};

}  // namespace crater::narration
