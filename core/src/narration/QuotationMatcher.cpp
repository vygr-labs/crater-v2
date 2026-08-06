#include "narration/QuotationMatcher.h"

#include "narration/SpokenNumbers.h"

#include <QHash>

#include <algorithm>
#include <cmath>
#include <utility>

namespace crater::narration {

namespace {

// Function words carry no evidence about WHICH verse is being quoted, and
// including them costs twice over: they widen every AND query toward nothing
// (the trigram index still has to intersect them) and they inflate the
// coverage denominator so a long verse of mostly-connective words would look
// well covered by any sentence at all.
//
// Deliberately includes the King James pronouns and verb forms — thee, thou,
// hath, doth, unto — since our corpus is full of them and they are exactly as
// uninformative as their modern equivalents.
//
// Nothing here is a noun, a name, or a verb of action. That is the line: if a
// word could distinguish one verse from another, it stays.
const QSet<QString>& stopwords()
{
    static const QSet<QString> s = {
        QStringLiteral("a"),     QStringLiteral("about"),  QStringLiteral("after"),
        QStringLiteral("again"), QStringLiteral("against"),QStringLiteral("all"),
        QStringLiteral("also"),  QStringLiteral("am"),     QStringLiteral("an"),
        QStringLiteral("and"),   QStringLiteral("any"),    QStringLiteral("are"),
        QStringLiteral("art"),   QStringLiteral("as"),     QStringLiteral("at"),
        QStringLiteral("be"),    QStringLiteral("because"),QStringLiteral("been"),
        QStringLiteral("before"),QStringLiteral("being"),  QStringLiteral("both"),
        QStringLiteral("but"),   QStringLiteral("by"),     QStringLiteral("can"),
        QStringLiteral("did"),   QStringLiteral("do"),     QStringLiteral("does"),
        QStringLiteral("doth"),  QStringLiteral("down"),   QStringLiteral("each"),
        QStringLiteral("even"),  QStringLiteral("ever"),   QStringLiteral("every"),
        QStringLiteral("for"),   QStringLiteral("from"),   QStringLiteral("had"),
        QStringLiteral("has"),   QStringLiteral("hast"),   QStringLiteral("hath"),
        QStringLiteral("have"),  QStringLiteral("he"),     QStringLiteral("her"),
        QStringLiteral("here"),  QStringLiteral("hers"),   QStringLiteral("him"),
        QStringLiteral("his"),   QStringLiteral("how"),    QStringLiteral("i"),
        QStringLiteral("if"),    QStringLiteral("in"),     QStringLiteral("into"),
        QStringLiteral("is"),    QStringLiteral("it"),     QStringLiteral("its"),
        QStringLiteral("let"),   QStringLiteral("like"),   QStringLiteral("may"),
        QStringLiteral("me"),    QStringLiteral("might"),  QStringLiteral("more"),
        QStringLiteral("most"),  QStringLiteral("much"),   QStringLiteral("must"),
        QStringLiteral("my"),    QStringLiteral("neither"),QStringLiteral("no"),
        QStringLiteral("nor"),   QStringLiteral("not"),    QStringLiteral("now"),
        QStringLiteral("of"),    QStringLiteral("off"),    QStringLiteral("on"),
        QStringLiteral("only"),  QStringLiteral("or"),     QStringLiteral("other"),
        QStringLiteral("our"),   QStringLiteral("out"),    QStringLiteral("over"),
        QStringLiteral("own"),   QStringLiteral("said"),   QStringLiteral("same"),
        QStringLiteral("say"),   QStringLiteral("says"),   QStringLiteral("shall"),
        QStringLiteral("she"),   QStringLiteral("should"), QStringLiteral("since"),
        QStringLiteral("so"),    QStringLiteral("some"),   QStringLiteral("such"),
        QStringLiteral("than"),  QStringLiteral("that"),   QStringLiteral("the"),
        QStringLiteral("thee"),  QStringLiteral("their"),  QStringLiteral("them"),
        QStringLiteral("then"),  QStringLiteral("there"),  QStringLiteral("these"),
        QStringLiteral("they"),  QStringLiteral("thine"),  QStringLiteral("this"),
        QStringLiteral("those"), QStringLiteral("thou"),   QStringLiteral("though"),
        QStringLiteral("thus"),  QStringLiteral("thy"),    QStringLiteral("till"),
        QStringLiteral("to"),    QStringLiteral("too"),    QStringLiteral("unto"),
        QStringLiteral("up"),    QStringLiteral("upon"),   QStringLiteral("us"),
        QStringLiteral("very"),  QStringLiteral("was"),    QStringLiteral("we"),
        QStringLiteral("were"),  QStringLiteral("what"),   QStringLiteral("when"),
        QStringLiteral("where"), QStringLiteral("which"),  QStringLiteral("while"),
        QStringLiteral("who"),   QStringLiteral("whom"),   QStringLiteral("why"),
        QStringLiteral("will"),  QStringLiteral("with"),   QStringLiteral("would"),
        QStringLiteral("ye"),    QStringLiteral("yet"),    QStringLiteral("you"),
        QStringLiteral("your"),
    };
    return s;
}

// The trigram tokenizer cannot index anything shorter, so a two-letter word
// contributes nothing to an FTS match no matter how meaningful it looks.
// db::kTrigramFloor says the same thing; restated as a local so this file
// does not reach into the DB layer for a constant.
constexpr int kMinWordLen = 3;

bool keepable(const QString& w)
{
    if (w.size() < kMinWordLen) return false;
    if (stopwords().contains(w)) return false;
    return true;
}

struct Coord
{
    QString book;
    int     chapter = 0;
    int     verse   = 0;

