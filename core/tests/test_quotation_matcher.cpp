// Narration phase 3 — verbatim quotation detection. docs/narration.md §2.
//
// Two halves, and the second is the point.
//
// The first half drives QuotationMatcher against a hand-built fixture corpus
// that implements the same implicit-AND semantics BibleService::search does.
// That covers the logic this file owns: windowing, the uniqueness gate, the
// coverage test, tier assignment, and adjacency collapsing.
//
// The second half runs the SAME matcher against the operator's real
// bibles.sqlite through the real BibleService, with the real FTS5 trigram
// index over all 31,102 verses. A fixture with nine verses in it can prove
// the gate rejects ambiguity among nine verses; only the real corpus can
// prove "for God so loved the world" resolves uniquely among thirty-one
// thousand. Those tests skip, loudly, when the database is not present.
//
// Note test mode is deliberately NOT enabled here: DbPaths resolves through
// AppDataLocation, and redirecting it would point BibleService at an empty
// directory and quietly turn the real-corpus half into a no-op.

#include <QtTest>

#include <QCoreApplication>
#include <QFile>

#include "crater/BibleService.h"
#include "crater/value/HeardReference.h"
#include "crater/value/SearchHit.h"
#include "db/DbPaths.h"
#include "narration/QuotationMatcher.h"

using namespace crater;
using narration::QuotationMatcher;

namespace {

struct FixtureVerse
{
    const char* book;
    int         chapter;
    int         verse;
    const char* text;
};

// A corpus small enough to reason about and varied enough to be adversarial:
// John 3:16 and 3:17 share most of their vocabulary, the two "love one
// another" verses are near-identical, and Psalm 23:1 is the short-verse case
// the word-count-only rule would have thrown away.
const FixtureVerse kFixture[] = {
    { "John", 3, 16, "For God so loved the world, that he gave his only begotten Son, "
                     "that whosoever believeth in him should not perish, but have "
                     "everlasting life." },
    { "John", 3, 17, "For God sent not his Son into the world to condemn the world; "
                     "but that the world through him might be saved." },
    { "John", 13, 34, "A new commandment I give unto you, That ye love one another; "
                      "as I have loved you, that ye also love one another." },
    { "John", 15, 12, "This is my commandment, That ye love one another, as I have "
                      "loved you." },
    { "Psalms", 23, 1, "The LORD is my shepherd; I shall not want." },
    { "Psalms", 23, 2, "He maketh me to lie down in green pastures: he leadeth me "
                       "beside the still waters." },
    { "Romans", 8, 28, "And we know that all things work together for good to them "
                       "that love God, to them who are the called according to his "
                       "purpose." },
    { "Philippians", 4, 13, "I can do all things through Christ which strengtheneth me." },
    { "Genesis", 1, 1, "In the beginning God created the heaven and the earth." },
};

// Stands in for BibleService::search: implicit AND across terms, substring
// matching (the trigram tokenizer matches inside words, so "love" finds
// "loved"), ordered best-first by a crude term-density score.
QList<SearchHit> fixtureSearch(const QString& andQuery)
{
    const QStringList terms = andQuery.split(QLatin1Char(' '), Qt::SkipEmptyParts);
    QList<SearchHit> out;
    if (terms.isEmpty()) return out;

    for (const FixtureVerse& v : kFixture) {
        const QString text = QString::fromUtf8(v.text).toLower();
        bool all = true;
        for (const QString& t : terms) {
            if (!text.contains(t)) { all = false; break; }
        }
        if (!all) continue;

        SearchHit h;
        h.book            = QString::fromUtf8(v.book);
        h.chapter         = v.chapter;
        h.verse           = v.verse;
        h.text            = QString::fromUtf8(v.text);
        h.translationCode = QStringLiteral("KJV");
        // Lower is better, matching bm25's ordering. Shorter verses carrying
        // the same terms rank higher, which is what bm25 does too.
        h.score           = double(text.size()) / double(terms.size());
        out.append(h);
    }

    std::sort(out.begin(), out.end(),
              [](const SearchHit& a, const SearchHit& b) { return a.score < b.score; });
    return out;
}

QuotationMatcher makeFixtureMatcher()
{
    QuotationMatcher m;
    m.setSearch(fixtureSearch);
    return m;
}

bool hasRef(const QList<HeardReference>& refs, const QString& reference)
{
    for (const HeardReference& r : refs)
        if (r.reference == reference) return true;
    return false;
}

HeardReference refFor(const QList<HeardReference>& refs, const QString& reference)
{
    for (const HeardReference& r : refs)
        if (r.reference == reference) return r;
    return {};
}

}  // namespace

