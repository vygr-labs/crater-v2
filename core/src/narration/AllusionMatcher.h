#pragma once

#include "crater/value/HeardReference.h"
#include "narration/AllusionIndex.h"

#include <QList>
#include <QString>

#include <functional>

namespace crater::narration {

// Semantic paraphrase detection. docs/narration.md §2 and §7.3.
//
// This is the path that makes the feature feel like magic: the preacher says
// "God loved us so much that he sent his own son to die" and John 3:16 is
// there, without the address and without the words. It is also, by a wide
// margin, the path with the worst false-positive profile, which is why §5
// never lets it fire on its own in any mode.
//
// ── Why the gates have to be this strict ─────────────────────────────────
//
// Sermons are saturated with biblical language. "We need to love one another"
// is semantically adjacent to dozens of verses, and raw top-1 cosine would
// fire on it constantly — and on the welcome, and on the announcements. Three
// gates, all required:
//
//   1. Content floor  — enough non-stopword tokens to carry signal at all.
//   2. Absolute score — the top hit must actually be close.
//   3. Cluster size   — and the neighbourhood around it must be SMALL.
//
// ── Why the third gate counts neighbours instead of measuring a gap ──────
//
// It began as a top-1-versus-top-2 margin, which is the obvious way to ask
// "does one verse own this phrase?". Run against the real 31,102-verse index
// it rejected the feature's own flagship example. "God loved us so much that
// he sent his own son to die so we could live" scores 0.779 on 1 John 4:9,
// 0.760 on Romans 5:8 and 0.757 on John 3:16 — a 0.019 gap, so the margin
// killed it.
//
// But those three verses are all *correct*. 1 John 4:9 says God "sent his
// only begotten Son into the world, that we might live through him". The
// preacher paraphrased something scripture says in several places, and the
// margin test could not tell that apart from meaningless noise, because a
// gap is not what distinguishes them. Crowd size is: three good answers is a
// cluster, fifty equally-near verses is mush. That was always the stated
// intent in §7.3 ("if fifty verses are all equally close…"); the top-2 gap
// was a crude proxy for it that misfires at exactly the moment it matters.
//
// So a small cluster now yields ALL of its members as separate suggestions.
// That is the right call specifically because this tier is queue-only: the
// trust gate refuses to project "possible" under any configuration, so the
// choice is between offering the operator three one-click candidates and
// offering nothing. §5 says this path "earns its place by populating a queue
// the operator can act on in one click" — suppressing the cluster earns
// nothing.
//
// Clearing all three still only earns tier "possible", which the trust gate
// refuses to project under any configuration. That is not belt-and-braces;
// it is the reason this path is allowed to exist.
class AllusionMatcher
{
public:
    struct Config
    {
        // Non-stopword tokens required before the window is worth embedding.
        // Short phrases carry too little signal to distinguish a paraphrase
        // from a coincidence.
        //
        // Five, matching §7.3, and the number is load-bearing at exactly this
        // value: "God loved us so much that he sent his own son to die" —
        // §2's own canonical paraphrase example — keeps precisely five
        // (god, loved, sent, son, die). A floor of six silently discards the
        // case the whole path exists for.
        int minContentWords = 5;

        // Top-1 cosine floor, and the single most-revised number here.
        //
        // It was 0.68, measured against a FOUR-verse index where announcements
        // sat at 0.47 and paraphrases at 0.75. Against the real 31,102-verse
        // index (`build_allusion_index --calibrate`) that separation does not
        // exist at all:
        //
        //   paraphrases       0.707 .. 0.891
        //   ordinary speech   0.580 .. 0.775
        //
        // The two OVERLAP. This is not a tuning error, it is arithmetic: the
        // nearest neighbour of any sentence rises as the corpus grows, so
        // "how close is the best match" stops being informative once there
        // are thirty thousand candidates. Any threshold calibrated on a toy
        // index will be wrong on the real one.
        //
        // 0.78 sits above every ordinary-speech sample that had a small
        // cluster, which is what makes it work in combination with the gate
        // below — neither number is sufficient alone.
        float minScore = 0.78f;

        // A verse counts as part of the top hit's cluster when it is within
        // this much cosine of it AND clears minScore. 0.04 is roughly the
        // spread across the three correct answers in the worked example
        // above (0.779 down to 0.757).
        float clusterWindow = 0.04f;

        // Above this many near-tied verses, nothing is emitted — and THIS is
        // the gate that actually separates the two distributions above.
        //
        // Measured on the real index, cluster size tracks whether a sentence
        // is *about* one verse:
        //
        //   Phil 4:13   0.891  cluster 1     paraphrase, resolved correctly
        //   Genesis 1:1 0.885  cluster 1     ditto
        //   1 John 1:9  0.863  cluster 1     ditto
        //   Romans 8:28 0.822  cluster 2     ditto
        //   Psalm 23:1  0.786  cluster 3     ditto
        //   Rev 22:21   0.775  cluster 8     "good morning church..."
        //   Psalms 66:8 0.755  cluster 8     "thank the worship team..."
        //
        // Ordinary speech scores high only by being vaguely near a crowd of
        // verses at once. A real paraphrase is near one, or near a few that
        // genuinely say the same thing.
        //
        // Three, with minScore 0.78, fires on 5 of 8 sampled paraphrases and
        // 0 of 10 sampled announcements. That trade is deliberate: this tier
        // populates a suggestion queue, where a wrong entry costs the
        // operator's trust and a missing one costs nothing they would notice.
        int maxCluster = 3;

        // Suggestions emitted per window even when the cluster is larger. The
        // queue is a glanceable strip in the console, not a search results
        // page.
        int maxPerWindow = 3;

        // How deep to probe so cluster size can be measured at all. The scan
        // is a flat pass either way, so a larger k costs only the selection.
        int probeDepth = 8;

        // Words per embedding window, and how far the window slides.
        int maxWindowWords = 22;
        int windowStep     = 12;
        int maxWindows     = 3;
    };

    // Text to an L2-normalized vector. Supplied rather than owned, exactly as
    // CitationDetector takes a validator and QuotationMatcher takes a search
    // function, so the gates are testable against synthetic vectors with no
    // model on disk.
    using EmbedFn = std::function<QList<float>(const QString& text)>;

    explicit AllusionMatcher(Config cfg = {});

    void setIndex(const AllusionIndex* index) { m_index = index; }
    void setEmbedder(EmbedFn fn)              { m_embed = std::move(fn); }

    // True when both an index and an embedder are present. False means this
    // path is inert, which is the normal state of a build that ships without
    // the embedding model.
    bool isReady() const;

    const Config& config() const { return m_cfg; }
    void setConfig(Config cfg)   { m_cfg = cfg; }

    QList<crater::HeardReference> match(const QString& utterance, qint64 nowMs);

private:
    Config               m_cfg;
    const AllusionIndex* m_index = nullptr;
    EmbedFn              m_embed;
};

}  // namespace crater::narration
