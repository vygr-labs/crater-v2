#include "crater/MediaService.h"

#include "db/Connection.h"
#include "db/DbPaths.h"
#include "db/Error.h"
#include "db/Statement.h"
#include "db/Transaction.h"

#include <QByteArray>
#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QUrl>
#include <QtConcurrent>

#include <optional>

namespace crater {

namespace {

// Magic-byte sniffer. Returns "image", "video", or empty string when the
// file's leading bytes don't match a supported container.
//
// We read a small prefix from the file rather than trusting the extension —
// per ARCHITECTURE.md §5.1 ("validate at the boundary: magic bytes").
QString sniffMediaType(const QString& path)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return {};
    const QByteArray head = f.read(32);
    if (head.size() < 4) return {};

    const auto starts = [&](const char* sig, int len) {
        return head.size() >= len && std::memcmp(head.constData(), sig, len) == 0;
    };
    const auto matchAt = [&](int off, const char* sig, int len) {
        return head.size() >= off + len
            && std::memcmp(head.constData() + off, sig, len) == 0;
    };

    // ── Images ───────────────────────────────────────────────────────────
    if (starts("\x89PNG\r\n\x1a\n", 8))                  return QStringLiteral("image");
    if (starts("\xff\xd8\xff", 3))                       return QStringLiteral("image");   // JPEG
    if (starts("GIF87a", 6) || starts("GIF89a", 6))      return QStringLiteral("image");
    if (starts("BM", 2))                                 return QStringLiteral("image");   // BMP
    if (starts("RIFF", 4) && matchAt(8, "WEBP", 4))      return QStringLiteral("image");

    // ── Videos ───────────────────────────────────────────────────────────
    if (matchAt(4, "ftyp", 4))                           return QStringLiteral("video");   // mp4 / mov / m4v
    if (starts("\x1a\x45\xdf\xa3", 4))                   return QStringLiteral("video");   // WebM / Matroska (EBML)
    if (starts("RIFF", 4) && matchAt(8, "AVI ", 4))      return QStringLiteral("video");   // AVI
    if (starts("\x00\x00\x01\xba", 4))                   return QStringLiteral("video");   // MPEG-PS
    if (starts("\x00\x00\x01\xb3", 4))                   return QStringLiteral("video");   // MPEG-1/2
    if (starts("OggS", 4))                               return QStringLiteral("video");   // Ogg (may be audio; treat as video for picker)
    if (starts("FLV\x01", 4))                            return QStringLiteral("video");

    return {};
}

// Normalize an input path. Returns a clean absolute filesystem path, or an
// empty string when the input is malformed or refers to a non-file.
// Accepts both plain paths and file:// URLs (drag-drop yields URLs).
QString normalizeInputPath(const QString& raw)
{
    QString s = raw;
    if (s.startsWith(QStringLiteral("file:"))) {
        const QUrl url(s);
        if (!url.isLocalFile()) return {};
        s = url.toLocalFile();
    }
    s = QDir::cleanPath(s);
    if (s.isEmpty()) return {};
    QFileInfo info(s);
    if (!info.exists() || !info.isFile()) return {};
    return info.absoluteFilePath();
}

// Build a destination filename under `mediaDir` that doesn't collide with
// an existing file. We keep the source basename and append `-N` before the
// extension on collision.
QString pickDestinationName(const QString& mediaDir, const QString& srcBasename)
{
    QFileInfo src(srcBasename);
    const QString stem = src.completeBaseName();   // before last .
    const QString ext  = src.suffix();             // after  last .

    QDir dir(mediaDir);
    QString candidate = srcBasename;
    int n = 1;
    while (dir.exists(candidate)) {
        candidate = ext.isEmpty()
            ? QStringLiteral("%1-%2").arg(stem).arg(n)
            : QStringLiteral("%1-%2.%3").arg(stem).arg(n).arg(ext);
        ++n;
    }
    return dir.absoluteFilePath(candidate);
}

}  // namespace

struct MediaService::Impl
{
    db::Connection conn;

    db::Statement selectAll;
    db::Statement insertItem;
    db::Statement selectById;
    db::Statement deleteItem;
    db::Statement toggleFav;
    db::Statement renameItem;
    db::Statement setMeta;

    // Cached allMedia() — invalidated on every mutation.
    std::optional<QList<MediaItem>> cachedAll;