class TestQuotationMatcher : public QObject
{
    Q_OBJECT

private slots:

    // ── contentWords ────────────────────────────────────────────────────

    void content_words_drop_function_words()
    {
        const QStringList w = QuotationMatcher::contentWords(
            QStringLiteral("For God so loved the world, that he gave his only begotten Son"));
        QCOMPARE(w, QStringList({ QStringLiteral("god"),      QStringLiteral("loved"),
                                  QStringLiteral("world"),    QStringLiteral("gave"),
                                  QStringLiteral("begotten"), QStringLiteral("son") }));
    }

    // Numbers belong to the citation path. Leaving them in would AND digits
    // against verse prose and match nothing at all.
    void content_words_drop_spoken_and_written_numbers()
    {
        const QStringList w = QuotationMatcher::contentWords(
            QStringLiteral("john three sixteen for god so loved the world"));
        QCOMPARE(w, QStringList({ QStringLiteral("john"),  QStringLiteral("god"),
                                  QStringLiteral("loved"), QStringLiteral("world") }));

        const QStringList d = QuotationMatcher::contentWords(
            QStringLiteral("romans 8:28 all things work together"));
        QCOMPARE(d, QStringList({ QStringLiteral("romans"), QStringLiteral("things"),
                                  QStringLiteral("work"),   QStringLiteral("together") }));
    }

    void content_words_drop_words_below_the_trigram_floor()
    {
        // "am" and "i" are unindexable by trigram regardless of meaning.
        const QStringList w = QuotationMatcher::contentWords(
            QStringLiteral("I am the way"));
        QVERIFY(!w.contains(QStringLiteral("i")));
        QVERIFY(!w.contains(QStringLiteral("am")));
    }

    // ── Matching ────────────────────────────────────────────────────────

    void a_verbatim_quote_resolves_to_its_verse()
    {
        auto m = makeFixtureMatcher();
        const auto refs = m.match(
            QStringLiteral("for god so loved the world that he gave his only begotten son"), 0);

        QCOMPARE(refs.size(), 1);
        QCOMPARE(refs.first().reference,  QStringLiteral("John 3:16"));
        QCOMPARE(refs.first().kind,       QStringLiteral("quotation"));
        QCOMPARE(refs.first().tier,       QStringLiteral("high"));
        QCOMPARE(refs.first().verseStart, 16);
        QCOMPARE(refs.first().verseEnd,   16);
    }

    // Three content words, all of them the verse's, and no other verse has
    // all three. The word-count-only rule the doc originally implied would
    // have discarded the second most quoted verse in the Bible.
    void a_short_famous_verse_still_resolves()
    {
        auto m = makeFixtureMatcher();
        const auto refs = m.match(QStringLiteral("the lord is my shepherd i shall not want"), 0);

        QVERIFY(hasRef(refs, QStringLiteral("Psalms 23:1")));
        // Coverage is total: they said every distinctive word the verse has.
        QCOMPARE(refFor(refs, QStringLiteral("Psalms 23:1")).tier, QStringLiteral("high"));
    }

    // The dominance gate doing its job. "love one another ... as I have loved
    // you" is in both John 13:34 and John 15:12 — one vote each, no winner,
    // so it is a quotation of neither.
    void a_phrase_shared_by_two_verses_is_rejected()
    {
        auto m = makeFixtureMatcher();
        const auto refs = m.match(
            QStringLiteral("love one another as i have loved you"), 0);

        QVERIFY2(refs.isEmpty(),
                 "a phrase two verses share equally identifies neither");
    }

    // The other half of dominance: a lopsided split IS an answer. This is the
    // shape a fourteen-translation library produces constantly — the right
    // verse in eleven translations plus one paraphrase of something else.
    void a_lopsided_split_still_resolves()
    {
        // Nine rows for John 3:16, one for a decoy. Real search results look
        // exactly like this once paraphrase translations are installed.
        QuotationMatcher m;
        m.setSearch([](const QString&) {
            QList<SearchHit> hits;
            for (int i = 0; i < 9; ++i) {
                SearchHit h;
                h.book = QStringLiteral("John"); h.chapter = 3; h.verse = 16;
                h.text = QString::fromUtf8(kFixture[0].text);
                h.score = 1.0 + i;
                hits.append(h);
            }
            SearchHit decoy;
            decoy.book = QStringLiteral("2 Peter"); decoy.chapter = 3; decoy.verse = 5;
            decoy.text = QStringLiteral("a loose paraphrase that happens to share words");
            decoy.score = 99.0;
            hits.append(decoy);
            return hits;
        });

        const auto refs = m.match(
            QStringLiteral("for god so loved the world that he gave his only begotten son"), 0);
        QVERIFY(!refs.isEmpty());
        QCOMPARE(refs.first().reference, QStringLiteral("John 3:16"));
    }

