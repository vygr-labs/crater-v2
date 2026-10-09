#pragma once

#include <QList>
#include <QString>
#include <QStringList>

namespace crater::narration {

// Sentence embeddings for the allusion path. docs/narration.md §7.2.
//
// One method, because that is genuinely all the retrieval side needs: text in,
// unit-length float vectors out. Everything about *which* model, how it is
// quantized, and what runtime executes it lives behind this line.
//
// The interface exists before its implementation on purpose. The index format,
// the brute-force scan, the three distinctiveness gates and the trust wiring
// are all testable against synthetic vectors, and separating them from the
// model runtime means none of that work is blocked on shipping a 33 M
// parameter ONNX file. `AllusionIndex` reads a file; `AllusionMatcher` needs
// exactly one vector per query. Neither cares where the numbers came from.
//
// Contract:
//   - Vectors are L2-normalized. The index quantizes on that assumption and
//     the scan reports dot products as cosine similarity directly.
//   - dimensions() is fixed for the life of the object and must match the
//     index the vectors will be compared against.
//   - modelId() identifies the model AND its version, and is written into the
//     index file. Comparing vectors from two different models produces
//     confident nonsense, so the loader refuses a mismatch rather than
//     ranking garbage (see AllusionIndex::load).
class TextEmbedder
{
public:
    virtual ~TextEmbedder() = default;

    virtual bool    isReady()    const = 0;
    virtual int     dimensions() const = 0;
    virtual QString modelId()    const = 0;

    // Embed one batch. Returns one vector per input, in order, or an empty
    // list on failure. Batched because building the index embeds 31,102
    // verses and per-call overhead would dominate.
    virtual QList<QList<float>> embed(const QStringList& texts) = 0;
};

}  // namespace crater::narration
