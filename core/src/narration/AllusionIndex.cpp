#include "narration/AllusionIndex.h"

#include <QDataStream>
#include <QFile>
#include <QHash>

#include <algorithm>
#include <cmath>

namespace crater::narration {

namespace {

constexpr quint32 kMagic   = 0x49415243;   // "CRAI" little-endian
constexpr quint32 kVersion = 1;

// Largest magnitude an int8 component may take. 127 rather than 128 so the
// range is symmetric and -128 never appears — an asymmetric range would bias
// every dot product very slightly toward negative components.
constexpr float kQuantMax = 127.0f;

void fail(QString* error, const QString& message)
{
    if (error) *error = message;
}

}  // namespace

void AllusionIndex::clear()
{
    m_dims = 0;
    m_count = 0;
    m_modelId.clear();
    m_books.clear();
    m_bookIdx.clear();
    m_chapter.clear();
    m_verse.clear();
    m_data.clear();
    m_scale.clear();
}

bool AllusionIndex::build(const QList<Entry>& entries, const QString& modelId, QString* error)
{
    clear();
    if (entries.isEmpty()) {
        fail(error, QStringLiteral("No entries to index."));
        return false;
    }

    m_dims = int(entries.first().vector.size());
    if (m_dims <= 0) {
        fail(error, QStringLiteral("First entry has an empty vector."));
        return false;
    }

    m_count   = int(entries.size());
    m_modelId = modelId;

    m_bookIdx.reserve(m_count);
    m_chapter.reserve(m_count);
    m_verse.reserve(m_count);
    m_scale.reserve(m_count);
    m_data.resize(qsizetype(m_count) * m_dims);

    QHash<QString, int> bookIds;

    for (int r = 0; r < m_count; ++r) {
        const Entry& e = entries.at(r);
        if (int(e.vector.size()) != m_dims) {
            fail(error, QStringLiteral("Entry %1 (%2 %3:%4) has %5 dimensions, expected %6.")
                            .arg(r).arg(e.book).arg(e.chapter).arg(e.verse)
                            .arg(e.vector.size()).arg(m_dims));
            clear();
            return false;
        }

        int id = bookIds.value(e.book, -1);
        if (id < 0) {
            id = int(m_books.size());
            m_books.append(e.book);
            bookIds.insert(e.book, id);
        }
        m_bookIdx.append(quint16(id));
        m_chapter.append(quint16(e.chapter));
        m_verse.append(quint16(e.verse));

        // Scale by the vector's own largest component so the int8 range is
        // actually used. A vector of all zeros would divide by zero, so it
        // gets a scale of zero and contributes nothing to any search — which
        // is the right answer for a verse with no signal.
        float peak = 0.0f;
        for (const float v : e.vector) peak = std::max(peak, std::fabs(v));

        const float scale = (peak > 0.0f) ? (peak / kQuantMax) : 0.0f;
        m_scale.append(scale);

        qint8* row = m_data.data() + qsizetype(r) * m_dims;
        if (scale <= 0.0f) {
            std::fill(row, row + m_dims, qint8(0));
            continue;
        }
        for (int d = 0; d < m_dims; ++d) {
            const float q = std::round(e.vector.at(d) / scale);
            row[d] = qint8(std::clamp(q, -kQuantMax, kQuantMax));
        }
    }

    return true;
}

bool AllusionIndex::save(const QString& path, QString* error) const
{
    if (m_count <= 0) {
        fail(error, QStringLiteral("Index is empty; nothing to save."));
        return false;
    }

    QFile f(path);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        fail(error, QStringLiteral("Cannot write %1: %2").arg(path, f.errorString()));
        return false;
    }

    QDataStream s(&f);
    s.setByteOrder(QDataStream::LittleEndian);
    s.setFloatingPointPrecision(QDataStream::SinglePrecision);

    s << kMagic << kVersion << quint32(m_dims) << quint32(m_count);

