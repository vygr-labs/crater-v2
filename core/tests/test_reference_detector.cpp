// Tests for crater::narration — spoken-number normalization and the citation
// detector (docs/narration.md §4, phase 0).
//
// Run via CTest: `ctest --test-dir <build-dir> -R reference_detector --output-on-failure`
// Or directly:   `./test_reference_detector` from the build output directory.
//
// Coverage philosophy: this is the component that decides what a preacher
// meant, and every wrong answer is a wrong verse in front of a congregation.
// So the suite is weighted toward the two failure modes that matter — the
// adjacency rule ("three sixteen" vs "twenty two") that the most-quoted verse
// in the Bible depends on, and the false-positive gating that keeps ordinary
// sermon prose ("John was there") off the screen.
//
// Fixtures are transcripts, not audio. The detector is pure by design so this
// suite needs no model, no microphone, and no database.

#include <QObject>
#include <QString>
#include <QTest>

#include "crater/value/HeardReference.h"
#include "narration/CitationDetector.h"
#include "narration/SpokenNumbers.h"

using crater::HeardReference;
using crater::narration::CitationDetector;
using crater::narration::RefContext;
using crater::narration::parseNumberPhrase;
using crater::narration::tokenize;

namespace {

// Parse the first number phrase in a string. Returns -1 when none parses.
int firstNumber(const QString& s)
{
    const QStringList w = tokenize(s);
    const auto        p = parseNumberPhrase(w, 0);
    return p ? p->value : -1;
}

// Every number phrase in a string, in order — the view the detector's
// adjacency rule actually operates on.
QList<int> allNumbers(const QString& s)
{
    const QStringList w = tokenize(s);
    QList<int>        out;
    int               i = 0;
    while (i < w.size()) {
        if (const auto p = parseNumberPhrase(w, i)) {
            out.append(p->value);
            i = p->endIdx;
        } else {
            ++i;
        }
    }
    return out;
}

// A validator standing in for the Bible DB: knows only that Psalm 1 is short
// and Psalm 119 is long, which is the exact fact the §11 ambiguity rule needs.
bool psalmValidator(const QString& book, int chapter, int verse)
{
    if (book != QStringLiteral("Psalms")) return true;
    if (chapter == 1)   return verse >= 1 && verse <= 6;
    if (chapter == 119) return verse >= 1 && verse <= 176;
    return chapter >= 1 && chapter <= 150;
}

}  // namespace

class TestReferenceDetector : public QObject
{
    Q_OBJECT

private slots:

    // ── Spoken numbers ──────────────────────────────────────────────────

    void numbers_units_and_teens()
    {
        QCOMPARE(firstNumber(QStringLiteral("three")),    3);
        QCOMPARE(firstNumber(QStringLiteral("sixteen")),  16);
        QCOMPARE(firstNumber(QStringLiteral("nineteen")), 19);
    }

    void numbers_tens_compose_with_units()
    {
        QCOMPARE(firstNumber(QStringLiteral("twenty two")),   22);
        QCOMPARE(firstNumber(QStringLiteral("twenty-two")),   22);
        QCOMPARE(firstNumber(QStringLiteral("forty five")),   45);
        QCOMPARE(firstNumber(QStringLiteral("ninety nine")),  99);
        QCOMPARE(firstNumber(QStringLiteral("twenty")),       20);
    }

    void numbers_hundreds()
    {
        QCOMPARE(firstNumber(QStringLiteral("one hundred nineteen")),     119);
        QCOMPARE(firstNumber(QStringLiteral("one hundred and nineteen")), 119);
        QCOMPARE(firstNumber(QStringLiteral("one hundred fifty")),        150);
        QCOMPARE(firstNumber(QStringLiteral("two hundred")),              200);
    }