    bool operator==(const Coord& o) const
    {
        return chapter == o.chapter && verse == o.verse
            && book.compare(o.book, Qt::CaseInsensitive) == 0;
    }
};

}  // namespace

QuotationMatcher::QuotationMatcher(Config cfg)
    : m_cfg(cfg)
{
}

QStringList QuotationMatcher::contentWords(const QString& utterance)
{
    // Reuses the citation path's tokenizer rather than rolling a second one.
    // Both paths must agree on what a word is, or a phrase that the citation
    // grammar splits one way and this splits another would behave differently
    // depending on which detector saw it.
    const QStringList words = narration::tokenize(utterance);

    QStringList out;
    out.reserve(words.size());

    for (int i = 0; i < words.size();) {
        // Skip whole number phrases, not single tokens: "twenty eight" is one
        // number and both halves belong to the citation path.
        if (const auto np = narration::parseNumberPhrase(words, i)) {
            i = np->endIdx;
            continue;
        }
        const QString& w = words.at(i);
        if (keepable(w)) out.append(w);
        ++i;
    }
    return out;
}

QSet<QString> QuotationMatcher::verseContentWords(const QString& verseText)
{
    QSet<QString> out;
    const QStringList words = narration::tokenize(verseText);
    for (const QString& w : words) {
        // Verse-side numbers stay: "forty days" is part of what the verse
        // says, and the coverage test compares against the utterance's own
        // filtered words either way.
        if (keepable(w)) out.insert(w);
    }
    return out;
}

QList<HeardReference> QuotationMatcher::match(const QString& utterance, qint64 nowMs)
{
    QList<HeardReference> out;
    if (!m_search) return out;

    const QStringList words = contentWords(utterance);
    if (words.size() < m_cfg.minContentWords) return out;

    int windowsTried = 0;

    for (int start = 0;
         start + m_cfg.minContentWords <= words.size() && windowsTried < m_cfg.maxWindows
             && out.size() < m_cfg.maxEmits;
         start += m_cfg.windowStep)
    {
        const int take = std::min(m_cfg.maxWindowWords, int(words.size()) - start);
        if (take < m_cfg.minContentWords) break;

        const QStringList window = words.mid(start, take);
        ++windowsTried;

        const QList<SearchHit> hits = m_search(window.join(QLatin1Char(' ')));
        if (hits.isEmpty()) continue;

        // Collapse across translations. The same verse in KJV, NIV and ESV is
        // three rows and one answer — and a phrase matching the same
        // coordinates in several translations is stronger evidence, not
        // weaker. Which translation the congregation sees is the operator's
        // choice, resolved later (docs/narration.md §11).
        //
        // Hits arrive best-first (ORDER BY bm25 ASC), so the first group is
        // the coordinate of the best-scoring row.
        QList<Coord> coords;
        QList<int>   counts;
        QString      bestText;
        for (const SearchHit& h : hits) {
            const Coord c{ h.book, h.chapter, h.verse };
            const int   at = coords.indexOf(c);
            if (at < 0) { coords.append(c); counts.append(1); }
            else        { counts[at]++; }
            if (bestText.isEmpty()) bestText = h.text;
        }
        if (coords.isEmpty()) continue;

        // The gate: does one verse clearly own this phrase?
        //
        // Strict uniqueness was the first rule here and it was wrong in
        // practice. A library with fourteen translations includes loose
        // paraphrases, and "in the beginning God created the heaven and the
        // earth" matches Genesis 1:1 in eleven of them plus one paraphrase of
        // 2 Peter 3:5 — one stray row, and the most quoted opening line in
        // scripture was being thrown away.
        //
        // Dominance asks the better question. Eleven votes against one is a
        // clear answer; nine against eight is two verses that both genuinely
        // contain the phrase, which means it identifies neither. That is a
        // property of the evidence rather than a threshold somebody tuned.
        const int total  = int(hits.size());
        const int best   = counts.first();
        const int others = total - best;
        if (best < 2 * others) continue;

        const Coord& c = coords.first();
        if (c.book.isEmpty() || c.chapter <= 0 || c.verse <= 0) continue;

        // A continuous reading walks the window across consecutive verses.
        // Emitting each one separately would fill the queue with a passage the
        // operator already has, so treat an immediate neighbour of something
        // we just emitted as the same quotation.
        bool adjacent = false;
        for (const HeardReference& prev : out) {
            if (prev.book.compare(c.book, Qt::CaseInsensitive) == 0
                && prev.chapter == c.chapter
                && std::abs(prev.verseStart - c.verse) <= 1) {
                adjacent = true;
                break;
            }
        }
        if (adjacent) continue;

        // How much of the verse did they actually say?
        const QSet<QString> verseWords = verseContentWords(bestText);
        if (verseWords.isEmpty()) continue;

        int matched = 0;
        for (const QString& w : window)
            if (verseWords.contains(w)) ++matched;

        const qreal coverage = qreal(matched) / qreal(verseWords.size());
        if (coverage < m_cfg.minCoverage) continue;

        HeardReference ref;
        ref.book       = c.book;
        ref.chapter    = c.chapter;
        ref.verseStart = c.verse;
        ref.verseEnd   = c.verse;
        ref.reference  = QStringLiteral("%1 %2:%3").arg(c.book).arg(c.chapter).arg(c.verse);
        ref.kind       = QStringLiteral("quotation");
        ref.heardText  = window.join(QLatin1Char(' '));
        ref.atMs       = nowMs;

        // Enough distinctive words to stand alone, or nearly the whole verse.
        // Anything weaker is a maybe, and a maybe belongs in the queue.
        ref.tier = (matched >= m_cfg.highWordCount || coverage >= m_cfg.highCoverage)
                       ? QStringLiteral("high")
                       : QStringLiteral("possible");

        out.append(ref);
    }

    return out;
}

}  // namespace crater::narration