    const QByteArray model = m_modelId.toUtf8();
    s << quint32(model.size());
    s.writeRawData(model.constData(), int(model.size()));

    s << quint32(m_books.size());
    for (const QString& b : m_books) {
        const QByteArray n = b.toUtf8();
        s << quint16(n.size());
        s.writeRawData(n.constData(), int(n.size()));
    }

    for (int r = 0; r < m_count; ++r)
        s << m_bookIdx.at(r) << m_chapter.at(r) << m_verse.at(r) << quint16(0);

    s.writeRawData(reinterpret_cast<const char*>(m_data.constData()),
                   int(qsizetype(m_count) * m_dims));

    for (int r = 0; r < m_count; ++r)
        s << m_scale.at(r);

    if (s.status() != QDataStream::Ok) {
        fail(error, QStringLiteral("Write failed part-way through %1.").arg(path));
        return false;
    }
    return true;
}

bool AllusionIndex::load(const QString& path, const QString& expectedModelId, QString* error)
{
    clear();

    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) {
        fail(error, QStringLiteral("Cannot read %1: %2").arg(path, f.errorString()));
        return false;
    }

    QDataStream s(&f);
    s.setByteOrder(QDataStream::LittleEndian);
    s.setFloatingPointPrecision(QDataStream::SinglePrecision);

    quint32 magic = 0, version = 0, dims = 0, count = 0;
    s >> magic >> version >> dims >> count;
    if (magic != kMagic) {
        fail(error, QStringLiteral("%1 is not a Crater allusion index.").arg(path));
        return false;
    }
    if (version != kVersion) {
        fail(error, QStringLiteral("Index version %1 is not supported (expected %2).")
                        .arg(version).arg(kVersion));
        return false;
    }
    if (dims == 0 || count == 0 || dims > 4096) {
        fail(error, QStringLiteral("Index header is not sane (dims=%1 count=%2).")
                        .arg(dims).arg(count));
        return false;
    }

    quint32 modelLen = 0;
    s >> modelLen;
    QByteArray model(int(modelLen), Qt::Uninitialized);
    if (modelLen > 0 && s.readRawData(model.data(), int(modelLen)) != int(modelLen)) {
        fail(error, QStringLiteral("Index truncated in the model identifier."));
        return false;
    }
    const QString fileModel = QString::fromUtf8(model);

    // A mismatch here is the dangerous kind of wrong. Two models' vector
    // spaces are unrelated, so searching one with the other's query returns
    // high-scoring, entirely arbitrary verses — output that looks exactly
    // like a working system. Refuse rather than rank noise.
    if (!expectedModelId.isEmpty() && fileModel != expectedModelId) {
        fail(error, QStringLiteral("Index was built with model \"%1\" but \"%2\" is loaded. "
                                   "Rebuild the index.")
                        .arg(fileModel, expectedModelId));
        return false;
    }

    quint32 bookCount = 0;
    s >> bookCount;
    if (bookCount == 0 || bookCount > 1000) {
        fail(error, QStringLiteral("Index book table is not sane (%1 entries).").arg(bookCount));
        return false;
    }
    QStringList books;
    books.reserve(int(bookCount));
    for (quint32 i = 0; i < bookCount; ++i) {
        quint16 len = 0;
        s >> len;
        QByteArray name(int(len), Qt::Uninitialized);
        if (len > 0 && s.readRawData(name.data(), int(len)) != int(len)) {
            fail(error, QStringLiteral("Index truncated in the book table."));
            return false;
        }
        books.append(QString::fromUtf8(name));
    }

    QList<quint16> bookIdx, chapter, verse;
    bookIdx.reserve(int(count));
    chapter.reserve(int(count));
    verse.reserve(int(count));
    for (quint32 r = 0; r < count; ++r) {
        quint16 b = 0, c = 0, v = 0, pad = 0;
        s >> b >> c >> v >> pad;
        if (b >= bookCount) {
            fail(error, QStringLiteral("Index row %1 references book %2 of %3.")
                            .arg(r).arg(b).arg(bookCount));
            return false;
        }
        bookIdx.append(b);
        chapter.append(c);
        verse.append(v);
    }

    QList<qint8> data;
    data.resize(qsizetype(count) * qsizetype(dims));
    const int want = int(qsizetype(count) * qsizetype(dims));
    if (s.readRawData(reinterpret_cast<char*>(data.data()), want) != want) {
        fail(error, QStringLiteral("Index truncated in the vector block."));
        return false;
    }

    QList<float> scale;
    scale.reserve(int(count));
    for (quint32 r = 0; r < count; ++r) {
        float sc = 0.0f;
        s >> sc;
        scale.append(sc);
    }

    if (s.status() != QDataStream::Ok) {
        fail(error, QStringLiteral("Index truncated in the scale block."));
        return false;
    }

    m_dims    = int(dims);
    m_count   = int(count);
    m_modelId = fileModel;
    m_books   = std::move(books);
    m_bookIdx = std::move(bookIdx);
    m_chapter = std::move(chapter);
    m_verse   = std::move(verse);
    m_data    = std::move(data);
    m_scale   = std::move(scale);
    return true;
}

