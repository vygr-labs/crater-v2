#include "bundle/Zip.h"

#include "bundle/Crc32.h"

#include <QByteArray>
#include <QDateTime>
#include <QDebug>
#include <QFile>
#include <QHash>
#include <QSaveFile>
#include <QSet>

#include <cstring>
#include <limits>

namespace crater::bundle {

namespace {

// ─── Little-endian writers ──────────────────────────────────────────────
// ZIP is little-endian. We avoid any "host endian" assumption by byte-
// shuffling explicitly — the cost is one instruction per byte and it makes
// the on-wire layout obvious.

void appendU16(QByteArray& out, uint16_t v)
{
    out.append(char(v & 0xFF));
    out.append(char((v >> 8) & 0xFF));
}

void appendU32(QByteArray& out, uint32_t v)
{
    out.append(char(v & 0xFF));
    out.append(char((v >> 8) & 0xFF));
    out.append(char((v >> 16) & 0xFF));
    out.append(char((v >> 24) & 0xFF));
}

void appendU64(QByteArray& out, uint64_t v)
{
    appendU32(out, uint32_t(v & 0xFFFFFFFFu));
    appendU32(out, uint32_t(v >> 32));
}

uint16_t readU16(const char* p) noexcept
{
    return uint16_t(uint8_t(p[0])) | (uint16_t(uint8_t(p[1])) << 8);
}

uint32_t readU32(const char* p) noexcept
{
    return uint32_t(uint8_t(p[0]))
         | (uint32_t(uint8_t(p[1])) << 8)
         | (uint32_t(uint8_t(p[2])) << 16)
         | (uint32_t(uint8_t(p[3])) << 24);
}

uint64_t readU64(const char* p) noexcept
{
    return uint64_t(readU32(p)) | (uint64_t(readU32(p + 4)) << 32);
}

// Pack a QDateTime into DOS time/date (the legacy MS-DOS format every ZIP
// implementation still uses). Time is seconds/2, date is years-from-1980.
// We always write "now" — bundle provenance is in manifest.exportedAt.
struct DosTimeDate { uint16_t time; uint16_t date; };

DosTimeDate dosNow()
{
    const QDateTime n = QDateTime::currentDateTime();
    const QDate d = n.date();
    const QTime t = n.time();
    const int year = qMax(1980, d.year());
    DosTimeDate r;
    r.time = uint16_t((t.hour() << 11) | (t.minute() << 5) | (t.second() / 2));
    r.date = uint16_t(((year - 1980) << 9) | (d.month() << 5) | d.day());
    return r;
}

// General-purpose bit-flag: bit 11 set → filename is UTF-8 (APPNOTE 4.4.4).
// Our filenames are content-hash + extension (ASCII), but setting this
// keeps us correct if a filename ever picks up multi-byte chars.
constexpr uint16_t kGpBit_Utf8Names = 0x0800;

// Signatures.
constexpr uint32_t kSigLocal         = 0x04034b50u;
constexpr uint32_t kSigCentral       = 0x02014b50u;
constexpr uint32_t kSigEndCentral    = 0x06054b50u;
constexpr uint32_t kSigZip64End      = 0x06064b50u;
constexpr uint32_t kSigZip64Locator  = 0x07064b50u;

// ZIP64 (APPNOTE 4.5.3). A 32-bit size/offset field holding this value means
// "the real value is in the ZIP64 extended-information extra field".
constexpr uint32_t kSat32      = 0xFFFFFFFFu;
constexpr uint16_t kSat16      = 0xFFFFu;
constexpr uint16_t kZip64Extra = 0x0001;

// Streaming chunk. Big enough that per-call overhead vanishes, small enough
// that a 4 GB copy never holds more than this in memory.
constexpr qint64 kChunk = 4 * 1024 * 1024;

}  // namespace

// ═══════════════════════════════════════════════════════════════════════
// ZipWriter
// ═══════════════════════════════════════════════════════════════════════

struct ZipWriter::Impl
{
    QSaveFile file;
    bool      closed = false;

