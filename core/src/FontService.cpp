#include "crater/FontService.h"

#include "db/Connection.h"
#include "db/DbPaths.h"
#include "db/Error.h"
#include "db/Statement.h"

#include <QByteArray>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QFontDatabase>

#include <optional>

namespace crater {

namespace {

// Font-format magic-byte sniffer. Returns the canonical extension
// (".ttf" or ".otf") for the formats we accept, or empty string for
// anything we don't recognize.
//
// We accept only direct font containers — TrueType (0x00010000),
// Mac-flavor TrueType ("true"), OpenType/CFF ("OTTO"). We deliberately
// refuse:
//   • TrueType Collections ("ttcf") — multi-face container, family
//     resolution is ambiguous without picking a specific subface.
//   • WOFF / WOFF2 — web font containers; QFontDatabase doesn't accept
//     them on every platform and they'd add a decompression dependency.
// A theme bundle that ships these will see the font skipped at import
// (per ARCHITECTURE.md §10.4's best-effort policy) with a warning;
// the theme still loads, the font falls back.
QString sniffFontExt(QByteArrayView bytes)
{
    if (bytes.size() < 4) return {};
    const auto p = reinterpret_cast<const unsigned char*>(bytes.data());

    // TTF: SFNT version 0x00010000
    if (p[0] == 0x00 && p[1] == 0x01 && p[2] == 0x00 && p[3] == 0x00)
        return QStringLiteral(".ttf");

    // Mac-style TrueType
    if (p[0] == 't' && p[1] == 'r' && p[2] == 'u' && p[3] == 'e')
        return QStringLiteral(".ttf");

    // OpenType (CFF)
    if (p[0] == 'O' && p[1] == 'T' && p[2] == 'T' && p[3] == 'O')
        return QStringLiteral(".otf");

    return {};
}

QString sha256Hex(QByteArrayView bytes)
{
    return QString::fromLatin1(QCryptographicHash::hash(
        QByteArray::fromRawData(bytes.data(), bytes.size()),
        QCryptographicHash::Sha256).toHex());
}

}  // namespace

struct FontService::Impl
{
    db::Connection conn;

    db::Statement selectAll;
    db::Statement selectByHash;
    db::Statement selectByFamily;
    db::Statement selectById;
    db::Statement insertFont;
    db::Statement deleteById;

    // Maps a user_fonts row id to the QFontDatabase application-font id
    // returned at registration time. We need this to call
    // removeApplicationFont() when the operator deletes a font — without
    // it, the font stays loaded for the rest of the session and would
    // confuse the operator who just clicked "remove" and still sees it
    // in the editor's font picker. The map is rebuilt on every session
    // start by the constructor's re-register loop.
    QHash<qint64, int> regIdByDbId;

    std::optional<QList<UserFont>> cachedAll;

    explicit Impl(const QString& path)
        : conn(path, db::OpenMode::ReadWriteCreate, QStringLiteral("FontService"))
        , selectAll(conn.prepare(QStringLiteral(
            "SELECT id, hash, family, path, added_at FROM user_fonts ORDER BY family")))
        , selectByHash(conn.prepare(QStringLiteral(
            "SELECT id, hash, family, path, added_at FROM user_fonts WHERE hash = ?")))
        , selectByFamily(conn.prepare(QStringLiteral(
            "SELECT id, hash, family, path, added_at FROM user_fonts WHERE family = ? LIMIT 1")))
        , selectById(conn.prepare(QStringLiteral(
            "SELECT id, hash, family, path, added_at FROM user_fonts WHERE id = ?")))
        , insertFont(conn.prepare(QStringLiteral(
            "INSERT INTO user_fonts (hash, family, path, added_at) VALUES (?, ?, ?, ?)")))
        , deleteById(conn.prepare(QStringLiteral(
            "DELETE FROM user_fonts WHERE id = ?")))
    {}

