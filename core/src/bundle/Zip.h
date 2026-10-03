#pragma once

#include <QByteArray>
#include <QByteArrayView>
#include <QList>
#include <QString>
#include <QStringView>

#include <functional>
#include <memory>

namespace crater::bundle {

// Minimal stored-only ZIP writer / reader.
//
// Written for `.craterheme` v2 bundles, which carry already-compressed
// payloads (JPEG / PNG / MP4 / TTF) plus tiny JSON. Deflate gives roughly
// 0% benefit on that mix, so we set compression method to STORE (0) and
// skip vendoring miniz / zlib. See ARCHITECTURE.md §10.
//
// `.craterprofile` archives (ARCHITECTURE.md §12) reuse it. A profile can
// hold gigabytes of video, so two things were added for them:
//   • streaming: addFile() copies a file in chunks and the reader maps the
//     archive instead of loading it, with extractToFile() streaming back out.
//   • ZIP64: entries, offsets or a central directory past the 4 GiB ZIP32
//     limits get the ZIP64 extra field / end records (APPNOTE 4.5.3). Small
//     archives are written byte-for-byte as before, so theme bundles are
//     unaffected.
//
// Both classes are non-copyable, non-movable, and meant to be stack-
// allocated for the duration of one bundle. Writer commits atomically via
// QSaveFile (tmpfile + rename — ARCHITECTURE.md §8); reader memory-maps
// the file for cheap entry lookup.

// Progress hook for the streaming calls: bytes of the current entry done so
// far. Return false to abort the operation.
using ZipProgress = std::function<bool(qint64 bytesDone)>;

class ZipWriter
{
public:
    explicit ZipWriter(QString path);
    ~ZipWriter();

    ZipWriter(const ZipWriter&) = delete;
    ZipWriter& operator=(const ZipWriter&) = delete;

    // True if construction opened the destination file successfully.
    bool isOpen() const noexcept;

    // Always write ZIP64 records, even when nothing needs them. Tests use it
    // to exercise the ZIP64 reader path without writing a 4 GiB file. Call
    // before the first addEntry/addFile.
    void setForceZip64(bool on) noexcept { m_forceZip64 = on; }

    // Append one entry. `name` is the in-archive path (forward slashes,
    // UTF-8). Returns false if a write fails (call errorString()). Names
    // are not deduplicated — caller is responsible for not adding the same
    // name twice (a content-addressed bundle handles this by construction).
    bool addEntry(QStringView name, QByteArrayView bytes);

    // Append one entry whose bytes come from a file on disk, streamed in
    // chunks so a multi-GB video never sits in memory. The file is read
    // twice (CRC first, then the copy); a file that changes in between is
    // refused rather than archived with a CRC that does not match it.
    bool addFile(QStringView name, const QString& sourcePath,
                 const ZipProgress& progress = {});

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
        uint64_t size;      // uncompressed == compressed (STORE)
        bool     zip64Local; // the LFH carries a ZIP64 extra field
    };

    void setError(QString msg);
    bool writeLocalHeader(const QByteArray& nameUtf8, uint32_t crc, uint64_t size,
                          bool zip64);

    struct Impl;
    std::unique_ptr<Impl> m_impl;
    QList<Entry>          m_entries;
    QString               m_error;
    bool                  m_forceZip64 = false;
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

    // True when two central-directory records share a name. The lookup
    // keeps only the last of them, so a caller that validates names must
    // refuse such an archive rather than trust which copy it gets.
    bool hasDuplicateNames() const noexcept;

    bool hasEntry(QStringView name) const;

    // Uncompressed size of an entry, or -1 on miss. Read from the central
    // directory, so it costs nothing and touches no payload bytes.
    qint64 entrySize(QStringView name) const;

    // Returns the entry's bytes. Empty on miss; check hasEntry() first if
    // an empty entry is a meaningful possibility (manifests, JSON files —
    // never empty in our usage).
    QByteArray readEntry(QStringView name) const;

    // Stream an entry to `destPath` without holding it in memory, checking
    // the CRC as it goes. The destination is removed on any failure,
    // including a CRC mismatch. Returns false with errorString() set.
    bool extractToFile(QStringView name, const QString& destPath,
                       const ZipProgress& progress = {});

    QString errorString() const { return m_error; }

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
    mutable QString       m_error;
};

}  // namespace crater::bundle
