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
//   3. Margin         — and it must clearly beat the runner-up. This is the
//                       one that catches generic phrasing: when fifty verses
//                       are all equally near, the phrase is generic rather
//                       than a paraphrase of any one of them, and no
//                       absolute threshold can tell those apart.
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

        // Top-1 cosine floor, chosen from measurements rather than intuition.
        // Against the real bge-small-en-v1.5 (test_onnx_embedder):
        //
        //   paraphrase -> the verse it paraphrases      0.75, 0.79
        //   paraphrase -> a plausible but wrong verse   0.62
        //   ordinary announcements -> nearest verse     0.47
        //
        // 0.68 sits above every wrong match observed and below every right
        // one, with room on both sides. Note where it does NOT sit: anywhere
        // near 0.3-0.5, which is where unrelated English sentence pairs land
        // and where a threshold picked by feel tends to end up.
        float minScore = 0.68f;

        // How far the top hit must beat the runner-up, in absolute cosine.
        // Small in magnitude and large in effect — this is what separates
        // "that verse" from "that theme", and it is what actually rejects the
        // 0.62 near-miss above (0.75 - 0.62 = 0.13, comfortably clear).
        float minMargin = 0.045f;

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