QList<AllusionIndex::Hit> AllusionIndex::search(const QList<float>& query, int k) const
{
    QList<Hit> out;
    if (m_count <= 0 || k <= 0) return out;
    if (int(query.size()) != m_dims) return out;   // never compare padded

    // Quantize the query the same way the rows were, so both sides carry the
    // same kind of error and the dot product stays an integer operation.
    float peak = 0.0f;
    for (const float v : query) peak = std::max(peak, std::fabs(v));
    if (peak <= 0.0f) return out;

    const float qScale = peak / kQuantMax;
    QList<qint8> q;
    q.resize(m_dims);
    for (int d = 0; d < m_dims; ++d)
        q[d] = qint8(std::clamp(std::round(query.at(d) / qScale), -kQuantMax, kQuantMax));

    // Partial selection rather than a full sort: k is 2 or 3 and the corpus
    // is 31,102, so sorting everything would cost more than the scan itself.
    QList<QPair<float, int>> best;   // (score, row), worst-first
    best.reserve(k + 1);

    const qint8* base = m_data.constData();
    const qint8* qp   = q.constData();

    for (int r = 0; r < m_count; ++r) {
        const float rowScale = m_scale.at(r);
        if (rowScale <= 0.0f) continue;

        const qint8* row = base + qsizetype(r) * m_dims;

        // Plain integer loop. int32 cannot overflow here: the worst case is
        // 4096 * 127 * 127 which is under 67 M. Compilers vectorize this
        // shape well, and hand-written SIMD would be a portability tax for a
        // scan already measured in single-digit milliseconds.
        qint32 acc = 0;
        for (int d = 0; d < m_dims; ++d)
            acc += qint32(row[d]) * qint32(qp[d]);

        // Both sides were unit vectors before quantization, so the dequantized
        // dot product IS the cosine similarity.
        const float score = float(acc) * rowScale * qScale;

        if (best.size() < k) {
            best.append(qMakePair(score, r));
            std::sort(best.begin(), best.end(),
                      [](const auto& a, const auto& b) { return a.first < b.first; });
        } else if (score > best.first().first) {
            best[0] = qMakePair(score, r);
            std::sort(best.begin(), best.end(),
                      [](const auto& a, const auto& b) { return a.first < b.first; });
        }
    }

    out.reserve(best.size());
    for (int i = int(best.size()) - 1; i >= 0; --i) {   // best-first
        const int r = best.at(i).second;
        Hit h;
        h.book    = m_books.at(m_bookIdx.at(r));
        h.chapter = int(m_chapter.at(r));
        h.verse   = int(m_verse.at(r));
        h.score   = best.at(i).first;
        out.append(h);
    }
    return out;
}

}  // namespace crater::narration
