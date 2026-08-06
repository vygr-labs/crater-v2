#pragma once

#include <QHash>
#include <QList>
#include <QString>
#include <QStringList>

namespace crater::narration {

// BERT WordPiece tokenizer, matching HuggingFace `BertTokenizer` closely
// enough that bge-small-en-v1.5 sees the token ids it was trained on.
//
// ── Why this is written by hand ──────────────────────────────────────────
//
// The alternative is HuggingFace's `tokenizers` crate (Rust) or ONNX Runtime
// Extensions, either of which is a second native dependency the size of the
// inference runtime itself, dragged in to do string splitting. WordPiece is a
// few hundred lines of well-specified text processing, it is deterministic,
// and it is exactly the sort of thing that should be unit-tested against
// known-good outputs rather than trusted.
//
// It is also where a silent, catastrophic failure would live. Feed the model
// subtly wrong token ids and it still returns a confident 384-dimension
// vector — one that points somewhere meaningless. Every verse would still
// retrieve *a* neighbour, and nothing about the output would look broken.
// That is precisely the failure this subsystem must not have, which is why
// the tokenizer is tested against fixed expected id sequences.
//
// ── Configuration, taken from the model, not guessed ─────────────────────
//
// bge-small-en-v1.5's tokenizer_config.json declares:
//   do_lower_case      true   (and therefore accent stripping, per BERT)
//   do_basic_tokenize  true
//   tokenize_chinese_chars true
//   model_max_length   512
//   [PAD]=0, plus [UNK] [CLS] [SEP] [MASK] resolved from the vocab
//
// Those are the settings implemented here. Nothing is parameterised that the
// model does not vary.
class WordPieceTokenizer
{
public:
    struct Encoded
    {
        // int64 because that is what BERT ONNX graphs declare for their
        // input tensors; converting at the boundary would just move the cast.
        QList<qint64> ids;
        QList<qint64> attentionMask;
        QList<qint64> tokenTypeIds;

        bool isEmpty() const { return ids.isEmpty(); }
    };

    // Load `vocab.txt`: one token per line, line number is the token id.
    bool loadVocab(const QString& path, QString* error = nullptr);
    bool loadVocab(const QStringList& tokens, QString* error = nullptr);

    bool isLoaded()   const { return !m_vocab.isEmpty(); }
    int  vocabSize()  const { return int(m_vocab.size()); }

    // Full encode: basic tokenize, WordPiece, then wrap in [CLS] ... [SEP]
    // and truncate to `maxLen` INCLUDING those two, which is what the model
    // expects. Returns an empty Encoded when no vocab is loaded.
    Encoded encode(const QString& text, int maxLen = 512) const;

    // The two stages, exposed because they are what the tests pin down.
    QStringList basicTokenize(const QString& text) const;
    QStringList wordPiece(const QString& word) const;

    int idFor(const QString& token) const;

private:
    QHash<QString, int> m_vocab;
    int m_unk = -1;
    int m_cls = -1;
    int m_sep = -1;
    int m_pad = -1;
};

}  // namespace crater::narration
