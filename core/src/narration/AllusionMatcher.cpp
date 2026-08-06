#include "narration/AllusionMatcher.h"

#include "narration/QuotationMatcher.h"
#include "narration/SpokenNumbers.h"

#include <algorithm>
#include <utility>

namespace crater::narration {

AllusionMatcher::AllusionMatcher(Config cfg)
    : m_cfg(cfg)
{
}

bool AllusionMatcher::isReady() const
{
    return m_index && m_index->isLoaded() && bool(m_embed);
}

QList<HeardReference> AllusionMatcher::match(const QString& utterance, qint64 nowMs)
{
    QList<HeardReference> out;
    if (!isReady()) return out;

    // Gate 1, the content floor — and it runs before anything expensive.
    // Counting on the same filtered vocabulary QuotationMatcher uses keeps
    // the two paths agreeing on what "enough to go on" means, and skips the
    // embedding entirely for the announcements.
    const QStringList content = QuotationMatcher::contentWords(utterance);
    if (int(content.size()) < m_cfg.minContentWords) return out;

    // Embed the ORIGINAL words, not the filtered ones. Stopwords are noise to
    // a bag-of-words AND query and grammar to a sentence encoder — "God loved
    // us so much that he sent his own son" and "god loved sent son" do not
    // mean the same thing to the model, and the second is much further from
    // any real verse.
    const QStringList words = narration::tokenize(utterance);
    if (words.isEmpty()) return out;

    int windows = 0;
    for (int start = 0;
         start < int(words.size()) && windows < m_cfg.maxWindows;
         start += m_cfg.windowStep)
    {
        const int take = std::min(m_cfg.maxWindowWords, int(words.size()) - start);
        if (take < m_cfg.minContentWords) break;
        ++windows;

        const QStringList window = words.mid(start, take);
        const QString     text   = window.join(QLatin1Char(' '));

        const QList<float> vec = m_embed(text);
        if (vec.isEmpty()) continue;

        // Two hits, because the margin test needs a runner-up. Asking for
        // more would cost nothing in the scan but says nothing extra.
        const QList<AllusionIndex::Hit> hits = m_index->search(vec, 2);
        if (hits.isEmpty()) continue;

        const AllusionIndex::Hit& top = hits.first();

        // Gate 2: is it actually close?
        if (top.score < m_cfg.minScore) continue;

        // Gate 3: is it clearly closer than the next one? A crowded
        // neighbourhood means the phrase expresses a theme the whole canon
        // shares, not a paraphrase of one verse. When there is no runner-up
        // at all the margin is trivially satisfied.
        if (hits.size() > 1 && (top.score - hits.at(1).score) < m_cfg.minMargin) continue;

        if (top.book.isEmpty() || top.chapter <= 0 || top.verse <= 0) continue;

        // Do not emit two references for the same verse from overlapping
        // windows of one utterance.
        bool already = false;
        for (const HeardReference& prev : out) {
            if (prev.chapter == top.chapter && prev.verseStart == top.verse
                && prev.book.compare(top.book, Qt::CaseInsensitive) == 0) {
                already = true;
                break;
            }
        }
        if (already) continue;

        HeardReference ref;
        ref.book       = top.book;
        ref.chapter    = top.chapter;
        ref.verseStart = top.verse;
        ref.verseEnd   = top.verse;
        ref.reference  = QStringLiteral("%1 %2:%3")
                             .arg(top.book).arg(top.chapter).arg(top.verse);
        ref.kind       = QStringLiteral("allusion");
        ref.heardText  = text;
        ref.atMs       = nowMs;

        // Always "possible". Not "usually", not "unless the score is very
        // high" — there is no evidence this path can produce that justifies
        // driving the audience screen, and the tier is where that judgement
        // is recorded. See TrustGate.h.
        ref.tier = QStringLiteral("possible");

        out.append(ref);
    }

    return out;
}

}  // namespace crater::narration
