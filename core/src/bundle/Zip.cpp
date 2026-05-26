#include "bundle/Zip.h"

#include "bundle/Crc32.h"

#include <QByteArray>
#include <QDateTime>
#include <QDebug>
#include <QFile>
#include <QHash>
#include <QSaveFile>

#include <cstring>

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
constexpr uint32_t kSigLocal       = 0x04034b50u;
constexpr uint32_t kSigCentral     = 0x02014b50u;
constexpr uint32_t kSigEndCentral  = 0x06054b50u;

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

bool ZipWriter::addEntry(QStringView name, QByteArrayView bytes)
{
    if (!isOpen()) return false;

    // Cap at 4 GiB - 1 — we're writing a ZIP32 archive (no ZIP64 records).
    // No theme bundle should approach this; a single 4 GiB media file would
    // already be at MediaService's import-size cap (§5.1) and we never
    // bundle more than one of those.
    if (bytes.size() > qint64(0xFFFFFFFEu)) {
        setError(QStringLiteral("ZipWriter: entry too large (%1 bytes)").arg(bytes.size()));
        return false;
    }

    const QByteArray nameUtf8 = name.toString().toUtf8();
    if (nameUtf8.size() > 0xFFFE) {
        setError(QStringLiteral("ZipWriter: entry name too long"));
        return false;
    }

    const uint32_t crc  = Crc32::of(bytes);
    const uint32_t size = uint32_t(bytes.size());
    const auto     dt   = dosNow();
    const uint64_t offset = uint64_t(m_impl->file.pos());

    // ── Local file header ───────────────────────────────────────────────
    QByteArray lfh;
    lfh.reserve(30 + nameUtf8.size());
    appendU32(lfh, kSigLocal);
    appendU16(lfh, 20);                  // version needed: 2.0 (STORE)
    appendU16(lfh, kGpBit_Utf8Names);    // gp bit flag
    appendU16(lfh, 0);                   // method: STORE
    appendU16(lfh, dt.time);
    appendU16(lfh, dt.date);
    appendU32(lfh, crc);
    appendU32(lfh, size);                // compressed (== uncompressed)
    appendU32(lfh, size);                // uncompressed
    appendU16(lfh, uint16_t(nameUtf8.size()));
    appendU16(lfh, 0);                   // extra field length
    lfh.append(nameUtf8);

    if (m_impl->file.write(lfh) != lfh.size()) {
        setError(QStringLiteral("ZipWriter: write LFH failed: %1")
                     .arg(m_impl->file.errorString()));
        return false;
    }
    if (size > 0 && m_impl->file.write(bytes.data(), bytes.size()) != bytes.size()) {
        setError(QStringLiteral("ZipWriter: write payload failed: %1")
                     .arg(m_impl->file.errorString()));
        return false;
    }

    m_entries.append(Entry{ name.toString(), offset, crc, size });
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

        appendU32(cd, kSigCentral);
        appendU16(cd, 0x031e);            // version made by: 3.0 / Unix
        appendU16(cd, 20);                // version needed
        appendU16(cd, kGpBit_Utf8Names);  // gp bit flag
        appendU16(cd, 0);                 // method: STORE
        appendU16(cd, dt.time);
        appendU16(cd, dt.date);
        appendU32(cd, e.crc);
        appendU32(cd, e.size);            // compressed
        appendU32(cd, e.size);            // uncompressed
        appendU16(cd, uint16_t(nameUtf8.size()));
        appendU16(cd, 0);                 // extra field length
        appendU16(cd, 0);                 // file comment length
        appendU16(cd, 0);                 // disk number start
        appendU16(cd, 0);                 // internal attrs
        appendU32(cd, 0);                 // external attrs
        appendU32(cd, uint32_t(e.offset));// LFH offset (ZIP32; we assert <4 GiB below)
        cd.append(nameUtf8);
    }

    if (cdOffset > 0xFFFFFFFFu) {
        setError(QStringLiteral("ZipWriter: archive exceeds ZIP32 4 GiB total — refusing to write"));
        m_impl->file.cancelWriting();
        return false;
    }

    if (m_impl->file.write(cd) != cd.size()) {
        setError(QStringLiteral("ZipWriter: write CD failed: %1")
                     .arg(m_impl->file.errorString()));
        m_impl->file.cancelWriting();
        return false;
    }

    // ── End of central directory ────────────────────────────────────────
    QByteArray eocd;
    appendU32(eocd, kSigEndCentral);
    appendU16(eocd, 0);                              // disk number
    appendU16(eocd, 0);                              // disk where CD starts
    appendU16(eocd, uint16_t(m_entries.size()));     // CD entries on this disk
    appendU16(eocd, uint16_t(m_entries.size()));     // total CD entries
    appendU32(eocd, uint32_t(cd.size()));            // CD size
    appendU32(eocd, uint32_t(cdOffset));             // CD offset
    appendU16(eocd, 0);                              // zip comment length

    if (m_impl->file.write(eocd) != eocd.size()) {
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
    QFile      file;
    QByteArray data;   // memory-mapped view if possible, else loaded buffer

    struct CdEntry {
        uint16_t method;
        uint32_t crc;
        uint32_t compressedSize;
        uint32_t uncompressedSize;
        uint32_t lfhOffset;
    };

    QHash<QString, CdEntry> byName;
    QStringList             order;   // CD-order of names (for entryNames())

    explicit Impl(const QString& path) : file(path) {}
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

    // Read whole file. Bundles are bounded (~hundreds of MB at most — single
    // background video plus a font or two), so the simplicity beats mmap
    // here. If we ever bundle multi-GB content, switch to QFile::map().
    m_impl->data = m_impl->file.readAll();
    if (m_impl->data.size() != size) {
        m_error = QStringLiteral("ZipReader: short read (%1 of %2)").arg(m_impl->data.size()).arg(size);
        m_impl.reset();
        return;
    }

    // Locate End of Central Directory. EOCD is fixed 22 bytes minimum at
    // the tail, but allows a trailing comment. Scan backward up to 64 KiB
    // (max comment length) looking for the signature. Bundles we write have
    // no comment, so we'll find it at exactly size-22 in practice.
    const char* d = m_impl->data.constData();
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

    const uint16_t totalEntries = readU16(d + eocdPos + 10);
    const uint32_t cdSize       = readU32(d + eocdPos + 12);
    const uint32_t cdOffset     = readU32(d + eocdPos + 16);

    if (qint64(cdOffset) + qint64(cdSize) > size) {
        m_error = QStringLiteral("ZipReader: central directory out of range");
        m_impl.reset();
        return;
    }

    // Walk the central directory.
    qint64 p = cdOffset;
    for (int i = 0; i < totalEntries; ++i) {
        if (p + 46 > size || readU32(d + p) != kSigCentral) {
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

        if (p + 46 + nLen > size) {
            m_error = QStringLiteral("ZipReader: name overruns at entry %1").arg(i);
            m_impl.reset();
            return;
        }
        const QString name = QString::fromUtf8(d + p + 46, nLen);
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

bool ZipReader::hasEntry(QStringView name) const
{
    if (!m_impl) return false;
    return m_impl->byName.contains(name.toString());
}

QByteArray ZipReader::readEntry(QStringView name) const
{
    if (!m_impl) return {};
    const auto it = m_impl->byName.constFind(name.toString());
    if (it == m_impl->byName.constEnd()) return {};
    const auto& e = it.value();

    // Read the local file header to discover the actual data offset
    // (because LFH name + extra fields can differ from CD's).
    const char* d = m_impl->data.constData();
    const qint64 size = m_impl->data.size();
    const qint64 lfh = e.lfhOffset;
    if (lfh + 30 > size || readU32(d + lfh) != kSigLocal) return {};

    const uint16_t nLen = readU16(d + lfh + 26);
    const uint16_t xLen = readU16(d + lfh + 28);
    const qint64 dataAt = lfh + 30 + nLen + xLen;
    if (dataAt + qint64(e.compressedSize) > size) return {};

    if (e.method != 0) {
        // We only emit STORE; reject anything else explicitly rather than
        // silently mis-extracting (an attacker-shaped bundle would set
        // method=DEFLATE without us having a decompressor).
        return {};
    }

    QByteArray out(d + dataAt, qsizetype(e.compressedSize));
    // Verify CRC — cheap (table-driven) and catches both bit-rot and
    // hostile tampering at the zip-format layer. Higher layers should
    // hash-check too, but a CRC mismatch here is already a refusable
    // failure mode.
    if (Crc32::of(out) != e.crc) return {};
    return out;
}

}  // namespace crater::bundle
