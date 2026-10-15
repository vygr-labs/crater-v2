#pragma once

#include <QByteArray>
#include <QFile>
#include <QList>
#include <QString>
#include <QStringList>

#include <memory>
#include <optional>

// crater::paradox — read-only access to a Borland Paradox table.
//
// EasyWorship 2007 and 2009 keep their song library in Paradox tables, not
// SQLite: Songs.DB holds one fixed-size record per song and Songs.MB holds the
// memo fields those records point into, the lyrics among them. Qt has no
// Paradox driver, so this reads the files directly.
//
// It covers only what an EasyWorship library uses: alpha (text) fields and
// memo fields, read sequentially. Indexes (.PX, .XG?, .YG?) are not needed to
// read every record and are ignored.
//
// Layout notes (all offsets in bytes):
//   .DB header     0 record size (int16 LE), 2 header size (int16, 0x800),
//                  4 file type, 5 block size in KB, 6 record count (int32),
//                  33 field count (int16), 120 one (type, size) pair per field,
//                  then the field names, NUL-separated, before the header end.
//   .DB data       blocks of `block size` KB from the header end. Each starts
//                  with next block (int16, 0 ends the chain), previous block
//                  and the offset of its last record (int16, negative when the
//                  block is empty); records follow at +6.
//   record fields  stored big-endian with the sign bit flipped, alpha fields
//                  NUL-padded. A memo field keeps a 10-byte pointer in its
//                  last bytes: block offset in the .MB (low byte = slot in a
//                  shared block) and the data length.
//   .MB blocks     type 2 holds one memo, data at +9. Type 3 is shared by small
//                  memos: a 5-byte entry per slot from +12, whose first byte is
//                  the data offset in 16-byte units.
namespace crater::paradox {

class Table
{
public:
    // Opens `dbPath` and, when the table has memo fields, the .MB file beside
    // it. Returns nullopt and sets `error` when either is missing or the .DB
    // is not a Paradox table.
    static std::optional<Table> open(const QString& dbPath, QString* error);

    // True when the first bytes of `path` look like a Paradox table header.
    // Cheap enough to call on every file the operator selects.
    static bool looksLikeTable(const QString& path);

    int recordCount() const { return int(m_records.size()); }

    // Index of the field called `name` (case-insensitive), or -1.
    int fieldIndex(const QString& name) const;

    // An alpha field as text, decoded as Windows-1252 and trimmed. Empty for
    // a NULL field, an out-of-range index or a field of another type.
    QString text(int record, int field) const;

    // The raw bytes of a memo field, read from the .MB file. Empty for a NULL
    // or unreadable memo.
    QByteArray memo(int record, int field) const;

private:
    struct Field
    {
        QString name;
        int     type   = 0;
        int     size   = 0;
        int     offset = 0;   // within a record
    };

    QByteArray        m_db;        // the whole .DB, a few MB at most
    QList<int>        m_records;   // byte offset of each record in m_db
    QList<Field>      m_fields;
    std::shared_ptr<QFile> m_memo; // the .MB, read on demand (it can be hundreds of MB)
};

}  // namespace crater::paradox