    // The load-bearing rule. "three sixteen" must stay two numbers so the
    // detector can read it as chapter:verse, while "twenty two" must stay one.
    void numbers_adjacency_splits_chapter_and_verse()
    {
        QCOMPARE(allNumbers(QStringLiteral("three sixteen")),  (QList<int>{ 3, 16 }));
        QCOMPARE(allNumbers(QStringLiteral("twenty two")),     (QList<int>{ 22 }));
        QCOMPARE(allNumbers(QStringLiteral("eight twenty")),   (QList<int>{ 8, 20 }));
        QCOMPARE(allNumbers(QStringLiteral("one nineteen")),   (QList<int>{ 1, 19 }));
    }

    void numbers_digits_never_compose()
    {
        QCOMPARE(allNumbers(QStringLiteral("3 16")),  (QList<int>{ 3, 16 }));
        QCOMPARE(allNumbers(QStringLiteral("3:16")),  (QList<int>{ 3, 16 }));
        QCOMPARE(allNumbers(QStringLiteral("119")),   (QList<int>{ 119 }));
    }

    void numbers_ordinals()
    {
        QCOMPARE(firstNumber(QStringLiteral("third")),        3);
        QCOMPARE(firstNumber(QStringLiteral("twenty third")), 23);
        QCOMPARE(firstNumber(QStringLiteral("23rd")),         23);
    }

    void numbers_reject_non_numbers()
    {
        QCOMPARE(firstNumber(QStringLiteral("hundred")),  -1);
        QCOMPARE(firstNumber(QStringLiteral("and four")), -1);
        QCOMPARE(firstNumber(QStringLiteral("brethren")), -1);
    }

    // ── Citations ───────────────────────────────────────────────────────

