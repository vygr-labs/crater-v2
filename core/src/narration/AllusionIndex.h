#pragma once

#include <QList>
#include <QString>
#include <QStringList>

#include <cstdint>

namespace crater::narration {

// Flat int8 vector index over every verse, with brute-force cosine search.
// docs/narration.md §7.2.
//
// ── Why no ANN index ─────────────────────────────────────────────────────
//
// 31,102 verses at 384 dimensions is 12 MB and one full scan is ~12 M
// multiply-accumulates — single-digit milliseconds. HNSW or FAISS would buy
// nothing here and cost a dependency, a build step, tuning parameters, and a
// recall cliff nobody would notice until the one Sunday it mattered. Brute
// force is exact, has no knobs, and is fast enough. This is the whole
// argument, and it is worth re-reading before anyone "optimizes" it.
//
// ── Quantization ─────────────────────────────────────────────────────────
//
// Per-vector scaling, not a global one. Vectors arrive L2-normalized, so a
// 384-dimension unit vector has components averaging about 1/sqrt(384) ~ 0.05
// — quantizing those against a fixed [-1,1] range would spend the whole int8
// budget on a range nothing occupies and leave roughly three usable bits per
// component. Scaling each vector by its own largest component uses the full
// range and costs one float per verse (124 KB across the corpus).
//
// ── File format (little-endian) ──────────────────────────────────────────
//
//   magic   "CRAI"                      4 bytes
//   version uint32 = 1
//   dims    uint32
//   count   uint32
//   modelId uint32 length + UTF-8 bytes   (see TextEmbedder::modelId)
//   books   uint32 count, then per book: uint16 length + UTF-8 name
//   rows    count * { uint16 book, uint16 chapter, uint16 verse, uint16 pad }
//   vectors count * dims int8, row-major
//   scales  count * float32
//
// Book names are interned because storing "1 Corinthians" 31,102 times would
// cost more than the vectors do.
class AllusionIndex
{
public:
    struct Hit
    {
        QString book;
        int     chapter = 0;
        int     verse   = 0;
        // Cosine similarity in [-1, 1]. Dequantized, so it is comparable
        // against an absolute threshold rather than only usable for ranking.
        float   score   = 0.0f;
    };

    struct Entry
    {
        QString      book;
        int          chapter = 0;
        int          verse   = 0;
        QList<float> vector;      // L2-normalized
    };

    AllusionIndex() = default;

    // Build from float vectors, quantizing as described above. Replaces any
    // existing contents. Entries whose vector length differs from the first
    // are rejected; a ragged index would silently misalign every row after
    // the bad one.
    bool build(const QList<Entry>& entries, const QString& modelId, QString* error = nullptr);

    bool save(const QString& path, QString* error = nullptr) const;

    // Load, and refuse a model mismatch. Comparing vectors produced by two
    // different models yields confident nonsense rather than obvious
    // garbage, which is exactly the failure this path must not have — every
    // result would still look like a plausible verse. `expectedModelId` may
    // be empty to accept whatever the file declares.
    bool load(const QString& path, const QString& expectedModelId, QString* error = nullptr);

    void clear();

    bool    isLoaded()   const { return m_count > 0; }
    int     count()      const { return m_count; }
    int     dimensions() const { return m_dims; }
    QString modelId()    const { return m_modelId; }

    // Best `k` verses for an L2-normalized query vector, best first. Returns
    // empty when the index is unloaded or the query has the wrong dimension —
    // never a partial or padded comparison.
    QList<Hit> search(const QList<float>& query, int k) const;

private:
    int     m_dims  = 0;
    int     m_count = 0;
    QString m_modelId;

    QStringList          m_books;    // interned names
    QList<quint16>       m_bookIdx;  // per row
    QList<quint16>       m_chapter;  // per row
    QList<quint16>       m_verse;    // per row
    QList<qint8>         m_data;     // count * dims, row-major
    QList<float>         m_scale;    // per row
};

}  // namespace crater::narration
