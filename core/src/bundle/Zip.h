#pragma once

#include <QByteArray>
#include <QByteArrayView>
#include <QList>
#include <QString>
#include <QStringView>

#include <memory>

namespace crater::bundle {

// Minimal stored-only ZIP writer / reader.
//
// We only need this for `.craterheme` v2 bundles, which carry already-
// compressed payloads (JPEG / PNG / MP4 / TTF) plus tiny JSON. Deflate
// gives roughly 0% benefit on that mix, so we set compression method to
// STORE (0) and skip vendoring miniz / zlib. See ARCHITECTURE.md §10.
//
// Both classes are non-copyable, non-movable, and meant to be stack-
// allocated for the duration of one bundle. Writer commits atomically via
// QSaveFile (tmpfile + rename — ARCHITECTURE.md §8); reader memory-maps
// the file for cheap entry lookup.

class ZipWriter
{
public:
    explicit ZipWriter(QString path);
    ~ZipWriter();

    ZipWriter(const ZipWriter&) = delete;
    ZipWriter& operator=(const ZipWriter&) = delete;

    // True if construction opened the destination file successfully.
    bool isOpen() const noexcept;

    // Append one entry. `name` is the in-archive path (forward slashes,
    // UTF-8). Returns false if a write fails (call errorString()). Names
    // are not deduplicated — caller is responsible for not adding the same
    // name twice (a content-addressed bundle handles this by construction).
    bool addEntry(QStringView name, QByteArrayView bytes);

    // Finalize: writes the central directory + EOCD and atomically renames
    // the staging file into place. After commit(), the writer is closed
    // and addEntry() returns false. Returns true on success.
    bool commit();

    QString errorString() const { return m_error; }

private:
    struct Entry {
        QString  name;
        uint64_t offset;    // start of local file header in the staging file
        uint32_t crc;
        uint32_t size;      // uncompressed == compressed (STORE)
    };

    void setError(QString msg);

    struct Impl;
    std::unique_ptr<Impl> m_impl;
    QList<Entry>          m_entries;
    QString               m_error;
};

class ZipReader
{
public:
    explicit ZipReader(QString path);
    ~ZipReader();

    ZipReader(const ZipReader&) = delete;
    ZipReader& operator=(const ZipReader&) = delete;

    bool isOpen() const noexcept;

    // Names of every entry in the archive (in central-directory order).
    QStringList entryNames() const;

    bool hasEntry(QStringView name) const;

    // Returns the entry's bytes. Empty on miss; check hasEntry() first if
    // an empty entry is a meaningful possibility (manifests, JSON files —
    // never empty in our usage).
    QByteArray readEntry(QStringView name) const;

    QString errorString() const { return m_error; }

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
    QString               m_error;
};

}  // namespace crater::bundle