    void citation_book_chapter_verse_spoken()
    {
        CitationDetector d;
        const auto r = d.detect(
            QStringLiteral("turn with me to first corinthians chapter thirteen verse four"), 0);
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].book,       QStringLiteral("1 Corinthians"));
        QCOMPARE(r[0].chapter,    13);
        QCOMPARE(r[0].verseStart, 4);
        QCOMPARE(r[0].reference,  QStringLiteral("1 Corinthians 13:4"));
        QCOMPARE(r[0].tier,       QStringLiteral("certain"));
        QCOMPARE(r[0].kind,       QStringLiteral("citation"));
    }

    // The single most common spoken reference in preaching.
    void citation_bare_adjacency()
    {
        CitationDetector d;
        const auto r = d.detect(QStringLiteral("john three sixteen"), 0);
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].reference, QStringLiteral("John 3:16"));
    }

    void citation_digits_from_recognizer()
    {
        CitationDetector d;
        const auto r = d.detect(QStringLiteral("look at john 3:16"), 0);
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].reference, QStringLiteral("John 3:16"));
    }

    // "third john" is a book, not John chapter 3. Longest-first book matching
    // is what makes this work; if it regresses, this is the canary.
    void citation_ordinal_book_beats_chapter_reading()
    {
        CitationDetector d;
        const auto r = d.detect(QStringLiteral("turn to third john verse four"), 0);
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].book,       QStringLiteral("3 John"));
        QCOMPARE(r[0].verseStart, 4);
    }

    // Jude, Philemon, Obadiah, 2 John and 3 John have no chapter to say, so
    // the verse follows the book directly. Parsers that require a chapter
    // number silently drop the verse on every one of them.
    void citation_single_chapter_book_has_no_chapter_number()
    {
        CitationDetector d;
        const auto r = d.detect(QStringLiteral("turn to jude verse nine"), 0);
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].book,       QStringLiteral("Jude"));
        QCOMPARE(r[0].chapter,    1);
        QCOMPARE(r[0].verseStart, 9);
        QCOMPARE(r[0].reference,  QStringLiteral("Jude 1:9"));
    }

    void citation_chapter_only()
    {
        CitationDetector d;
        const auto r = d.detect(QStringLiteral("turn to romans chapter eight"), 0);
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].book,       QStringLiteral("Romans"));
        QCOMPARE(r[0].chapter,    8);
        QCOMPARE(r[0].verseStart, 0);
        QCOMPARE(r[0].reference,  QStringLiteral("Romans 8"));
    }

    void citation_verse_range()
    {
        CitationDetector d;
        const auto r = d.detect(
            QStringLiteral("ephesians chapter two verses eight through ten"), 0);
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].book,       QStringLiteral("Ephesians"));
        QCOMPARE(r[0].chapter,    2);
        QCOMPARE(r[0].verseStart, 8);
        QCOMPARE(r[0].verseEnd,   10);
    }

    void citation_multi_word_book()
    {
        CitationDetector d;
        const auto r = d.detect(QStringLiteral("song of solomon chapter two verse one"), 0);
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].book, QStringLiteral("Song of Solomon"));
    }

    void citation_ordinal_before_book()
    {
        CitationDetector d;
        const auto r = d.detect(QStringLiteral("the twenty third psalm"), 0);
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].book,    QStringLiteral("Psalms"));
        QCOMPARE(r[0].chapter, 23);
    }

    void citation_two_references_in_one_utterance()
    {
        CitationDetector d;
        const auto r = d.detect(
            QStringLiteral("we saw john three sixteen and now romans chapter five verse eight"), 0);
        QCOMPARE(r.size(), 2);
        QCOMPARE(r[0].reference, QStringLiteral("John 3:16"));
        QCOMPARE(r[1].reference, QStringLiteral("Romans 5:8"));
    }

    void citation_deduped_within_utterance()
    {
        CitationDetector d;
        const auto r = d.detect(QStringLiteral("john three sixteen john three sixteen"), 0);
        QCOMPARE(r.size(), 1);
    }

    // ── False-positive gating ───────────────────────────────────────────

    // The whole reason cue gating exists. A congregation must never see a
    // verse because the preacher told a story about someone named Mark.
    void gating_bare_book_name_in_prose_does_not_fire()
    {
        CitationDetector d;
        QVERIFY(d.detect(QStringLiteral("john was there when mark said it"), 0).isEmpty());
        QVERIFY(d.detect(QStringLiteral("james from the worship team"), 0).isEmpty());
    }

    void gating_bare_book_with_cue_fires_at_lower_tier()
    {
        CitationDetector d;
        const auto r = d.detect(QStringLiteral("turn to romans"), 0);
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].book, QStringLiteral("Romans"));
        QCOMPARE(r[0].tier, QStringLiteral("high"));
    }

    void gating_no_scripture_content_is_silent()
    {
        CitationDetector d;
        QVERIFY(d.detect(QStringLiteral("good morning church it is good to see you"), 0).isEmpty());
        QVERIFY(d.detect(QString(), 0).isEmpty());
    }

    // ── Context ─────────────────────────────────────────────────────────

    void context_resolves_bare_verse()
    {
        CitationDetector d;
        d.detect(QStringLiteral("turn to romans chapter eight verse one"), 0);

        const auto r = d.detect(QStringLiteral("now look at verse nine"), 1000);
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].book,       QStringLiteral("Romans"));
        QCOMPARE(r[0].chapter,    8);
        QCOMPARE(r[0].verseStart, 9);
        QCOMPARE(r[0].tier,       QStringLiteral("high"));
    }

    void context_resolves_next_verse()
    {
        CitationDetector d;
        d.detect(QStringLiteral("romans chapter eight verse one"), 0);

        const auto r = d.detect(QStringLiteral("and the next verse"), 500);
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].verseStart, 2);
    }

    void context_without_prior_reference_is_silent()
    {
        CitationDetector d;
        QVERIFY(d.detect(QStringLiteral("look at verse nine"), 0).isEmpty());
    }

    // A verse number recovered from a chapter we left ten minutes ago is a
    // guess dressed up as a fact.
    void context_expires()
    {
        CitationDetector d;
        d.detect(QStringLiteral("romans chapter eight verse one"), 0);

        const qint64 stale = CitationDetector::kContextTtlMs + 1;
        QVERIFY(d.detect(QStringLiteral("look at verse nine"), stale).isEmpty());
    }

    void context_follows_the_latest_reference()
    {
        CitationDetector d;
        d.detect(QStringLiteral("romans chapter eight verse one"), 0);
        d.detect(QStringLiteral("turn to ephesians chapter two verse eight"), 1000);

        const auto r = d.detect(QStringLiteral("verse nine"), 2000);
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].book,    QStringLiteral("Ephesians"));
        QCOMPARE(r[0].chapter, 2);
    }

    // ── Ambiguous composition (docs/narration.md §11) ───────────────────

    // "Psalm one nineteen" reads literally as Psalm 1:19, which doesn't exist.
    // With a validator present the detector should prefer Psalm 119.
    void ambiguity_psalm_119_resolved_by_validator()
    {
        CitationDetector d;
        d.setValidator(psalmValidator);

        const auto r = d.detect(QStringLiteral("turn to psalm one nineteen"), 0);
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].book,       QStringLiteral("Psalms"));
        QCOMPARE(r[0].chapter,    119);
        QCOMPARE(r[0].verseStart, 0);
    }

    // The same shape where the literal reading DOES exist must be left alone.
    void ambiguity_valid_literal_reading_is_kept()
    {
        CitationDetector d;
        d.setValidator(psalmValidator);

        const auto r = d.detect(QStringLiteral("psalm one verse five"), 0);
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].chapter,    1);
        QCOMPARE(r[0].verseStart, 5);
    }

    // An explicit "verse" is the preacher disambiguating for us. Honour it
    // even when the resulting reference fails validation.
    void ambiguity_explicit_verse_keyword_blocks_composition()
    {
        CitationDetector d;
        d.setValidator(psalmValidator);

        const auto r = d.detect(QStringLiteral("psalm one verse nineteen"), 0);
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].chapter,    1);
        QCOMPARE(r[0].verseStart, 19);
    }

    // Without a validator the detector is pure and must not invent facts.
    void ambiguity_without_validator_keeps_literal_reading()
    {
        CitationDetector d;
        const auto r = d.detect(QStringLiteral("turn to psalm one nineteen"), 0);
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].chapter,    1);
        QCOMPARE(r[0].verseStart, 19);
    }

    // ── Recognizer mangling ─────────────────────────────────────────────

    // Fuzzy book matching is readmitted only when "chapter" follows, which is
    // strong enough evidence to justify guessing at a garbled name.
    void mangled_book_rescued_when_chapter_follows()
    {
        CitationDetector d;
        const auto r = d.detect(QStringLiteral("phillipians chapter four verse thirteen"), 0);
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].book,       QStringLiteral("Philippians"));
        QCOMPARE(r[0].chapter,    4);
        QCOMPARE(r[0].verseStart, 13);
    }

    // The rescue's blast radius. lookupBook matches on subsequence, so "in"
    // resolves to 1 K-i-n-gs and "the" to o-t-H-E-r books. Letting a function
    // word through would emit a fabricated reference at "certain" tier, which
    // is the worst output this subsystem can produce.
    void mangled_rescue_rejects_function_words()
    {
        CitationDetector d;
        QVERIFY(d.detect(QStringLiteral("in chapter three we see this"), 0).isEmpty());
        QVERIFY(d.detect(QStringLiteral("the chapter we read last week"), 0).isEmpty());
        QVERIFY(d.detect(QStringLiteral("that chapter four times over"), 0).isEmpty());
    }

    // A correctly spelled book must be taken by the strict table, never by the
    // fuzzy rescue. If this starts routing through the rescue, precision on
    // every other test in this file is no longer what it appears to be.
    void mangled_rescue_does_not_shadow_exact_matches()
    {
        CitationDetector d;
        const auto r = d.detect(QStringLiteral("romans chapter eight verse twenty eight"), 0);
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].book,       QStringLiteral("Romans"));
        QCOMPARE(r[0].chapter,    8);
        QCOMPARE(r[0].verseStart, 28);
    }
};

QTEST_GUILESS_MAIN(TestReferenceDetector)
#include "test_reference_detector.moc"
