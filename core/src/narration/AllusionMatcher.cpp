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

        const QStringList window = words.mid(start, take);
        const QString     text   = window.join(QLatin1Char(' '));

        // The content floor has to be re-checked PER WINDOW, not just over
        // the whole utterance. A trailing window is mostly function words —
        // "die so we could live" is five tokens carrying two content words —
        // and embedding it asks the index to identify a fragment that says
        // almost nothing. Against 31,102 verses something always answers:
        // that particular fragment lands on 2 Corinthians 4:12 ("death
        // worketh in us, but life in you") with real confidence.
        if (int(QuotationMatcher::contentWords(text).size()) < m_cfg.minContentWords)
            continue;

        ++windows;

        const QList<float> vec = m_embed(text);
        if (vec.isEmpty()) continue;

        // Probe deep enough to measure the neighbourhood, not just its edge.
        const QList<AllusionIndex::Hit> hits = m_index->search(vec, m_cfg.probeDepth);
        if (hits.isEmpty()) continue;

        const AllusionIndex::Hit& top = hits.first();

        // Gate 2: is it actually close to anything?
        if (top.score < m_cfg.minScore) continue;

        // Gate 3: how crowded is the neighbourhood? Everything within
        // clusterWindow of the best hit is a co-answer, not a competitor.
        //
        // Membership is RELATIVE only. It used to also require each member to
        // clear minScore, which quietly collapsed this window to nothing
        // whenever the top hit sat near the threshold — at minScore 0.780 and
        // a top of 0.779, a 0.04 window admits a 0.001 band, so the six
        // verses that genuinely co-answered were filtered out before they
        // could be counted. The two numbers answer different questions and
        // should not be spent on each other: minScore asks "is this utterance
        // near scripture at all", which is absolute and already settled by
        // gate 2 above; the window asks "which verses answer it together with
        // the best one", which is only meaningful relative to that best one.
        //
        // Dropping the floor here can only make clusters LARGER, so it makes
        // the crowd rejection below stricter rather than looser. What it
        // changes is what an accepted cluster contains: all of its members
        // instead of only the ones that happened to sit above an absolute
        // line drawn for another purpose.
        QList<AllusionIndex::Hit> cluster;
        for (const AllusionIndex::Hit& h : hits) {
            if ((top.score - h.score) > m_cfg.clusterWindow) break;   // sorted, so done
            cluster.append(h);
        }

        // A crowd this size means the phrase expresses a theme the canon
        // shares rather than a paraphrase of anything in particular. Note the
        // probe depth bounds what we can see: a cluster filling the probe is
        // treated as too large, which is the conservative reading.
        if (cluster.size() > m_cfg.maxCluster) continue;
        if (cluster.size() >= m_cfg.probeDepth) continue;

        for (const AllusionIndex::Hit& h : cluster) {
            if (out.size() >= m_cfg.maxEmits) break;
            if (h.book.isEmpty() || h.chapter <= 0 || h.verse <= 0) continue;

            // Do not emit the same verse twice from overlapping windows.
            bool already = false;
            for (const HeardReference& prev : out) {
                if (prev.chapter == h.chapter && prev.verseStart == h.verse
                    && prev.book.compare(h.book, Qt::CaseInsensitive) == 0) {
                    already = true;
                    break;
                }
            }
            if (already) continue;

            HeardReference ref;
            ref.book       = h.book;
            ref.chapter    = h.chapter;
            ref.verseStart = h.verse;
            ref.verseEnd   = h.verse;
            ref.reference  = QStringLiteral("%1 %2:%3")
                                 .arg(h.book).arg(h.chapter).arg(h.verse);
            ref.kind       = QStringLiteral("allusion");
            ref.heardText  = text;
            ref.atMs       = nowMs;

            // Always "possible". Not "usually", not "unless the score is very
            // high" — there is no evidence this path can produce that
            // justifies driving the audience screen, and the tier is where
            // that judgement is recorded. See TrustGate.h.
            ref.tier = QStringLiteral("possible");

            out.append(ref);
        }
    }

    return out;
}

}  // namespace crater::narration