    void ordinary_speech_matches_nothing()
    {
        auto m = makeFixtureMatcher();
        QVERIFY(m.match(QStringLiteral("good morning church it is wonderful to see you"), 0).isEmpty());
        QVERIFY(m.match(QStringLiteral("please stand for the offering"), 0).isEmpty());
        QVERIFY(m.match(QStringLiteral("we will take a short break now"), 0).isEmpty());
    }

    void too_few_content_words_never_queries()
    {
        bool queried = false;
        QuotationMatcher m;
        m.setSearch([&](const QString&) { queried = true; return QList<SearchHit>(); });

        m.match(QStringLiteral("the lord is good"), 0);   // "lord", "good"
        QVERIFY2(!queried, "a two-word phrase is not worth an FTS query");
    }

    void a_matcher_with_no_search_installed_is_inert()
    {
        QuotationMatcher m;
        QVERIFY(!m.hasSearch());
        QVERIFY(m.match(QStringLiteral("for god so loved the world that he gave"), 0).isEmpty());
    }

    // A continuous reading walks the window across neighbouring verses. The
    // operator wants one entry, not one per window.
    void adjacent_verses_collapse_to_one_entry()
    {
        auto m = makeFixtureMatcher();
        const auto refs = m.match(
            QStringLiteral("the lord is my shepherd i shall not want he maketh me "
                           "to lie down in green pastures he leadeth me beside the "
                           "still waters"), 0);

        // Psalms 23:1 and 23:2 are neighbours; only one survives.
        int inPsalm23 = 0;
        for (const HeardReference& r : refs)
            if (r.book == QStringLiteral("Psalms") && r.chapter == 23) ++inPsalm23;
        QCOMPARE(inPsalm23, 1);
    }

    void one_utterance_emits_at_most_two_references()
    {
        auto m = makeFixtureMatcher();
        const auto refs = m.match(
            QStringLiteral("in the beginning god created the heaven and the earth "
                           "i can do all things through christ which strengtheneth me "
                           "and we know that all things work together for good to them "
                           "that love god"), 0);
        QVERIFY(refs.size() <= m.config().maxEmits);
    }

    void the_query_budget_is_respected()
    {
        int queries = 0;
        QuotationMatcher m;
        m.setSearch([&](const QString& q) { ++queries; return fixtureSearch(q); });

        // Long enough to slide many windows past the cap.
        m.match(QStringLiteral("alpha bravo charlie delta echo foxtrot golf hotel india "
                               "juliet kilo lima mike november oscar papa quebec romeo "
                               "sierra tango uniform victor whiskey xray yankee zulu"), 0);
        QVERIFY2(queries <= m.config().maxWindows,
                 qPrintable(QStringLiteral("issued %1 queries, budget is %2")
                                .arg(queries).arg(m.config().maxWindows)));
    }

    void timestamps_pass_through()
    {
        auto m = makeFixtureMatcher();
        const auto refs = m.match(
            QStringLiteral("for god so loved the world that he gave his only begotten son"),
            123456);
        QCOMPARE(refs.size(), 1);
        QCOMPARE(refs.first().atMs, qint64(123456));
    }

    // ── The real corpus ─────────────────────────────────────────────────

    void real_corpus_resolves_famous_quotations()
    {
        if (!QFile::exists(db::DbPaths::biblesDbPath()))
            QSKIP("no bibles.sqlite on this machine; skipping real-corpus tests");

        BibleService bible;
        if (bible.translations().isEmpty())
            QSKIP("bibles.sqlite has no translations installed");

        QuotationMatcher m;
        m.setSearch([&](const QString& q) { return bible.search(q, QString()); });

        struct Case { const char* said; const char* expect; };
        const Case cases[] = {
            { "for god so loved the world that he gave his only begotten son",
              "John 3:16" },
            { "i can do all things through christ which strengtheneth me",
              "Philippians 4:13" },
            { "in the beginning god created the heaven and the earth",
              "Genesis 1:1" },
            { "trust in the lord with all thine heart and lean not unto thine own "
              "understanding",
              "Proverbs 3:5" },
        };

        for (const Case& c : cases) {
            const auto refs = m.match(QString::fromUtf8(c.said), 0);
            const QString want = QString::fromUtf8(c.expect);
            QVERIFY2(hasRef(refs, want),
                     qPrintable(QStringLiteral("\"%1\" did not resolve to %2 (got %3)")
                                    .arg(QString::fromUtf8(c.said), want,
                                         refs.isEmpty()
                                             ? QStringLiteral("nothing")
                                             : refs.first().reference)));
        }
    }

