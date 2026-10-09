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

// Enough of the Bible's shape to tell real references from misheard ones:
// Romans 8 ends at verse 39, 2 John has one chapter of 13 verses.
bool smallBible(const QString& book, int chapter, int verse)
{
    if (verse < 1) return false;
    if (book == QStringLiteral("Romans"))
        return chapter >= 1 && chapter <= 16 && verse <= (chapter == 8 ? 39 : 33);
    if (book == QStringLiteral("2 John")) return chapter == 1 && verse <= 13;
    if (book == QStringLiteral("John"))   return chapter >= 1 && chapter <= 21 && verse <= 40;
    if (book == QStringLiteral("Jude"))   return chapter == 1 && verse <= 25;
    if (book == QStringLiteral("Obadiah")) return chapter == 1 && verse <= 21;
    return true;
}

bool noneCertain(const QList<HeardReference>& refs)
{
    for (const auto& r : refs)
        if (r.tier == QStringLiteral("certain")) return false;
    return true;
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
        // whisper v1.9.5's base.en writes "three sixteen" this way.
        QCOMPARE(allNumbers(QStringLiteral("3/16")),  (QList<int>{ 3, 16 }));
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

    // "Jude 8" is how the book is cited: the number is the verse. Found in a
    // live run, where "Jude 8", "Jude eight verse 19" and "Obadiah four
    // seventeen" all read as chapters that don't exist and were dropped.
    void single_chapter_book_number_is_the_verse()
    {
        CitationDetector d;
        d.setValidator(smallBible);

        auto r = d.detect(QStringLiteral("turn to jude eight"), 0);
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].reference, QStringLiteral("Jude 1:8"));
        QCOMPARE(r[0].tier,      QStringLiteral("certain"));

        // No cue: it might be a person called Jude, so offered, not projected.
        r = d.detect(QStringLiteral("jude eight"), 0);
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].reference, QStringLiteral("Jude 1:8"));
        QCOMPARE(r[0].tier,      QStringLiteral("high"));

        r = d.detect(QStringLiteral("Jude eight verse 19."), 0);
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].reference, QStringLiteral("Jude 1:19"));
        QCOMPARE(r[0].tier,      QStringLiteral("high"));

        r = d.detect(QStringLiteral("Let's take a turn to the book of Obadiah four seventeen."), 0);
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].reference, QStringLiteral("Obadiah 1:17"));
        QCOMPARE(r[0].tier,      QStringLiteral("high"));

        // The ordinary forms are unchanged.
        r = d.detect(QStringLiteral("turn to jude one twenty"), 0);
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].reference, QStringLiteral("Jude 1:20"));
        QCOMPARE(r[0].tier,      QStringLiteral("certain"));

        // A verse the book doesn't have is still dropped.
        QVERIFY(d.detect(QStringLiteral("turn to jude forty"), 0).isEmpty());
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

    // An explicit "verse" is the preacher disambiguating for us, so it must
    // never be recomposed into Psalm 119. Psalm 1:19 doesn't exist either,
    // and a verse the Bible doesn't contain is a mishearing, so nothing is
    // offered at all.
    void ambiguity_explicit_verse_keyword_blocks_composition()
    {
        CitationDetector d;
        d.setValidator(psalmValidator);

        const auto r = d.detect(QStringLiteral("psalm one verse nineteen"), 0);
        QVERIFY(r.isEmpty());
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
        // A guessed book name is never "certain", whatever the numbers around
        // it look like. At "high" the trust gate will stage it and stop; that
        // is what keeps a mishearing off the audience screen in Auto mode.
        QCOMPARE(r[0].tier,       QStringLiteral("high"));
    }

    // The measured failure from a live microphone run: small.en transcribed
    // "turn with me to john chapter 3 verse 16" as "...to join chapter 3...".
    // One substituted letter, and the single most-cited verse in English
    // preaching stopped being detected at all.
    //
    // Four letters is below the rescue's normal floor. What buys the exception
    // is the intent cue immediately before it — between "turn with me to" and
    // "chapter", nothing but a book name goes.
    void short_mangled_book_rescued_behind_a_cue()
    {
        CitationDetector d;
        const auto r = d.detect(QStringLiteral("turn with me to join chapter 3 verse 16"), 0);
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].book,       QStringLiteral("John"));
        QCOMPARE(r[0].chapter,    3);
        QCOMPARE(r[0].verseStart, 16);
        QCOMPARE(r[0].tier,       QStringLiteral("high"));
    }

    // The same slip in the form with no "chapter" in it, which is at least as
    // common from a pulpit. Here the structure is cue, name, number.
    void short_mangled_book_rescued_before_bare_numbers()
    {
        CitationDetector d;
        const auto r = d.detect(QStringLiteral("turn to join three sixteen"), 0);
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].book,       QStringLiteral("John"));
        QCOMPARE(r[0].chapter,    3);
        QCOMPARE(r[0].verseStart, 16);
        QCOMPARE(r[0].tier,       QStringLiteral("high"));
    }

    // Both halves of the evidence are load-bearing. Without the cue a
    // four-letter probe stays below the floor; without a number or a chapter
    // after it, there is no citation to rescue.
    void short_mangled_book_needs_both_cue_and_numbers()
    {
        CitationDetector d;
        QVERIFY(d.detect(QStringLiteral("join chapter three of the story"), 0).isEmpty());
        QVERIFY(d.detect(QStringLiteral("turn to join us at the front"), 0).isEmpty());
    }

    // The reason this uses lookupBookNearMiss rather than lookupBook. The
    // latter's fuzzy tier accepts edit distance three, which makes "page" a
    // match for Jude and "cover" a match for Hosea — plausible words in a
    // sentence that also contains a number, and catastrophic as citations.
    void near_miss_refuses_ordinary_words_at_distance()
    {
        CitationDetector d;
        QVERIFY(d.detect(QStringLiteral("turn to page four"), 0).isEmpty());
        QVERIFY(d.detect(QStringLiteral("look at point three"), 0).isEmpty());
        QVERIFY(d.detect(QStringLiteral("go to slide twelve"), 0).isEmpty());
    }

    // An exactly spelled book behind a cue must still come back "certain", or
    // the rescue has quietly demoted the whole citation path.
    void exact_book_behind_a_cue_stays_certain()
    {
        CitationDetector d;
        const auto r = d.detect(QStringLiteral("turn with me to john chapter 3 verse 16"), 0);
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].book,       QStringLiteral("John"));
        QCOMPARE(r[0].tier,       QStringLiteral("certain"));
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
    // ── Auto-mode safety ────────────────────────────────────────────────
    //
    // "certain" is what Auto projects without a human. Each phrase here is
    // ordinary speech that used to come back certain.

    // A book name and one number is how English sounds, not only scripture.
    void prose_book_and_number_is_never_certain()
    {
        CitationDetector d;
        QVERIFY(noneCertain(d.detect(QStringLiteral("I called John three times"), 0)));
        QVERIFY(noneCertain(d.detect(QStringLiteral("my job two years ago was hard"), 0)));
        QVERIFY(noneCertain(d.detect(QStringLiteral("the numbers 3 and 4 matter"), 0)));
        QVERIFY(noneCertain(d.detect(QStringLiteral("Mark, two people asked me"), 0)));

        const auto r = d.detect(QStringLiteral("I called John three times"), 0);
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].tier, QStringLiteral("possible"));
    }

    // Book, chapter and verse said aloud is still certain.
    void spoken_book_chapter_verse_is_certain()
    {
        CitationDetector d;
        const auto r = d.detect(QStringLiteral("john three sixteen"), 0);
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].tier, QStringLiteral("certain"));
    }

    void ordinals_in_prose_do_not_fire()
    {
        CitationDetector d;
        QVERIFY(d.detect(QStringLiteral("my first job was at a bank"), 0).isEmpty());
        QVERIFY(d.detect(QStringLiteral("first acts of kindness"), 0).isEmpty());
    }

    // Written punctuation splits "First, John" back into a list item and John.
    void comma_keeps_ordinal_out_of_the_book_name()
    {
        CitationDetector d;
        auto r = d.detect(QStringLiteral("First, John 3:16 says it plainly"), 0);
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].reference, QStringLiteral("John 3:16"));

        r = d.detect(QStringLiteral("Point one, John 3:16."), 0);
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].reference, QStringLiteral("John 3:16"));

        // "3.16" is a British-style verse, not a sentence break.
        r = d.detect(QStringLiteral("First John 3.16"), 0);
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].reference, QStringLiteral("1 John 3:16"));
    }

    // "Romans, verse nine" in the middle of Romans 8 is 8:9, not 1:9.
    void book_then_verse_uses_the_chapter_in_play()
    {
        CitationDetector d;
        d.setContext(RefContext{ QStringLiteral("Romans"), 8, 1, 0 });
        auto r = d.detect(QStringLiteral("Romans, verse nine"), 1000);
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].reference, QStringLiteral("Romans 8:9"));
        QCOMPARE(r[0].tier, QStringLiteral("high"));

        CitationDetector fresh;
        QVERIFY(fresh.detect(QStringLiteral("in John, verse sixteen"), 0).isEmpty());
    }

    // A reference the Bible doesn't contain is a mishearing.
    void nonexistent_references_are_dropped()
    {
        CitationDetector d;
        d.setValidator(smallBible);
        QVERIFY(d.detect(QStringLiteral("romans 8 40"), 0).isEmpty());
        QVERIFY(d.detect(QStringLiteral("two john fourteen six"), 0).isEmpty());
        QVERIFY(d.detect(QStringLiteral("romans chapter twenty"), 0).isEmpty());

        const auto r = d.detect(QStringLiteral("romans 8 39"), 0);
        QCOMPARE(r.size(), 1);
        QCOMPARE(r[0].reference, QStringLiteral("Romans 8:39"));
    }

    void vs_is_not_a_verse()
    {
        CitationDetector d;
        d.setContext(RefContext{ QStringLiteral("Romans"), 8, 1, 0 });
        QVERIFY(d.detect(QStringLiteral("lakers vs 76ers last night"), 1000).isEmpty());
    }

    void and_adds_a_second_verse()
    {
        CitationDetector d;
        const auto r = d.detect(QStringLiteral("romans 8 28 and 31"), 0);
        QCOMPARE(r.size(), 2);
        QCOMPARE(r[0].reference, QStringLiteral("Romans 8:28"));
        QCOMPARE(r[1].reference, QStringLiteral("Romans 8:31"));

        // A count, not a verse.
        const auto c = d.detect(QStringLiteral("romans 8 28 and 5 other verses"), 0);
        QCOMPARE(c.size(), 1);
    }

    void service_numbers_are_not_books()
    {
        CitationDetector d;
        QVERIFY(d.detect(QStringLiteral("let's go back to song three"), 0).isEmpty());
        QVERIFY(d.detect(QStringLiteral("turn to number four in your hymnal"), 0).isEmpty());
    }

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
