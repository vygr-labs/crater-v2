#pragma once

#include "narration/TextEmbedder.h"
#include "narration/WordPieceTokenizer.h"

#include <QString>

#include <memory>

namespace crater::narration {

// bge-small-en-v1.5 sentence embeddings via ONNX Runtime.
// docs/narration.md §7.2.
//
// Compiled only when CRATER_WITH_EMBEDDINGS is on; otherwise every entry
// point fails loudly, exactly as WhisperRecognizer does without
// CRATER_WITH_WHISPER. A stub that quietly returned empty vectors would be
// indistinguishable from a preacher who has not paraphrased anything.
//
// ── Two details taken from the model, not assumed ────────────────────────
//
// **CLS pooling, not mean.** bge-small's 1_Pooling/config.json sets
// `pooling_mode_cls_token: true` and `pooling_mode_mean_tokens: false`. Mean
// pooling is the more common convention and is what most example code does,
// which makes this exactly the kind of thing that gets copied in wrong. Using
// the wrong pooling produces perfectly well-formed 384-dimension vectors in a
// space that has nothing to do with the index's, and every query would still
// return a confident, arbitrary verse.
//
// **No query instruction prefix.** BGE asks for an instruction prefix on
// short queries retrieving long passages (s2p). Ours is sentence-to-sentence:
// a spoken clause against a verse, both a sentence long. BGE's own guidance
// is to omit the prefix for s2s, and consistency matters more than the choice
// anyway — the index is built through this same class, so both sides of every
// comparison are produced identically by construction.
class OnnxEmbedder final : public TextEmbedder
{
public:
    OnnxEmbedder();
    ~OnnxEmbedder() override;

    // `modelPath` is the .onnx file; the vocabulary is the one bundled with
    // crater-core, so there is no way to pair a model with the wrong one.
    // Blocking and slow (hundreds of ms) — call it off the UI thread.
    bool load(const QString& modelPath, QString* error = nullptr);
    void unload();

    bool    isReady()    const override;
    int     dimensions() const override;
    QString modelId()    const override;

    // Batched, but executed one sequence at a time. Padding a batch to its
    // longest member and masking the difference is the usual trick; it is
    // also a second, silent way to get attention masking wrong, and the
    // index build is a one-off that runs at whatever speed it runs at.
    QList<QList<float>> embed(const QStringList& texts) override;

    // Convenience for the single-sentence query path. Returns an empty list
    // on any failure.
    QList<float> embedOne(const QString& text);

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

}  // namespace crater::narration
