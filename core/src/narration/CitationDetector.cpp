#include "narration/CitationDetector.h"

#include "import/CanonicalBibleBooks.h"
#include "narration/SpokenNumbers.h"

#include <QHash>
#include <QSet>

#include <algorithm>
#include <utility>

namespace crater::narration {
namespace {

// Longest spoken book form in tokens — "acts of the apostles".
constexpr int kMaxBookTokens = 4;

// Strict spoken-form to canonical-name table.
//
// This deliberately does NOT go through import::lookupBook. That function's
// fuzzy tier (subsequence + bounded edit distance) is tuned for an operator
// typing into a search box, where a wrong guess costs one keystroke to
// correct. Run over arbitrary sermon prose it matches something on nearly
// every clause — "in" is a subsequence of "1 Kings". Scanning needs exact
// membership; lookupBook's tolerance comes back deliberately and narrowly in
// rescueBookBefore(), where surrounding structure has established intent.
const QHash<QString, QString>& spokenBooks()
{
    static const QHash<QString, QString> table = []() {
        QHash<QString, QString> m;

        // "1 Samuel" is also spoken "first samuel" / "one samuel" / "1st samuel".
        static const char* const ordinalForms[3][3] = {
            { "first",  "one",   "1st" },
            { "second", "two",   "2nd" },
            { "third",  "three", "3rd" },
        };

        for (const auto& b : crater::import::allCanonicalBooks()) {
            const QStringList toks = tokenize(b.name);
            if (toks.isEmpty()) continue;
            m.insert(toks.join(QLatin1Char(' ')), b.name);

            bool      ok   = false;
            const int lead = toks.first().toInt(&ok);
            if (ok && lead >= 1 && lead <= 3 && toks.size() >= 2) {
                const QString rest = QStringList(toks.mid(1)).join(QLatin1Char(' '));
                for (const char* const form : ordinalForms[lead - 1])
                    m.insert(QString::fromLatin1(form) + QLatin1Char(' ') + rest, b.name);
            }
        }

        // Spoken variants not derivable from the canonical name. The probe
        // goes through lookupBook so whatever canonical spelling the rest of
        // the codebase uses is what we store — narration must never invent a
        // book name the Bible DB doesn't answer to.
        static const std::pair<const char*, const char*> aliases[] = {
            { "psalm",                "Psalms"          },
            { "psalms",               "Psalms"          },
            { "song of songs",        "Song of Solomon" },
            { "canticles",            "Song of Solomon" },
            { "revelations",          "Revelation"      },
            { "acts of the apostles", "Acts"            },
        };
        for (const auto& [spoken, probe] : aliases) {
            if (const auto meta = crater::import::lookupBook(QString::fromLatin1(probe)))
                m.insert(QString::fromLatin1(spoken), meta->name);
        }
        return m;
    }();
    return table;
}

struct BookMatch
{
    QString canonical;
    int     endIdx = 0;
};

// Longest-first, so "third john" beats "john" and "song of solomon" isn't
// truncated. Getting this order wrong turns 3 John into John 3.
std::optional<BookMatch> matchBookAt(const QStringList& w, int i)
{
    const int maxLen = std::min(kMaxBookTokens, int(w.size()) - i);
    for (int len = maxLen; len >= 1; --len) {
        const QString key = QStringList(w.mid(i, len)).join(QLatin1Char(' '));
        if (const auto it = spokenBooks().constFind(key); it != spokenBooks().constEnd())
            return BookMatch{ *it, i + len };
    }
    return std::nullopt;
}

// Intent cues. Required before a bare book name with no numbers after it,
// because book names are also ordinary English words and ordinary people's
// names. "John was there" and "Mark said" must not put anything on a screen.
//
// Declared up here rather than beside the main loop because the fuzzy rescue
// paths below consult them too: a cue is most of what licenses guessing at a
// mangled name.
const QList<QStringList>& cuePhrases()
{
    static const QList<QStringList> t = {
        { QStringLiteral("turn"), QStringLiteral("to") },
        { QStringLiteral("turn"), QStringLiteral("with"), QStringLiteral("me"), QStringLiteral("to") },
        { QStringLiteral("turn"), QStringLiteral("over"), QStringLiteral("to") },
        { QStringLiteral("look"), QStringLiteral("at") },
        { QStringLiteral("looking"), QStringLiteral("at") },
        { QStringLiteral("open"), QStringLiteral("to") },
        { QStringLiteral("open"), QStringLiteral("your"), QStringLiteral("bibles"), QStringLiteral("to") },
        { QStringLiteral("found"), QStringLiteral("in") },
        { QStringLiteral("book"), QStringLiteral("of") },
        { QStringLiteral("says"), QStringLiteral("in") },
        { QStringLiteral("according"), QStringLiteral("to") },
        { QStringLiteral("read"), QStringLiteral("from") },
        { QStringLiteral("go"), QStringLiteral("to") },
        { QStringLiteral("back"), QStringLiteral("to") },
        { QStringLiteral("over"), QStringLiteral("in") },
        { QStringLiteral("text"), QStringLiteral("is") },
    };
    return t;
}

bool hasCueBefore(const QStringList& w, int i)
{
    for (const QStringList& cue : cuePhrases()) {
        const int len   = int(cue.size());
        const int start = i - len;
        if (start < 0) continue;
        bool ok = true;
        for (int k = 0; k < len; ++k) {
            if (w[start + k] != cue[k]) { ok = false; break; }
        }
        if (ok) return true;
    }
    return false;
}

bool isChapterKeyword(const QString& w)
{
    return w == QStringLiteral("chapter") || w == QStringLiteral("chapters");
}

bool isVerseKeyword(const QString& w)
{
    return w == QStringLiteral("verse") || w == QStringLiteral("verses")
           || w == QStringLiteral("vs");
}

bool isRangeKeyword(const QString& w)
{
    return w == QStringLiteral("through") || w == QStringLiteral("thru")
           || w == QStringLiteral("to") || w == QStringLiteral("until")
           || w == QStringLiteral("till");
}

// Is what follows the shape of a citation? A cue in front of a word is only
// half an argument — "turn to the front" has one. What makes a citation is a
// chapter, a verse, or a number after the name, and requiring one is what
// keeps the near-miss matcher out of ordinary speech.
bool citationStructureFollows(const QStringList& w, int k)
{
    if (k >= int(w.size())) return false;
    if (isChapterKeyword(w[k]) || isVerseKeyword(w[k])) return true;
    return parseNumberPhrase(w, k).has_value();
}

// Words that must never be handed to the fuzzy matcher. Short function words
// are subsequences of half the canon, and a fabricated reference emitted at
// "certain" tier is the worst output this subsystem can produce.
const QSet<QString>& rescueStopwords()
{
    static const QSet<QString> s = {
        QStringLiteral("the"),    QStringLiteral("this"),  QStringLiteral("that"),
        QStringLiteral("then"),   QStringLiteral("them"),  QStringLiteral("they"),
        QStringLiteral("there"),  QStringLiteral("these"), QStringLiteral("those"),
        QStringLiteral("from"),   QStringLiteral("with"),  QStringLiteral("which"),
        QStringLiteral("what"),   QStringLiteral("when"),  QStringLiteral("where"),
        QStringLiteral("your"),   QStringLiteral("our"),   QStringLiteral("and"),
        QStringLiteral("but"),    QStringLiteral("for"),   QStringLiteral("next"),
        QStringLiteral("last"),   QStringLiteral("first"), QStringLiteral("second"),
        QStringLiteral("third"),  QStringLiteral("each"),  QStringLiteral("every"),
        QStringLiteral("same"),   QStringLiteral("other"), QStringLiteral("another"),
        QStringLiteral("whole"),  QStringLiteral("entire"),QStringLiteral("following"),
        QStringLiteral("previous"),QStringLiteral("above"),QStringLiteral("below"),
        QStringLiteral("into"),   QStringLiteral("in"),    QStringLiteral("verse"),
        QStringLiteral("verses"), QStringLiteral("about"), QStringLiteral("through"),
    };
    return s;
}

// How much recogniser slip to forgive, by probe length.
//
// One edit is a mishearing: "join" for "john", "mars" for "mark". Three edits
// on a four-letter word is a different word, which is precisely how
// lookupBook's tolerance ends up calling "page" a near-miss for Jude. Longer
// names earn a second edit because there is more of them left to agree with,
// and "phillipians" needs it.
int slipAllowance(const QString& probe)
{
    return probe.size() >= 8 ? 2 : 1;
}

// Canonical name for a span that is close to a book name without being one.
// The caller supplies the length floor, because how short a probe may safely
// be depends on how much structure surrounds it.
std::optional<QString> nearMissSpan(const QStringList& span, int minChars)
{
    for (const QString& t : span) {
        if (rescueStopwords().contains(t)) return std::nullopt;
    }

    const QString probe = span.join(QLatin1Char(' '));
    if (probe.size() < minChars) return std::nullopt;

    if (const auto meta = crater::import::lookupBookNearMiss(probe, slipAllowance(probe)))
        return meta->name;
    return std::nullopt;
}

// The narrow readmission of fuzzy matching. Only called when the next token
// is "chapter", which is strong enough evidence of intent to guess at a
// mangled name ("phillipians chapter four"). Guarded twice more: no stopword
// tokens, and a minimum probe length, because every real book name that
// survives recognizer mangling is long ("corinthians", "deuteronomy",
// "ephesians") and the short ones are already exact-matched.
//
// The floor relaxes by one character when an intent cue sits immediately
// before the span. "turn with me to join chapter three" has a cue on one side
// and a chapter on the other, and nothing but a book name goes there; a bare
// "join chapter three" has half that evidence, and four letters is short
// enough that half is not enough.
std::optional<BookMatch> rescueBookBefore(const QStringList& w, int chapterIdx)
{
    constexpr int kMinProbeChars = 5;

    for (int len = std::min(3, chapterIdx); len >= 1; --len) {
        const int start = chapterIdx - len;
        const int floorChars =
            hasCueBefore(w, start) ? kMinProbeChars - 1 : kMinProbeChars;
        if (const auto name = nearMissSpan(w.mid(start, len), floorChars))
            return BookMatch{ *name, chapterIdx };
    }
    return std::nullopt;
}

// The same idea for the form with no "chapter" in it at all: "turn with me to
// join three sixteen". Here the evidence is the cue in front and a number
// behind, which is the shape of every spoken citation and of almost no
// ordinary sentence.
//
// Two tokens at most, so a mangled "first corinthans" survives; three would
// start swallowing clauses.
std::optional<BookMatch> nearMissBookAfterCue(const QStringList& w, int i)
{
    constexpr int kMinProbeChars = 4;

    const int maxLen = std::min(2, int(w.size()) - i);
    for (int len = maxLen; len >= 1; --len) {
        if (!citationStructureFollows(w, i + len)) continue;
        if (const auto name = nearMissSpan(w.mid(i, len), kMinProbeChars))
            return BookMatch{ *name, i + len };
    }
    return std::nullopt;
}

QString spanText(const QStringList& w, int from, int to)
{
    from = std::max(0, from);
    to   = std::min(int(w.size()), to);
    if (to <= from) return {};
    return QStringList(w.mid(from, to - from)).join(QLatin1Char(' '));
}

}  // namespace

QList<crater::HeardReference> CitationDetector::detect(const QString& utterance, qint64 nowMs)
{
    QList<crater::HeardReference> out;
    const QStringList w = tokenize(utterance);
    const int         n = int(w.size());
    if (n == 0) return out;

    // Stale context is worse than no context — see kContextTtlMs.
    if (m_ctx.valid() && nowMs - m_ctx.atMs > kContextTtlMs)
        m_ctx = RefContext{};

    const auto validate = [this](const QString& book, int chapter, int verse) {
        return m_validate ? m_validate(book, chapter, verse) : true;
    };

    // NB: not named `emit` — that's a Qt macro and expands to nothing.
    const auto record = [&](const QString& book, int chapter, int verseStart, int verseEnd,
                            const QString& tier, int spanFrom, int spanTo) {
        crater::HeardReference r;
        r.book       = book;
        r.chapter    = chapter;
        r.verseStart = verseStart;
        r.verseEnd   = verseEnd > 0 ? verseEnd : verseStart;
        r.tier       = tier;
        r.kind       = QStringLiteral("citation");
        r.heardText  = spanText(w, spanFrom, spanTo);
        r.atMs       = nowMs;
        r.reference  = verseStart > 0
                           ? QStringLiteral("%1 %2:%3").arg(book).arg(chapter).arg(verseStart)
                           : QStringLiteral("%1 %2").arg(book).arg(chapter);

        // Within one utterance the same reference said twice is one
        // reference. Cross-utterance de-duping is RefContext's job upstream.
        for (const auto& prior : std::as_const(out)) {
            if (prior.reference == r.reference && prior.verseEnd == r.verseEnd) return;
        }

        m_ctx.book      = book;
        m_ctx.chapter   = chapter;
        m_ctx.lastVerse = r.verseEnd;
        m_ctx.atMs      = nowMs;
        out.append(r);
    };

    // Reads an optional "verse N [through M]" tail starting at `k`, advancing
    // it. Shared by the book-first path and the bare-from-context path.
    const auto readVerseTail = [&](int& k, bool& sawVerseKeyword, int& verseStart, int& verseEnd) {
        if (k < n && isVerseKeyword(w[k])) {
            sawVerseKeyword = true;
            ++k;
        }
        const auto vs = parseNumberPhrase(w, k);
        if (!vs) return false;
        verseStart = vs->value;
        k          = vs->endIdx;

        if (k < n && isRangeKeyword(w[k])) {
            if (const auto ve = parseNumberPhrase(w, k + 1); ve && ve->value >= verseStart) {
                verseEnd = ve->value;
                k        = ve->endIdx;
            }
        }
        return true;
    };

    int i = 0;
    while (i < n) {
        // ── Book-first: "first corinthians chapter thirteen verse four" ──
        //
        // Runs before the ordinal form below, and must: "third john" has to
        // resolve as the book 3 John, not as John chapter 3.
        //
        // On an exact miss, and only behind an intent cue, the same branch
        // accepts a near-miss — "turn with me to join chapter three" is what a
        // recognizer does to "john", and refusing it means the single most
        // common citation in English preaching fails on a one-letter slip.
        auto bm        = matchBookAt(w, i);
        bool fuzzyBook = false;
        if (!bm && hasCueBefore(w, i)) {
            bm        = nearMissBookAfterCue(w, i);
            fuzzyBook = bm.has_value();
        }
        if (bm) {
            // A book name we had to guess at is not the evidence a book name
            // we read is. Both are citations; only the exact one is "certain".
            // That difference is the whole safety story here — at "high" a
            // mishearing can reach the Preview pane and no further, even in
            // Auto mode, so the cost of being wrong is an operator glancing at
            // a wrong chip rather than a congregation reading one.
            const QString bookTier =
                fuzzyBook ? QStringLiteral("high") : QStringLiteral("certain");
            const int start = i;
            int       k     = bm->endIdx;

            if (k < n && isChapterKeyword(w[k])) ++k;

            const auto ch              = parseNumberPhrase(w, k);
            int        chapter         = 0;
            bool       sawVerseKeyword = false;
            int        verseStart      = 0;
            int        verseEnd        = 0;
            bool       hasVerse        = false;

            if (ch) {
                chapter  = ch->value;
                k        = ch->endIdx;
                hasVerse = readVerseTail(k, sawVerseKeyword, verseStart, verseEnd);
            } else {
                // No chapter number. A verse keyword straight after the book
                // is the single-chapter-book form — "third john verse four",
                // "jude verse nine". Those books have no chapter to say.
                if (k < n && isVerseKeyword(w[k])) {
                    hasVerse = readVerseTail(k, sawVerseKeyword, verseStart, verseEnd);
                    if (hasVerse) chapter = 1;
                }
                if (!hasVerse) {
                    // Bare book name, no numbers at all. Needs an intent cue.
                    if (hasCueBefore(w, start))
                        record(bm->canonical, 1, 0, 0, QStringLiteral("high"), start, bm->endIdx);
                    i = bm->endIdx;
                    continue;
                }
            }

            // Ambiguous composition — docs/narration.md §11. "Psalm one
            // nineteen" reads literally as 1:19, but Psalm 1 has six verses
            // and Psalm 119 exists. When the literal parse doesn't exist and
            // the two numbers compose into a chapter that does, prefer the
            // composed reading. Skipped when the preacher actually said
            // "verse", because then he meant a verse, and skipped without a
            // validator installed, because then we have no grounds to judge.
            if (ch && hasVerse && !sawVerseKeyword && verseEnd == 0
                && chapter < 10 && verseStart < 100
                && !validate(bm->canonical, chapter, verseStart)) {
                const int composed = chapter * 100 + verseStart;
                if (validate(bm->canonical, composed, 1)) {
                    record(bm->canonical, composed, 0, 0, bookTier, start, k);
                    i = k;
                    continue;
                }
            }

            record(bm->canonical, chapter, hasVerse ? verseStart : 0, verseEnd,
                   bookTier, start, k);
            i = k;
            continue;
        }

        // ── Ordinal-first: "the twenty-third psalm" ─────────────────────
        //
        // Gated on the number being ordinal. A cardinal here would fire on
        // any stray number that happened to precede a book name.
        if (const auto np = parseNumberPhrase(w, i); np && np->ordinal) {
            if (const auto bm = matchBookAt(w, np->endIdx)) {
                record(bm->canonical, np->value, 0, 0, QStringLiteral("certain"), i, bm->endIdx);
                i = bm->endIdx;
                continue;
            }
        }

        // ── Mangled book rescue: "phillipians chapter four" ─────────────
        if (isChapterKeyword(w[i]) && i > 0) {
            if (const auto bm = rescueBookBefore(w, i)) {
                int        k  = i + 1;
                const auto ch = parseNumberPhrase(w, k);
                if (ch) {
                    const int  chapter         = ch->value;
                    k                          = ch->endIdx;
                    bool       sawVerseKeyword = false;
                    int        verseStart      = 0;
                    int        verseEnd        = 0;
                    const bool hasVerse = readVerseTail(k, sawVerseKeyword, verseStart, verseEnd);
                    // "high", not "certain", for the same reason as the
                    // cue-anchored path above: the book name was guessed at.
                    record(bm->canonical, chapter, hasVerse ? verseStart : 0, verseEnd,
                           QStringLiteral("high"), i - 1, k);
                    i = k;
                    continue;
                }
            }
        }

        // ── Bare verse from context: "verse nine", "verses four to seven" ──
        if (isVerseKeyword(w[i]) && m_ctx.valid()) {
            int  k               = i;
            bool sawVerseKeyword = false;
            int  verseStart      = 0;
            int  verseEnd        = 0;
            if (readVerseTail(k, sawVerseKeyword, verseStart, verseEnd)) {
                record(m_ctx.book, m_ctx.chapter, verseStart, verseEnd,
                       QStringLiteral("high"), i, k);
                i = k;
                continue;
            }
        }

        // ── "the next verse" ────────────────────────────────────────────
        if (w[i] == QStringLiteral("next") && i + 1 < n && isVerseKeyword(w[i + 1])
            && m_ctx.valid() && m_ctx.lastVerse > 0) {
            record(m_ctx.book, m_ctx.chapter, m_ctx.lastVerse + 1, 0,
                   QStringLiteral("high"), i, i + 2);
            i += 2;
            continue;
        }

        ++i;
    }

    return out;
}

}  // namespace crater::narration