    explicit Impl(const QString& path)
        : conn(path)
        , selectAll(conn.prepare(QStringLiteral(
            "SELECT id, path, title, type, is_favorite, added_at, duration_ms "
            "FROM media ORDER BY added_at DESC")))
        , insertItem(conn.prepare(QStringLiteral(
            "INSERT INTO media (path, title, type, is_favorite, added_at, duration_ms) "
            "VALUES (?, ?, ?, 0, ?, 0)")))
        , selectById(conn.prepare(QStringLiteral(
            "SELECT id, path, title, type, is_favorite, added_at, duration_ms "
            "FROM media WHERE id = ?")))
        , deleteItem(conn.prepare(QStringLiteral(
            "DELETE FROM media WHERE id = ?")))
        , toggleFav(conn.prepare(QStringLiteral(
            "UPDATE media SET is_favorite = NOT is_favorite WHERE id = ?")))
        , renameItem(conn.prepare(QStringLiteral(
            "UPDATE media SET title = ? WHERE id = ?")))
        , setMeta(conn.prepare(QStringLiteral(
            "UPDATE media SET duration_ms = ? WHERE id = ?")))
    {}

    static MediaItem readRow(db::Statement& s)
    {
        MediaItem m;
        m.id         = s.columnInt64(0);
        m.path       = s.columnText (1);
        m.title      = s.columnText (2);
        m.type       = s.columnText (3);
        m.isFavorite = s.columnInt  (4) != 0;
        m.addedAt    = s.columnInt64(5);
        m.durationMs = s.columnInt64(6);
        return m;
    }
};

MediaService::MediaService(QObject* parent)
    : QObject(parent)
{
    try {
        m_impl = std::make_unique<Impl>(db::DbPaths::appDbPath());
    } catch (const db::Error& e) {
        qCritical().noquote() << "MediaService: failed to open DB —" << e.message();
    }
}

MediaService::~MediaService() = default;

void MediaService::invalidateCache()
{
    if (m_impl) m_impl->cachedAll.reset();
    emit allMediaChanged();
}

void MediaService::setSizeCapBytes(qint64 v)
{
    if (v < 0 || v == m_sizeCapBytes) return;
    m_sizeCapBytes = v;
    emit sizeCapBytesChanged();
}

QList<MediaItem> MediaService::allMedia()
{
    if (!m_impl) return {};
    if (m_impl->cachedAll) return *m_impl->cachedAll;

    QList<MediaItem> out;
    try {
        auto& s = m_impl->selectAll;
        s.reset();
        while (s.step()) out.append(Impl::readRow(s));
    } catch (const db::Error& e) {
        qWarning().noquote() << "MediaService::allMedia():" << e.message();
    }
    m_impl->cachedAll = out;
    return out;
}

int MediaService::importPaths(QStringList paths)
{
    if (!m_impl || paths.isEmpty()) return 0;

    // Capture state needed off-thread.
    const qint64 cap = m_sizeCapBytes;
    const QString dbPath  = db::DbPaths::appDbPath();
    const QString destDir = db::DbPaths::mediaDir();

    // The path-confinement check uses a canonical prefix so symlinks can't
    // escape the destination dir (§5.1: "verify the resulting path is within
    // the user's media directory before any write").
    const QString destDirCanonical = QFileInfo(destDir).canonicalFilePath();

    // Run validation + copy + insert on a worker so a multi-GB video import
    // doesn't freeze the operator console. We open a *separate* connection on
    // the worker thread — sqlite3 connections aren't safe to share (§3).
    QtConcurrent::run([this, paths, cap, dbPath, destDirCanonical]() {
        int imported = 0;
        int skipped  = 0;

        std::unique_ptr<db::Connection>           workerConn;
        std::optional<db::Statement>              workerInsert;
        try {
            workerConn = std::make_unique<db::Connection>(dbPath);
            workerInsert.emplace(workerConn->prepare(QStringLiteral(
                "INSERT INTO media (path, title, type, is_favorite, added_at, duration_ms) "
                "VALUES (?, ?, ?, 0, ?, 0)")));
        } catch (const db::Error& e) {
            qWarning().noquote() << "MediaService::importPaths(): worker DB open failed:"
                                 << e.message();
            QMetaObject::invokeMethod(this, "importFinished", Qt::QueuedConnection,
                Q_ARG(int, 0), Q_ARG(int, paths.size()));
            return;
        }

        for (const QString& raw : paths) {
            const QString src = normalizeInputPath(raw);
            if (src.isEmpty()) {
                qWarning().noquote() << "MediaService: skipping unreadable path:" << raw;
                ++skipped;
                continue;
            }

            const QFileInfo info(src);
            if (info.size() > cap) {
                qWarning().noquote() << "MediaService: skipping" << src
                                     << "— exceeds size cap (" << info.size()
                                     << ">" << cap << ")";
                ++skipped;
                continue;
            }

            const QString type = sniffMediaType(src);
            if (type.isEmpty()) {
                qWarning().noquote() << "MediaService: skipping" << src
                                     << "— unrecognized media type (magic-byte sniff failed)";
                ++skipped;
                continue;
            }

            // Pick a destination filename inside mediaDir() and confirm it
            // canonically resolves inside that directory.
            const QString dst = pickDestinationName(QDir(destDirCanonical).absolutePath(),
                                                    info.fileName());
            const QString dstClean = QDir::cleanPath(dst);
            if (!dstClean.startsWith(destDirCanonical + QStringLiteral("/"))
                && !dstClean.startsWith(destDirCanonical + QStringLiteral("\\"))) {
                qWarning().noquote() << "MediaService: refused destination outside media dir:" << dstClean;
                ++skipped;
                continue;
            }

            if (!QFile::copy(src, dstClean)) {
                qWarning().noquote() << "MediaService: copy failed" << src << "->" << dstClean;
                ++skipped;
                continue;
            }

            try {
                auto& stmt = *workerInsert;
                stmt.reset();
                stmt.bind(1, dstClean);
                stmt.bind(2, info.completeBaseName());
                stmt.bind(3, type);
                stmt.bind(4, QDateTime::currentMSecsSinceEpoch());
                stmt.step();
                ++imported;
            } catch (const db::Error& e) {
                qWarning().noquote() << "MediaService: insert failed for" << dstClean
                                     << "—" << e.message();
                // Roll back the file copy so we don't leak a duplicate.
                QFile::remove(dstClean);
                ++skipped;
            }
        }

        // Hop back to the main thread to invalidate the cache + fire signals.
        QMetaObject::invokeMethod(this, [this, imported, skipped]() {
            if (imported > 0) invalidateCache();
            emit importFinished(imported, skipped);
        }, Qt::QueuedConnection);
    });

    return paths.size();   // queued count; caller can listen to importFinished
}

