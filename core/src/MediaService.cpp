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
#include <QPdfDocument>
#include <QPdfDocumentRenderOptions>
#include <QUrl>
#include <QtConcurrent>

#include <optional>

namespace crater {

namespace {

// Magic-byte sniffer. Returns "image", "video", "pdf", or empty string when
// the file's leading bytes don't match a supported container.
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

    // ── PDFs ─────────────────────────────────────────────────────────────
    // '%PDF-' followed by the version (e.g. '%PDF-1.7'). The header may be
    // preceded by up to 1024 bytes of comments per the PDF spec, but in
    // practice every PDF we'll see has the magic at offset 0. If we ever
    // need to support exotic emitters that put a UTF-8 BOM or comments
    // before the header, widen the scan window here.
    if (starts("%PDF-", 5))                              return QStringLiteral("pdf");

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

// Probe a PDF on disk and return its page count. Returns 0 when the document
// can't be opened (corrupt / encrypted). Used at import time so the row's
// page_count column is populated once, eliminating a per-render probe.
int probePdfPageCount(const QString& path)
{
    QPdfDocument doc;
    const auto err = doc.load(path);
    if (err != QPdfDocument::Error::None) return 0;
    return doc.pageCount();
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

// Result of a successful per-file copy on the worker thread, captured by the
// main-thread completion lambda to drive the INSERT. We keep INSERTs on the
// owning connection because SQLite WAL frames written via a sibling
// connection inside the same process are not reliably visible to the main
// connection's next read transaction — a fresh SELECT returns the pre-commit
// snapshot even after sqlite3_reset/step, which manifests as imports
// "disappearing" until the app restarts (and reopens connections that see
// the on-disk state from scratch).
struct PendingImport {
    QString dst;
    QString title;
    QString type;
    qint64  addedAt;
    int     pageCount;   // 1 for image/video; QPdfDocument::pageCount() for pdf
};

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
            "SELECT id, path, title, type, is_favorite, added_at, duration_ms, page_count "
            "FROM media ORDER BY added_at DESC")))
        , insertItem(conn.prepare(QStringLiteral(
            "INSERT INTO media (path, title, type, is_favorite, added_at, duration_ms, page_count) "
            "VALUES (?, ?, ?, 0, ?, 0, ?)")))
        , selectById(conn.prepare(QStringLiteral(
            "SELECT id, path, title, type, is_favorite, added_at, duration_ms, page_count "
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
        m.pageCount  = s.columnInt  (7);
        return m;
    }
};

// Render one PDF page on the calling thread. Constructs a fresh
// QPdfDocument — see renderPdfPage for why we don't cache: QPdfDocument is
// a QObject and a cache would hand one across threadpool threads, which is
// undefined behavior in Qt's object model. Returns a null QImage (and logs)
// on any failure so callers can fall back cleanly.
static QImage renderPdfPageBlocking(const QString& path,
                                    int            pageIndex,
                                    QSize          targetSize,
                                    QRectF         cropRect)
{
    if (path.isEmpty() || targetSize.isEmpty()) {
        qWarning().noquote() << "renderPdfPage: rejected — path=" << path
                             << "target=" << targetSize;
        return {};
    }

    QPdfDocument doc;
    const auto loadErr = doc.load(path);
    if (loadErr != QPdfDocument::Error::None) {
        qWarning().noquote() << "renderPdfPage: load failed for" << path
                             << "err=" << static_cast<int>(loadErr);
        return {};
    }

    const int pageCount = doc.pageCount();
    if (pageCount <= 0 || pageIndex < 0 || pageIndex >= pageCount) {
        qWarning().noquote() << "renderPdfPage: page" << pageIndex
                             << "out of range (count=" << pageCount << ")";
        return {};
    }

    // Normalize + clamp the crop. Empty/invalid → full page.
    QRectF clip = cropRect;
    if (!clip.isValid() || clip.isEmpty()) clip = QRectF(0, 0, 1, 1);
    clip = clip.intersected(QRectF(0, 0, 1, 1));
    if (clip.isEmpty()) clip = QRectF(0, 0, 1, 1);

    const bool fullPage = qFuzzyIsNull(clip.x())
                       && qFuzzyIsNull(clip.y())
                       && qFuzzyCompare(clip.width(),  1.0)
                       && qFuzzyCompare(clip.height(), 1.0);

    // QPdfDocument::render scales the page to *exactly* the size it's given —
    // it does not preserve aspect ratio. Handing it a 16:9 target for a
    // portrait page produces a horizontally squished raster. So we fit the
    // requested target to the page's true aspect first; the returned QImage
    // then carries correct proportions and every QML Image element that
    // shows it (all use PreserveAspectFit) displays it undistorted.
    QSizeF ptSize = doc.pagePointSize(pageIndex);
    if (ptSize.width() <= 0 || ptSize.height() <= 0) {
        ptSize = QSizeF(targetSize);
    }
    QSize renderSize = ptSize.scaled(QSizeF(targetSize), Qt::KeepAspectRatio).toSize();
    renderSize = renderSize.expandedTo(QSize(1, 1));

    QImage img;
    if (fullPage) {
        // Full page — render straight to the aspect-fitted size. No
        // scaledClipRect: an "identity" clip equal to the whole target
        // changes how render() interprets its size args, and a clean
        // two-arg render() removes that variable entirely.
        img = doc.render(pageIndex, renderSize);
    } else {
        // Sub-region — scale the page to renderSize (page aspect) then clip
        // to the pixel rect, so text inside the crop rasterizes at the
        // higher effective DPI rather than upscaling a pre-rendered bitmap.
        QPdfDocumentRenderOptions opts;
        const QRect clipPx(qRound(clip.x()      * renderSize.width()),
                           qRound(clip.y()      * renderSize.height()),
                           qRound(clip.width()  * renderSize.width()),
                           qRound(clip.height() * renderSize.height()));
        opts.setScaledClipRect(clipPx);
        img = doc.render(pageIndex, renderSize, opts);
    }

    qInfo().noquote() << "renderPdfPage: page=" << pageIndex
                      << "target=" << targetSize << "renderSize=" << renderSize
                      << "fullPage=" << fullPage
                      << "-> image=" << img.size() << "null=" << img.isNull();
    return img;
}

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
    qInfo().noquote() << "MediaService::invalidateCache (emitting allMediaChanged)";
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
    if (m_impl->cachedAll) {
        qInfo().noquote() << "MediaService::allMedia (cached) rows="
                          << m_impl->cachedAll->size();
        return *m_impl->cachedAll;
    }

    QList<MediaItem> out;
    try {
        auto& s = m_impl->selectAll;
        s.reset();
        while (s.step()) out.append(Impl::readRow(s));
    } catch (const db::Error& e) {
        qWarning().noquote() << "MediaService::allMedia():" << e.message();
    }
    qInfo().noquote() << "MediaService::allMedia (db read) rows=" << out.size();
    m_impl->cachedAll = out;
    return out;
}

