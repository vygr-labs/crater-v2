#include "import/ParadoxTable.h"

#include "import/Rtf.h"

#include <QDir>
#include <QFileInfo>

namespace crater::paradox {

namespace {

constexpr int kHeaderSize = 0x800;   // every Paradox 4+ table EasyWorship writes
constexpr int kBlockHead  = 6;       // next, previous, last-record offset

// Field types this reader understands. Memo-like types (memo, blob, formatted
// memo, OLE, graphic) all keep the same 10-byte .MB pointer.
constexpr int kAlpha    = 0x01;
constexpr int kMemoLow  = 0x0C;
constexpr int kMemoHigh = 0x10;

int u8(const QByteArray& b, qsizetype at)
{
    return (at >= 0 && at < b.size()) ? quint8(b.at(at)) : 0;
}

int i16(const QByteArray& b, qsizetype at)
{
    return qint16(u8(b, at) | (u8(b, at + 1) << 8));
}

quint32 u32(const QByteArray& b, qsizetype at)
{
    return quint32(u8(b, at)) | (quint32(u8(b, at + 1)) << 8)
         | (quint32(u8(b, at + 2)) << 16) | (quint32(u8(b, at + 3)) << 24);
}

bool isMemo(int type) { return type >= kMemoLow && type <= kMemoHigh; }

// The header fields that make a file a Paradox table this reader can walk.
bool headerIsValid(const QByteArray& head)
{
    if (head.size() < 36) return false;
    const int recordSize = i16(head, 0);
    const int blockKb    = u8(head, 5);
    const int fields     = i16(head, 33);
    return i16(head, 2) == kHeaderSize
        && recordSize > 0
        && blockKb >= 1 && blockKb <= 32
        && fields > 0 && fields <= 255;
}

}  // namespace

bool Table::looksLikeTable(const QString& path)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return false;
    return headerIsValid(f.read(36));
}

std::optional<Table> Table::open(const QString& dbPath, QString* error)
{
    const auto fail = [&](const QString& why) -> std::optional<Table> {
        if (error) *error = why;
        return std::nullopt;
    };
    const QString name = QFileInfo(dbPath).fileName();

    QFile dbFile(dbPath);
    if (!dbFile.open(QIODevice::ReadOnly))
        return fail(QStringLiteral("Could not open %1.").arg(name));

    Table t;
    t.m_db = dbFile.readAll();
    const QByteArray& db = t.m_db;
    if (!headerIsValid(db) || db.size() < kHeaderSize)
        return fail(QStringLiteral("%1 is not an EasyWorship 2009 song database.").arg(name));

    const int recordSize = i16(db, 0);
    const int blockSize  = u8(db, 5) * 1024;
    const int fieldCount = i16(db, 33);

    // Field descriptors, then the names. Between them sit a pointer to the
    // table name, one pointer per field name and the 261-byte table name.
    int offset = 0;
    for (int i = 0; i < fieldCount; ++i) {
        Field f;
        f.type   = u8(db, 120 + 2 * i);
        f.size   = u8(db, 121 + 2 * i);
        f.offset = offset;
        offset  += f.size;
        t.m_fields.append(f);
    }
    if (offset != recordSize)
        return fail(QStringLiteral("%1 has a field layout this version can't read.").arg(name));

    qsizetype at = 120 + 2 * fieldCount + 4 + 4 * fieldCount + 261;
    for (int i = 0; i < fieldCount; ++i) {
        const qsizetype end = db.indexOf('\0', at);
        if (end < 0 || end >= kHeaderSize)
            return fail(QStringLiteral("%1 has a damaged header.").arg(name));
        t.m_fields[i].name = rtf::fromCp1252(QByteArrayView(db).sliced(at, end - at));
        at = end + 1;
    }

    // Walk the data blocks in chain order. A table can be larger than its
    // record count suggests (deleted records leave free blocks behind), so
    // the chain, not the count, decides what is read. The visit cap stops a
    // damaged chain that loops back on itself.
    const int maxBlocks = int((db.size() - kHeaderSize) / blockSize) + 1;
    int block = 1;
    for (int visited = 0; block > 0 && visited < maxBlocks; ++visited) {
        const qsizetype base = kHeaderSize + qsizetype(block - 1) * blockSize;
        if (base + kBlockHead > db.size()) break;
        const int next = i16(db, base);
        const int last = i16(db, base + 4);   // negative: the block is empty
        const int count = (last + recordSize) / recordSize;
        for (int r = 0; r < count; ++r) {
            const qsizetype rec = base + kBlockHead + qsizetype(r) * recordSize;
            if (rec + recordSize > db.size()) break;
            t.m_records.append(int(rec));
        }
        block = next;
    }

    // The memo file sits beside the table with the same base name.
    bool hasMemo = false;
    for (const Field& f : t.m_fields) hasMemo = hasMemo || isMemo(f.type);
    if (hasMemo) {
        const QFileInfo info(dbPath);
        const QString mbPath = info.dir().filePath(info.completeBaseName() + QStringLiteral(".MB"));
        t.m_memo = std::make_shared<QFile>(mbPath);
        if (!t.m_memo->open(QIODevice::ReadOnly))
            return fail(QStringLiteral("%1 needs %2 from the same folder.")
                            .arg(name, info.completeBaseName() + QStringLiteral(".MB")));
    }
    return t;
}

int Table::fieldIndex(const QString& name) const
{
    for (int i = 0; i < m_fields.size(); ++i)
        if (m_fields.at(i).name.compare(name, Qt::CaseInsensitive) == 0) return i;
    return -1;
}

QString Table::text(int record, int field) const
{
    if (record < 0 || record >= m_records.size()) return {};
    if (field < 0 || field >= m_fields.size()) return {};
    const Field& f = m_fields.at(field);
    if (f.type != kAlpha) return {};
    QByteArrayView raw = QByteArrayView(m_db).sliced(m_records.at(record) + f.offset, f.size);
    const qsizetype nul = raw.indexOf('\0');
    if (nul >= 0) raw = raw.first(nul);
    return rtf::fromCp1252(raw).trimmed();
}

QByteArray Table::memo(int record, int field) const
{
    if (!m_memo) return {};
    if (record < 0 || record >= m_records.size()) return {};
    if (field < 0 || field >= m_fields.size()) return {};
    const Field& f = m_fields.at(field);
    if (!isMemo(f.type) || f.size < 10) return {};

    // The pointer is the last 10 bytes of the field: offset, length, modcount.
    const qsizetype ptr = m_records.at(record) + f.offset + f.size - 10;
    const quint32 where  = u32(m_db, ptr);
    const quint32 length = u32(m_db, ptr + 4);
    if (where == 0 || length == 0) return {};   // NULL memo
    const qint64 block = qint64(where & ~quint32(0xFF));
    const int    slot  = int(where & 0xFF);

    QFile& mb = *m_memo;
    if (!mb.seek(block)) return {};
    const QByteArray head = mb.read(12 + 5 * 64);
    qint64 start = -1;
    switch (u8(head, 0)) {
    case 2:   // one memo fills the block
        start = block + 9;
        break;
    case 3:   // small memos share the block, one table entry per slot
        if (slot < 64 && 12 + 5 * slot < head.size())
            start = block + qint64(u8(head, 12 + 5 * slot)) * 16;
        break;
    default:  // free or index block: the pointer is stale
        break;
    }
    if (start < 0 || !mb.seek(start)) return {};
    QByteArray data = mb.read(length);
    return data.size() == qsizetype(length) ? data : QByteArray();
}

}  // namespace crater::paradox