void MediaService::remove(qint64 id)
{
    if (!m_impl) return;
    try {
        // Capture the path first so we can delete the managed file.
        QString path;
        {
            auto& sel = m_impl->selectById;
            sel.reset();
            sel.bind(1, id);
            if (sel.step()) path = sel.columnText(1);
        }

        db::Transaction tx(m_impl->conn);
        auto& del = m_impl->deleteItem;
        del.reset();
        del.bind(1, id);
        del.step();
        tx.commit();

        if (!path.isEmpty()) {
            // Best-effort — the row is already gone; failing to remove the
            // file just leaves an orphan on disk for a future GC sweep.
            QFile::remove(path);
        }

        // Best-effort orphan-thumb sweep. VideoThumbnailer writes thumbs to
        // <mediaDir>/thumbs/<id>.jpg; the file may not exist (image media
        // skips thumbnail generation, and the videothumbnailer is async so
        // a freshly-imported video could be deleted before its thumb landed).
        const QString thumb = QDir(db::DbPaths::mediaDir())
                                  .filePath(QStringLiteral("thumbs/%1.jpg").arg(id));
        if (QFile::exists(thumb)) QFile::remove(thumb);

        invalidateCache();
    } catch (const db::Error& e) {
        qWarning().noquote() << "MediaService::remove():" << e.message();
    }
}

void MediaService::rename(qint64 id, QString newTitle)
{
    if (!m_impl || id <= 0) return;
    const QString trimmed = newTitle.trimmed();
    if (trimmed.isEmpty()) return;   // refuse empty titles
    try {
        auto& s = m_impl->renameItem;
        s.reset();
        s.bind(1, trimmed);
        s.bind(2, id);
        s.step();
        invalidateCache();
    } catch (const db::Error& e) {
        qWarning().noquote() << "MediaService::rename():" << e.message();
    }
}

void MediaService::setVideoMeta(qint64 id, qint64 durationMs)
{
    if (!m_impl || id <= 0) return;
    try {
        auto& s = m_impl->setMeta;
        s.reset();
        s.bind(1, durationMs);
        s.bind(2, id);
        s.step();
        invalidateCache();
    } catch (const db::Error& e) {
        qWarning().noquote() << "MediaService::setVideoMeta():" << e.message();
    }
}

void MediaService::toggleFavorite(qint64 id)
{
    if (!m_impl) return;
    try {
        auto& s = m_impl->toggleFav;
        s.reset();
        s.bind(1, id);
        s.step();
        invalidateCache();
    } catch (const db::Error& e) {
        qWarning().noquote() << "MediaService::toggleFavorite():" << e.message();
    }
}

QString MediaService::thumbsDir() const
{
    // <mediaDir>/thumbs/ — created lazily by VideoThumbnailer the first time
    // it writes a frame. Returning the path even when the directory doesn't
    // exist yet keeps callers from having to special-case startup.
    return QDir(db::DbPaths::mediaDir()).filePath(QStringLiteral("thumbs"));
}

MediaItem MediaService::byId(qint64 id)
{
    MediaItem m;
    if (!m_impl || id <= 0) return m;
    try {
        auto& s = m_impl->selectById;
        s.reset();
        s.bind(1, id);
        if (s.step()) m = Impl::readRow(s);
    } catch (const db::Error& e) {
        qWarning().noquote() << "MediaService::byId():" << e.message();
    }
    return m;
}

}  // namespace crater