    static UserFont readRow(db::Statement& s)
    {
        UserFont f;
        f.id      = s.columnInt64(0);
        f.hash    = s.columnText (1);
        f.family  = s.columnText (2);
        f.path    = s.columnText (3);
        f.addedAt = s.columnInt64(4);
        return f;
    }
};

FontService::FontService(QObject* parent)
    : QObject(parent)
{
    try {
        m_impl = std::make_unique<Impl>(db::DbPaths::appDbPath());
    } catch (const db::Error& e) {
        qCritical().noquote() << "FontService: failed to open DB —" << e.message();
        return;
    }

    // Re-register every previously-imported font with QFontDatabase so
    // themes referencing those families render correctly from this
    // session's first paint. Without this step a font present in the
    // DB-but-not-loaded would fall back silently to a system font; the
    // operator would see slightly-wrong typography with no diagnostic.
    // See header comment on Lifecycle.
    int loaded = 0;
    int failed = 0;
    for (const UserFont& f : allFonts()) {
        QFile file(f.path);
        if (!file.open(QIODevice::ReadOnly)) {
            qWarning().noquote() << "FontService: cannot reopen font" << f.path
                                 << "—" << file.errorString();
            ++failed;
            continue;
        }
        const QByteArray bytes = file.readAll();
        const int id = QFontDatabase::addApplicationFontFromData(bytes);
        if (id < 0) {
            qWarning().noquote() << "FontService: re-register failed for" << f.path;
            ++failed;
        } else {
            m_impl->regIdByDbId.insert(f.id, id);
            ++loaded;
        }
    }
    if (loaded > 0 || failed > 0) {
        qInfo().noquote() << "FontService: re-registered" << loaded
                          << "user font(s) at startup (" << failed << "failed)";
    }
}

FontService::~FontService() = default;

void FontService::invalidateCache()
{
    if (m_impl) m_impl->cachedAll.reset();
    emit allFontsChanged();
}

QList<UserFont> FontService::allFonts()
{
    if (!m_impl) return {};
    if (m_impl->cachedAll) return *m_impl->cachedAll;

    QList<UserFont> out;
    try {
        auto& s = m_impl->selectAll;
        s.reset();
        while (s.step()) out.append(Impl::readRow(s));
    } catch (const db::Error& e) {
        qWarning().noquote() << "FontService::allFonts():" << e.message();
    }
    m_impl->cachedAll = out;
    return out;
}

UserFont FontService::importFontFile(QString path)
{
    m_lastError.clear();
    if (!m_impl) {
        m_lastError = QStringLiteral("FontService not initialized");
        return {};
    }

    QFile src(path);
    if (!src.open(QIODevice::ReadOnly)) {
        m_lastError = QStringLiteral("cannot open %1: %2").arg(path, src.errorString());
        return {};
    }
    const QByteArray bytes = src.readAll();
    src.close();

    const QString ext = sniffFontExt(bytes);
    if (ext.isEmpty()) {
        m_lastError = QStringLiteral("unrecognized font format (not TTF/OTF)");
        return {};
    }

    const QString hash = sha256Hex(bytes);

    // Dedup: already imported? Return the existing row unchanged.
    try {
        auto& s = m_impl->selectByHash;
        s.reset();
        s.bind(1, hash);
        const bool hit = s.step();
        UserFont existing;
        if (hit) existing = Impl::readRow(s);
        s.reset();   // close cursor before the insertFont write / dedup return
        if (hit) return existing;
    } catch (const db::Error& e) {
        m_lastError = QStringLiteral("DB lookup failed: %1").arg(e.message());
        return {};
    }

    // Register first so we can capture the family the OS gave us; we
    // don't want to commit a row whose family we couldn't determine.
    const int regId = QFontDatabase::addApplicationFontFromData(bytes);
    if (regId < 0) {
        m_lastError = QStringLiteral("QFontDatabase refused the font bytes");
        return {};
    }
    const QStringList families = QFontDatabase::applicationFontFamilies(regId);
    if (families.isEmpty()) {
        QFontDatabase::removeApplicationFont(regId);
        m_lastError = QStringLiteral("font registered with no usable families");
        return {};
    }
    const QString family = families.first();

    // Copy bytes into managed storage at <fontsDir>/<hash><ext>.
    const QString dst = QDir(db::DbPaths::fontsDir())
                            .filePath(hash + ext);
    if (!QFile::exists(dst)) {
        QFile out(dst);
        if (!out.open(QIODevice::WriteOnly)) {
            QFontDatabase::removeApplicationFont(regId);
            m_lastError = QStringLiteral("cannot write %1: %2").arg(dst, out.errorString());
            return {};
        }
        if (out.write(bytes) != bytes.size()) {
            out.remove();
            QFontDatabase::removeApplicationFont(regId);
            m_lastError = QStringLiteral("short write to %1").arg(dst);
            return {};
        }
    }

    const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
    try {
        auto& s = m_impl->insertFont;
        s.reset();
        s.bind(1, hash);
        s.bind(2, family);
        s.bind(3, dst);
        s.bind(4, nowMs);
        s.step();
    } catch (const db::Error& e) {
        // Roll back the file copy + registration so a failed import doesn't
        // leak resources.
        QFile::remove(dst);
        QFontDatabase::removeApplicationFont(regId);
        m_lastError = QStringLiteral("INSERT failed: %1").arg(e.message());
        return {};
    }

    UserFont f;
    f.id      = m_impl->conn.lastInsertRowId();
    f.hash    = hash;
    f.family  = family;
    f.path    = dst;
    f.addedAt = nowMs;
    m_impl->regIdByDbId.insert(f.id, regId);

    invalidateCache();
    qInfo().noquote() << "FontService: imported" << family << "(" << dst << ")";
    return f;
}

bool FontService::removeFont(qint64 id)
{
    m_lastError.clear();
    if (!m_impl || id <= 0) {
        m_lastError = QStringLiteral("invalid font id");
        return false;
    }

    // Look up the on-disk path BEFORE deleting the row — we need it to
    // clean up the file regardless of how the rest of this operation goes.
    QString path;
    try {
        auto& s = m_impl->selectById;
        s.reset();
        s.bind(1, id);
        if (!s.step()) {
            m_lastError = QStringLiteral("no font with id %1").arg(id);
            return false;
        }
        path = s.columnText(3);
        s.reset();   // close cursor before the DELETE write below
    } catch (const db::Error& e) {
        m_lastError = QStringLiteral("DB lookup failed: %1").arg(e.message());
        return false;
    }

    // Unregister from QFontDatabase if we have the regId for this session.
    // Without this the font would stay loaded for the rest of the process
    // — operator clicks "remove", reopens the font picker, still sees it.
    // The map is rebuilt by the constructor on every startup, so a regId
    // we don't know about here means we couldn't re-register that font on
    // this session's startup (it'll just be absent from the picker anyway).
    const auto it = m_impl->regIdByDbId.constFind(id);
    if (it != m_impl->regIdByDbId.constEnd()) {
        QFontDatabase::removeApplicationFont(it.value());
        m_impl->regIdByDbId.remove(id);
    }

    // Delete row first, then the file. If the DELETE fails we want the
    // file to still exist (consistency); if the DELETE succeeds and the
    // file remove fails (e.g. another process has it open), the row is
    // gone but the orphan file is harmless and a startup sweep could
    // pick it up later if we ever add one.
    try {
        auto& s = m_impl->deleteById;
        s.reset();
        s.bind(1, id);
        s.step();
    } catch (const db::Error& e) {
        m_lastError = QStringLiteral("DELETE failed: %1").arg(e.message());
        return false;
    }

    if (!path.isEmpty() && QFile::exists(path)) {
        QFile::remove(path);
    }

    invalidateCache();
    qInfo().noquote() << "FontService: removed font id" << id << "(" << path << ")";
    return true;
}

UserFont FontService::byHash(QString hash)
{
    if (!m_impl) return {};
    try {
        auto& s = m_impl->selectByHash;
        s.reset();
        s.bind(1, hash);
        UserFont f;
        if (s.step()) f = Impl::readRow(s);
        s.reset();   // release read txn (WAL snapshot pin)
        return f;
    } catch (const db::Error& e) {
        qWarning().noquote() << "FontService::byHash():" << e.message();
    }
    return {};
}

QString FontService::filePathForFamily(QString family)
{
    if (!m_impl) return {};
    try {
        auto& s = m_impl->selectByFamily;
        s.reset();
        s.bind(1, family);
        QString path;
        if (s.step()) path = s.columnText(3);
        s.reset();   // release read txn (WAL snapshot pin)
        return path;
    } catch (const db::Error& e) {
        qWarning().noquote() << "FontService::filePathForFamily():" << e.message();
    }
    return {};
}

QString FontService::lastError() const
{
    return m_lastError;
}

}  // namespace crater