int MediaService::importPaths(QStringList paths)
{
    if (!m_impl || paths.isEmpty()) return 0;

    // Capture state needed off-thread.
    const qint64  cap     = m_sizeCapBytes;
    const QString destDir = db::DbPaths::mediaDir();

    // The path-confinement check uses a canonical prefix so symlinks can't
    // escape the destination dir (§5.1: "verify the resulting path is within
    // the user's media directory before any write").
    const QString destDirCanonical = QFileInfo(destDir).canonicalFilePath();

    // The slow part (multi-GB file copy, magic-byte sniff) runs on a worker
    // so the UI doesn't freeze. The fast part (INSERT) runs back on the main
    // thread on the owning connection — see PendingImport above for why we
    // don't write from the worker's own sqlite3 handle.
    QtConcurrent::run([this, paths, cap, destDirCanonical]() {
        QList<PendingImport> pending;
        int skipped = 0;

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

            // PDF page-count probe runs after the copy on the worker thread —
            // we read the document we just dropped into managed storage. This
            // is cheap (single xref scan, sub-100 ms even on 200-page PDFs)
            // and removes the need for a separate post-import probe pass.
            // Images / videos default to 1; videos get duration_ms instead
            // (probed later by the app-side VideoThumbnailer).
            int pageCount = 1;
            if (type == QStringLiteral("pdf")) {
                pageCount = probePdfPageCount(dstClean);
                if (pageCount <= 0) {
                    qWarning().noquote() << "MediaService: skipping" << src
                                         << "— PDF probe returned 0 pages "
                                            "(corrupt or encrypted)";
                    QFile::remove(dstClean);
                    ++skipped;
                    continue;
                }
            }

            pending.append(PendingImport{
                dstClean,
                info.completeBaseName(),
                type,
                QDateTime::currentMSecsSinceEpoch(),
                pageCount
            });
        }

        qInfo().noquote() << "MediaService::importPaths worker done — pending="
                          << pending.size() << "skipped=" << skipped
                          << "(posting main-thread INSERTs)";

        // INSERT on the owning connection on the main thread. Microsecond-
        // scale work even for batched imports; well under the 16 ms frame
        // budget for a single drag-drop of dozens of files.
        QMetaObject::invokeMethod(this,
            [this, pending = std::move(pending), skipped]() mutable {
            qInfo().noquote() << "MediaService::importPaths main-thread INSERTs starting ("
                              << pending.size() << "rows)";
            int imported = 0;
            int insertFails = 0;
            for (const PendingImport& p : pending) {
                try {
                    auto& s = m_impl->insertItem;
                    s.reset();
                    s.bind(1, p.dst);
                    s.bind(2, p.title);
                    s.bind(3, p.type);
                    s.bind(4, p.addedAt);
                    s.bind(5, qint64(p.pageCount));
                    s.step();
                    ++imported;
                } catch (const db::Error& e) {
                    qWarning().noquote() << "MediaService: insert failed for" << p.dst
                                         << "—" << e.message();
                    // Roll back the worker's file copy so we don't leak.
                    QFile::remove(p.dst);
                    ++insertFails;
                }
            }
            if (imported > 0) invalidateCache();
            emit importFinished(imported, skipped + insertFails);
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

// ── PDF API ─────────────────────────────────────────────────────────────

int MediaService::pdfPageCount(qint64 mediaId)
{
    const MediaItem item = byId(mediaId);
    if (item.id == 0 || item.type != QStringLiteral("pdf")) return 0;
    // The row carries the count probed at import time — no need to reopen
    // the document for a metadata-only query. Falls back to a fresh probe
    // only if the column was 0 (legacy rows before V005, or an import that
    // failed mid-probe).
    if (item.pageCount > 0) return item.pageCount;
    return probePdfPageCount(item.path);
}

QFuture<QImage> MediaService::renderPdfPage(qint64  mediaId,
                                            int     pageIndex,
                                            QSize   targetSize,
                                            QRectF  cropRect)
{
    // Capture the path off the DB row up-front (sync, sub-ms). The render
    // body then runs entirely on the threadpool without touching the
    // service's sqlite3 handle — keeps the connection mainthread-only per
    // the ARCHITECTURE.md §3 threading rule. A fresh QPdfDocument is built
    // inside the lambda (see renderPdfPageBlocking) so a document is never
    // shared across threadpool threads.
    const MediaItem item = byId(mediaId);
    const QString   path  = (item.type == QStringLiteral("pdf")) ? item.path
                                                                 : QString{};
    if (path.isEmpty()) {
        qWarning().noquote() << "renderPdfPage: id" << mediaId
                             << "is not a PDF row (type=" << item.type << ")";
    }

    return QtConcurrent::run([path, pageIndex, targetSize, cropRect]() -> QImage {
        return renderPdfPageBlocking(path, pageIndex, targetSize, cropRect);
    });
}

}  // namespace crater