    explicit Impl(const QString& path) : file(path) {}
};

ZipWriter::ZipWriter(QString path)
    : m_impl(std::make_unique<Impl>(path))
{
    if (!m_impl->file.open(QIODevice::WriteOnly)) {
        setError(QStringLiteral("ZipWriter: cannot open %1: %2")
                     .arg(path, m_impl->file.errorString()));
        m_impl.reset();
    }
}

ZipWriter::~ZipWriter()
{
    // Don't auto-commit. If we got destroyed without commit(), the QSaveFile
    // destructor cancels the staging file — exactly what we want on a
    // partial write or exception.
    if (m_impl && !m_impl->closed) {
        m_impl->file.cancelWriting();
    }
}

bool ZipWriter::isOpen() const noexcept
{
    return m_impl && !m_impl->closed && m_impl->file.isOpen();
}

void ZipWriter::setError(QString msg)
{
    if (m_error.isEmpty()) m_error = std::move(msg);
}

bool ZipWriter::writeLocalHeader(const QByteArray& nameUtf8, uint32_t crc,
                                 uint64_t size, bool zip64)
{
    const auto dt = dosNow();

    QByteArray lfh;
    lfh.reserve(30 + nameUtf8.size() + (zip64 ? 20 : 0));
    appendU32(lfh, kSigLocal);
    appendU16(lfh, zip64 ? 45 : 20);     // version needed: 4.5 (ZIP64) / 2.0 (STORE)
    appendU16(lfh, kGpBit_Utf8Names);    // gp bit flag
    appendU16(lfh, 0);                   // method: STORE
    appendU16(lfh, dt.time);
    appendU16(lfh, dt.date);
    appendU32(lfh, crc);
    appendU32(lfh, zip64 ? kSat32 : uint32_t(size));   // compressed (== uncompressed)
    appendU32(lfh, zip64 ? kSat32 : uint32_t(size));   // uncompressed
    appendU16(lfh, uint16_t(nameUtf8.size()));
    appendU16(lfh, zip64 ? 20 : 0);      // extra field length
    lfh.append(nameUtf8);
    if (zip64) {
        // In a local header both sizes MUST be present (APPNOTE 4.5.3).
        appendU16(lfh, kZip64Extra);
        appendU16(lfh, 16);
        appendU64(lfh, size);            // uncompressed
        appendU64(lfh, size);            // compressed
    }

    if (m_impl->file.write(lfh) != lfh.size()) {
        setError(QStringLiteral("ZipWriter: write LFH failed: %1")
                     .arg(m_impl->file.errorString()));
        return false;
    }
    return true;
}

bool ZipWriter::addEntry(QStringView name, QByteArrayView bytes)
{
    if (!isOpen()) return false;

    const QByteArray nameUtf8 = name.toString().toUtf8();
    if (nameUtf8.size() > 0xFFFE) {
        setError(QStringLiteral("ZipWriter: entry name too long"));
        return false;
    }

    const uint32_t crc    = Crc32::of(bytes);
    const uint64_t size   = uint64_t(bytes.size());
    const uint64_t offset = uint64_t(m_impl->file.pos());
    const bool     zip64  = m_forceZip64 || size >= kSat32;

    if (!writeLocalHeader(nameUtf8, crc, size, zip64)) return false;
    if (size > 0 && m_impl->file.write(bytes.data(), bytes.size()) != bytes.size()) {
        setError(QStringLiteral("ZipWriter: write payload failed: %1")
                     .arg(m_impl->file.errorString()));
        return false;
    }

    m_entries.append(Entry{ name.toString(), offset, crc, size, zip64 });
    return true;
}

bool ZipWriter::addFile(QStringView name, const QString& sourcePath,
                        const ZipProgress& progress)
{
    if (!isOpen()) return false;

    const QByteArray nameUtf8 = name.toString().toUtf8();
    if (nameUtf8.size() > 0xFFFE) {
        setError(QStringLiteral("ZipWriter: entry name too long"));
        return false;
    }

    QFile src(sourcePath);
    if (!src.open(QIODevice::ReadOnly)) {
        setError(QStringLiteral("ZipWriter: cannot read %1: %2")
                     .arg(sourcePath, src.errorString()));
        return false;
    }

    // Pass 1: CRC + size. The local header carries both and precedes the
    // payload, and we do not use the data-descriptor variant (bit 3), which
    // some readers handle badly for STORE entries.
    Crc32    crc;
    uint64_t size = 0;
    {
        QByteArray buf;
        while (true) {
            buf = src.read(kChunk);
            if (buf.isEmpty()) break;
            crc.update(buf);
            size += uint64_t(buf.size());
        }
        if (src.error() != QFileDevice::NoError) {
            setError(QStringLiteral("ZipWriter: read failed for %1: %2")
                         .arg(sourcePath, src.errorString()));
            return false;
        }
    }

    const uint64_t offset = uint64_t(m_impl->file.pos());
    const bool     zip64  = m_forceZip64 || size >= kSat32;
    if (!writeLocalHeader(nameUtf8, crc.value(), size, zip64)) return false;

    // Pass 2: copy, re-checking the CRC so a file edited between the passes
    // fails loudly instead of producing an entry no reader will accept.
    if (!src.seek(0)) {
        setError(QStringLiteral("ZipWriter: cannot rewind %1").arg(sourcePath));
        return false;
    }
    Crc32    again;
    uint64_t copied = 0;
    while (true) {
        const QByteArray buf = src.read(kChunk);
        if (buf.isEmpty()) break;
        again.update(buf);
        copied += uint64_t(buf.size());
        if (m_impl->file.write(buf) != buf.size()) {
            setError(QStringLiteral("ZipWriter: write payload failed: %1")
                         .arg(m_impl->file.errorString()));
            return false;
        }
        if (progress && !progress(qint64(copied))) {
            setError(QStringLiteral("ZipWriter: cancelled"));
            return false;
        }
    }
    if (copied != size || again.value() != crc.value()) {
        setError(QStringLiteral("ZipWriter: %1 changed while it was being archived")
                     .arg(sourcePath));
        return false;
    }

    m_entries.append(Entry{ name.toString(), offset, crc.value(), size, zip64 });
    return true;
}

bool ZipWriter::commit()
{
    if (!isOpen()) return false;

    const uint64_t cdOffset = uint64_t(m_impl->file.pos());

    // ── Central directory ───────────────────────────────────────────────
    QByteArray cd;
    for (const Entry& e : m_entries) {
        const QByteArray nameUtf8 = e.name.toUtf8();
        const auto       dt       = dosNow();
        // An entry needs the ZIP64 field here when its size or its header
        // offset does not fit 32 bits. All three fields are saturated
        // together so the extra field always carries all three in order.
        const bool zip64 = e.zip64Local || e.size >= kSat32 || e.offset >= kSat32;

        appendU32(cd, kSigCentral);
        appendU16(cd, zip64 ? 0x032d : 0x031e);   // version made by: 4.5 / 3.0, Unix
        appendU16(cd, zip64 ? 45 : 20);           // version needed
        appendU16(cd, kGpBit_Utf8Names);          // gp bit flag
        appendU16(cd, 0);                         // method: STORE
        appendU16(cd, dt.time);
        appendU16(cd, dt.date);
        appendU32(cd, e.crc);
        appendU32(cd, zip64 ? kSat32 : uint32_t(e.size));     // compressed
        appendU32(cd, zip64 ? kSat32 : uint32_t(e.size));     // uncompressed
        appendU16(cd, uint16_t(nameUtf8.size()));
        appendU16(cd, zip64 ? 28 : 0);            // extra field length
        appendU16(cd, 0);                         // file comment length
        appendU16(cd, 0);                         // disk number start
        appendU16(cd, 0);                         // internal attrs
        appendU32(cd, 0);                         // external attrs
        appendU32(cd, zip64 ? kSat32 : uint32_t(e.offset));   // LFH offset
        cd.append(nameUtf8);
        if (zip64) {
            appendU16(cd, kZip64Extra);
            appendU16(cd, 24);
            appendU64(cd, e.size);    // uncompressed
            appendU64(cd, e.size);    // compressed
            appendU64(cd, e.offset);  // local header offset
        }
    }

    if (m_impl->file.write(cd) != cd.size()) {
        setError(QStringLiteral("ZipWriter: write CD failed: %1")
                     .arg(m_impl->file.errorString()));
        m_impl->file.cancelWriting();
        return false;
    }

    const uint64_t cdSize  = uint64_t(cd.size());
    const uint64_t count   = uint64_t(m_entries.size());
    const bool     zip64End = m_forceZip64 || count >= kSat16
                           || cdSize >= kSat32 || cdOffset >= kSat32;

    QByteArray tail;
    if (zip64End) {
        // ── ZIP64 end of central directory record + locator ─────────────
        const uint64_t z64Offset = uint64_t(m_impl->file.pos());
        appendU32(tail, kSigZip64End);
        appendU64(tail, 44);           // size of the record after this field
        appendU16(tail, 0x032d);       // version made by
        appendU16(tail, 45);           // version needed
        appendU32(tail, 0);            // this disk
        appendU32(tail, 0);            // disk with the CD
        appendU64(tail, count);        // entries on this disk
        appendU64(tail, count);        // total entries
        appendU64(tail, cdSize);
        appendU64(tail, cdOffset);

        appendU32(tail, kSigZip64Locator);
        appendU32(tail, 0);            // disk with the ZIP64 EOCD
        appendU64(tail, z64Offset);
        appendU32(tail, 1);            // total disks
    }

    // ── End of central directory ────────────────────────────────────────
    // With ZIP64 every field is saturated, so a reader can never take a
    // truncated 32-bit value at face value.
    appendU32(tail, kSigEndCentral);
    appendU16(tail, 0);                                            // disk number
    appendU16(tail, 0);                                            // disk where CD starts
    appendU16(tail, zip64End ? kSat16 : uint16_t(count));          // CD entries on this disk
    appendU16(tail, zip64End ? kSat16 : uint16_t(count));          // total CD entries
    appendU32(tail, zip64End ? kSat32 : uint32_t(cdSize));         // CD size
    appendU32(tail, zip64End ? kSat32 : uint32_t(cdOffset));       // CD offset
    appendU16(tail, 0);                                            // zip comment length

    if (m_impl->file.write(tail) != tail.size()) {
        setError(QStringLiteral("ZipWriter: write EOCD failed: %1")
                     .arg(m_impl->file.errorString()));
        m_impl->file.cancelWriting();
        return false;
    }

    if (!m_impl->file.commit()) {
        setError(QStringLiteral("ZipWriter: QSaveFile commit failed: %1")
                     .arg(m_impl->file.errorString()));
        return false;
    }

    m_impl->closed = true;
    return true;
}

// ═══════════════════════════════════════════════════════════════════════
// ZipReader
// ═══════════════════════════════════════════════════════════════════════

struct ZipReader::Impl
{
    QFile       file;
    QByteArray  buffer;          // only used when mapping is unavailable
    const char* data = nullptr;  // mapped view (or buffer.constData())
    qint64      size = 0;