    // The half that actually matters. Ordinary sermon speech, run against all
    // 31,102 verses, must produce nothing — a false quotation match pushes a
    // wrong verse into the operator's Preview pane.
    void real_corpus_does_not_fire_on_ordinary_speech()
    {
        if (!QFile::exists(db::DbPaths::biblesDbPath()))
            QSKIP("no bibles.sqlite on this machine; skipping real-corpus tests");

        BibleService bible;
        if (bible.translations().isEmpty())
            QSKIP("bibles.sqlite has no translations installed");

        QuotationMatcher m;
        m.setSearch([&](const QString& q) { return bible.search(q, QString()); });

        const QStringList speech = {
            QStringLiteral("good morning church it is wonderful to see everybody here today"),
            QStringLiteral("before we begin i want to thank the worship team for leading us"),
            QStringLiteral("there are envelopes in the back if you would like to give"),
            QStringLiteral("we are going to be starting a new series next sunday morning"),
            QStringLiteral("please remember the family in your prayers this week"),
            QStringLiteral("the youth group is meeting on wednesday evening at seven"),
        };

        for (const QString& s : speech) {
            const auto refs = m.match(s, 0);
            if (!refs.isEmpty()) {
                QFAIL(qPrintable(
                    QStringLiteral("ordinary speech fired: \"%1\" -> %2 (tier %3, matched on \"%4\")")
                        .arg(s, refs.first().reference, refs.first().tier,
                             refs.first().heardText)));
            }
        }
    }

    // This is the measurement that decided the architecture. A quotation pass
    // over the real 285 MB index costs tens to low hundreds of milliseconds —
    // an order of magnitude past architecture.md §3's 5 ms sync threshold and
    // past the 20 ms detector budget in docs/narration.md §9. That is why
    // NarrationService runs this pass on its own thread over its own SQLite
    // connection instead of inline.
    //
    // The assertion is a regression bound, not a target: it catches the pass
    // becoming pathologically slow (an index rebuild gone wrong, a runaway
    // window count) without pretending an FTS scan belongs on the UI thread.
    void real_corpus_latency_is_why_this_runs_off_thread()
    {
        if (!QFile::exists(db::DbPaths::biblesDbPath()))
            QSKIP("no bibles.sqlite on this machine; skipping real-corpus tests");

        BibleService bible;
        if (bible.translations().isEmpty())
            QSKIP("bibles.sqlite has no translations installed");

        QuotationMatcher m;
        m.setSearch([&](const QString& q) { return bible.search(q, QString()); });

        const QString utterance =
            QStringLiteral("for god so loved the world that he gave his only begotten son "
                           "that whosoever believeth in him should not perish but have "
                           "everlasting life");

        m.match(utterance, 0);   // warm the prepared statements and page cache

        QElapsedTimer t;
        t.start();
        for (int i = 0; i < 5; ++i) m.match(utterance, 0);
        const qint64 perPass = t.elapsed() / 5;

        qInfo().noquote()
            << QStringLiteral("quotation pass over %1 translations: %2 ms "
                              "(off-thread; see NarrationService::QuotationWorker)")
                   .arg(bible.translations().size()).arg(perPass);

        QVERIFY2(perPass < 600,
                 qPrintable(QStringLiteral("%1 ms per pass is pathological even off-thread")
                                .arg(perPass)));
    }
};

// Not QTEST_MAIN: DbPaths resolves through QStandardPaths::AppDataLocation,
// which is built from the organisation and application names. Without them
// the real-corpus half would look for bibles.sqlite beside a directory named
// after this test binary, find nothing, and QSKIP — passing green while never
// touching the corpus it exists to exercise.
int main(int argc, char* argv[])
{
    QCoreApplication app(argc, argv);
    QCoreApplication::setOrganizationName(QStringLiteral("Voyager Labs"));
    QCoreApplication::setApplicationName(QStringLiteral("Crater"));

    TestQuotationMatcher tc;
    return QTest::qExec(&tc, argc, argv);
}

#include "test_quotation_matcher.moc"