    struct CdEntry {
        uint16_t method;
        uint32_t crc;
        uint64_t compressedSize;
        uint64_t uncompressedSize;
        uint64_t lfhOffset;
    };

    QHash<QString, CdEntry> byName;
    QStringList             order;   // CD-order of names (for entryNames())
    bool                    duplicateNames = false;

    explicit Impl(const QString& path) : file(path) {}

    // Locate an entry's payload. Returns -1 when the local header is
    // missing, out of range or the method is not STORE.
    qint64 payloadOffset(const CdEntry& e) const
    {
        if (e.lfhOffset > uint64_t(size) || uint64_t(size) - e.lfhOffset < 30) return -1;
        const qint64 lfh = qint64(e.lfhOffset);
        if (readU32(data + lfh) != kSigLocal) return -1;
        const uint16_t nLen = readU16(data + lfh + 26);
        const uint16_t xLen = readU16(data + lfh + 28);
        const qint64 dataAt = lfh + 30 + nLen + xLen;
        if (dataAt > size || uint64_t(size - dataAt) < e.compressedSize) return -1;
        // We only emit STORE; reject anything else explicitly rather than
        // silently mis-extracting (an attacker-shaped bundle would set
        // method=DEFLATE without us having a decompressor). STORE means the
        // two sizes agree; a record claiming otherwise is malformed.
        if (e.method != 0 || e.compressedSize != e.uncompressedSize) return -1;
        return dataAt;
    }
};

ZipReader::ZipReader(QString path)
    : m_impl(std::make_unique<Impl>(path))
{
    if (!m_impl->file.open(QIODevice::ReadOnly)) {
        m_error = QStringLiteral("ZipReader: cannot open %1: %2")
                      .arg(path, m_impl->file.errorString());
        m_impl.reset();
        return;
    }
    const qint64 size = m_impl->file.size();
    if (size < 22) {
        m_error = QStringLiteral("ZipReader: file too small to be a zip (%1 bytes)").arg(size);
        m_impl.reset();
        return;
    }

    // Map the file rather than reading it: a theme bundle is small, but a
    // profile archive can hold gigabytes of video. The mapping stays valid
    // for the reader's lifetime (QFile unmaps on destruction). A filesystem
    // that refuses mapping falls back to reading, for small files only.
    if (uchar* mapped = m_impl->file.map(0, size)) {
        m_impl->data = reinterpret_cast<const char*>(mapped);
    } else {
        constexpr qint64 kMaxBuffered = qint64(512) * 1024 * 1024;
        if (size > kMaxBuffered) {
            m_error = QStringLiteral("ZipReader: cannot map %1 (%2 bytes)").arg(path).arg(size);
            m_impl.reset();
            return;
        }
        m_impl->buffer = m_impl->file.readAll();
        if (m_impl->buffer.size() != size) {
            m_error = QStringLiteral("ZipReader: short read (%1 of %2)")
                          .arg(m_impl->buffer.size()).arg(size);
            m_impl.reset();
            return;
        }
        m_impl->data = m_impl->buffer.constData();
    }
    m_impl->size = size;

    // Locate End of Central Directory. EOCD is fixed 22 bytes minimum at
    // the tail, but allows a trailing comment. Scan backward up to 64 KiB
    // (max comment length) looking for the signature. Bundles we write have
    // no comment, so we'll find it at exactly size-22 in practice.
    const char* d = m_impl->data;
    qint64 eocdPos = -1;
    const qint64 minScan = qMax<qint64>(0, size - (22 + 0xFFFF));
    for (qint64 i = size - 22; i >= minScan; --i) {
        if (readU32(d + i) == kSigEndCentral) { eocdPos = i; break; }
    }
    if (eocdPos < 0) {
        m_error = QStringLiteral("ZipReader: no EOCD signature (not a zip?)");
        m_impl.reset();
        return;
    }

    uint64_t totalEntries = readU16(d + eocdPos + 10);
    uint64_t cdSize       = readU32(d + eocdPos + 12);
    uint64_t cdOffset     = readU32(d + eocdPos + 16);

    // ZIP64: a saturated field means the real values live in the ZIP64 end
    // record, found through the locator that sits right before the EOCD.
    if (totalEntries == kSat16 || cdSize == kSat32 || cdOffset == kSat32) {
        const qint64 locPos = eocdPos - 20;
        if (locPos < 0 || readU32(d + locPos) != kSigZip64Locator) {
            m_error = QStringLiteral("ZipReader: saturated EOCD without a ZIP64 locator");
            m_impl.reset();
            return;
        }
        const uint64_t z64 = readU64(d + locPos + 8);
        if (z64 > uint64_t(size) || uint64_t(size) - z64 < 56
            || readU32(d + qint64(z64)) != kSigZip64End) {
            m_error = QStringLiteral("ZipReader: ZIP64 end record out of range");
            m_impl.reset();
            return;
        }
        totalEntries = readU64(d + qint64(z64) + 32);
        cdSize       = readU64(d + qint64(z64) + 40);
        cdOffset     = readU64(d + qint64(z64) + 48);
    }

    if (cdOffset > uint64_t(size) || cdSize > uint64_t(size) - cdOffset) {
        m_error = QStringLiteral("ZipReader: central directory out of range");
        m_impl.reset();
        return;
    }
    // Every record is at least 46 bytes, so a count the directory cannot
    // physically hold is a hostile or corrupt header. Refuse it before the
    // loop rather than spin through billions of iterations.
    if (totalEntries > cdSize / 46) {
        m_error = QStringLiteral("ZipReader: entry count exceeds the central directory");
        m_impl.reset();
        return;
    }

    // Walk the central directory.
    const qint64 cdEnd = qint64(cdOffset + cdSize);
    qint64 p = qint64(cdOffset);
    QSet<QString> seen;
    for (uint64_t i = 0; i < totalEntries; ++i) {
        if (p + 46 > cdEnd || readU32(d + p) != kSigCentral) {
            m_error = QStringLiteral("ZipReader: malformed CD at entry %1").arg(i);
            m_impl.reset();
            return;
        }
        Impl::CdEntry e;
        e.method           = readU16(d + p + 10);
        e.crc              = readU32(d + p + 16);
        e.compressedSize   = readU32(d + p + 20);
        e.uncompressedSize = readU32(d + p + 24);
        const uint16_t nLen = readU16(d + p + 28);
        const uint16_t xLen = readU16(d + p + 30);
        const uint16_t cLen = readU16(d + p + 32);
        e.lfhOffset        = readU32(d + p + 42);

        if (p + 46 + nLen + xLen + cLen > cdEnd) {
            m_error = QStringLiteral("ZipReader: name overruns at entry %1").arg(i);
            m_impl.reset();
            return;
        }

        // ZIP64 extended information: present only for the fields saturated
        // above, in the fixed order uncompressed, compressed, offset.
        if (e.uncompressedSize == kSat32 || e.compressedSize == kSat32
            || e.lfhOffset == kSat32) {
            qint64 q = p + 46 + nLen;
            const qint64 xEnd = q + xLen;
            bool found = false;
            while (q + 4 <= xEnd) {
                const uint16_t id = readU16(d + q);
                const uint16_t sz = readU16(d + q + 2);
                if (q + 4 + sz > xEnd) break;
                if (id == kZip64Extra) {
                    qint64 r = q + 4;
                    const qint64 rEnd = r + sz;
                    bool ok = true;
                    auto take = [&](uint64_t& field) {
                        if (field != kSat32) return;
                        if (r + 8 > rEnd) { ok = false; return; }
                        field = readU64(d + r);
                        r += 8;
                    };
                    take(e.uncompressedSize);
                    take(e.compressedSize);
                    take(e.lfhOffset);
                    found = ok;
                    break;
                }
                q += 4 + sz;
            }
            if (!found) {
                m_error = QStringLiteral("ZipReader: missing ZIP64 field at entry %1").arg(i);
                m_impl.reset();
                return;
            }
        }

        const QString name = QString::fromUtf8(d + p + 46, nLen);
        if (seen.contains(name)) m_impl->duplicateNames = true;
        seen.insert(name);
        m_impl->byName.insert(name, e);
        m_impl->order.append(name);

        p += 46 + nLen + xLen + cLen;
    }
}

ZipReader::~ZipReader() = default;

bool ZipReader::isOpen() const noexcept
{
    return m_impl != nullptr;
}

QStringList ZipReader::entryNames() const
{
    if (!m_impl) return {};
    return m_impl->order;
}

bool ZipReader::hasDuplicateNames() const noexcept
{
    return m_impl && m_impl->duplicateNames;
}

bool ZipReader::hasEntry(QStringView name) const
{
    if (!m_impl) return false;
    return m_impl->byName.contains(name.toString());
}

qint64 ZipReader::entrySize(QStringView name) const
{
    if (!m_impl) return -1;
    const auto it = m_impl->byName.constFind(name.toString());
    if (it == m_impl->byName.constEnd()) return -1;
    return qint64(it.value().uncompressedSize);
}

QByteArray ZipReader::readEntry(QStringView name) const
{
    if (!m_impl) return {};
    const auto it = m_impl->byName.constFind(name.toString());
    if (it == m_impl->byName.constEnd()) return {};
    const auto& e = it.value();

    // Read the local file header to discover the actual data offset
    // (because LFH name + extra fields can differ from CD's).
    const qint64 dataAt = m_impl->payloadOffset(e);
    if (dataAt < 0) return {};
    if (e.compressedSize > uint64_t(std::numeric_limits<qsizetype>::max())) return {};

    QByteArray out(m_impl->data + dataAt, qsizetype(e.compressedSize));
    // Verify CRC — cheap (table-driven) and catches both bit-rot and
    // hostile tampering at the zip-format layer. Higher layers should
    // hash-check too, but a CRC mismatch here is already a refusable
    // failure mode.
    if (Crc32::of(out) != e.crc) return {};
    return out;
}

bool ZipReader::extractToFile(QStringView name, const QString& destPath,
                              const ZipProgress& progress)
{
    m_error.clear();
    if (!m_impl) {
        m_error = QStringLiteral("ZipReader: not open");
        return false;
    }
    const auto it = m_impl->byName.constFind(name.toString());
    if (it == m_impl->byName.constEnd()) {
        m_error = QStringLiteral("ZipReader: no entry %1").arg(name.toString());
        return false;
    }
    const auto& e = it.value();
    const qint64 dataAt = m_impl->payloadOffset(e);
    if (dataAt < 0) {
        m_error = QStringLiteral("ZipReader: entry %1 is malformed").arg(name.toString());
        return false;
    }

    QFile out(destPath);
    if (!out.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        m_error = QStringLiteral("ZipReader: cannot write %1: %2")
                      .arg(destPath, out.errorString());
        return false;
    }

    Crc32 crc;
    const qint64 total = qint64(e.compressedSize);
    qint64 done = 0;
    while (done < total) {
        const qint64 n = qMin(kChunk, total - done);
        const QByteArrayView chunk(m_impl->data + dataAt + done, qsizetype(n));
        crc.update(chunk);
        if (out.write(chunk.data(), n) != n) {
            m_error = QStringLiteral("ZipReader: write failed for %1: %2")
                          .arg(destPath, out.errorString());
            out.close();
            out.remove();
            return false;
        }
        done += n;
        if (progress && !progress(done)) {
            m_error = QStringLiteral("ZipReader: cancelled");
            out.close();
            out.remove();
            return false;
        }
    }
    out.close();
    if (out.error() != QFileDevice::NoError || crc.value() != e.crc) {
        m_error = crc.value() != e.crc
            ? QStringLiteral("ZipReader: CRC mismatch for %1").arg(name.toString())
            : QStringLiteral("ZipReader: write failed for %1").arg(destPath);
        out.remove();
        return false;
    }
    return true;
}

}  // namespace crater::bundle
