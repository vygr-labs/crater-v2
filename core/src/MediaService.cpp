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
#include <QHash>
#include <QPdfDocument>
#include <QSet>
#include <QUrl>
#include <QtConcurrent>

#include <memory>
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

// Per-file validate + copy + probe. Shared by the async importPaths worker
// and the sync importPathSync. On success returns a PendingImport ready to
// be INSERTed by the DB-owning thread. On failure returns nullopt and (if
// `outReason` is non-null) writes a one-line explanation.
//
// Pure function — no DB access — so callers can run it from any thread.
// Side effect: a successful return has already copied the file into
// `destDirCanonical`. Callers must roll that copy back on subsequent
// INSERT failure (existing behavior in importPaths' main-thread phase).
std::optional<PendingImport> tryStageOneFile(const QString& raw,
                                             qint64         sizeCap,
                                             const QString& destDirCanonical,
                                             QString*       outReason = nullptr)
{
    const auto fail = [&](QString why) -> std::optional<PendingImport> {
        if (outReason) *outReason = std::move(why);
        return std::nullopt;
    };

    const QString src = normalizeInputPath(raw);
    if (src.isEmpty())
        return fail(QStringLiteral("unreadable path: %1").arg(raw));

    const QFileInfo info(src);
    if (info.size() > sizeCap)
        return fail(QStringLiteral("exceeds size cap (%1 > %2)").arg(info.size()).arg(sizeCap));

    const QString type = sniffMediaType(src);
    if (type.isEmpty())
        return fail(QStringLiteral("unrecognized media type (magic-byte sniff failed)"));

    const QString dst = pickDestinationName(QDir(destDirCanonical).absolutePath(),
                                            info.fileName());
    const QString dstClean = QDir::cleanPath(dst);
    if (!dstClean.startsWith(destDirCanonical + QStringLiteral("/"))
        && !dstClean.startsWith(destDirCanonical + QStringLiteral("\\"))) {
        return fail(QStringLiteral("destination escapes media dir: %1").arg(dstClean));
    }

    if (!QFile::copy(src, dstClean))
        return fail(QStringLiteral("copy failed: %1 -> %2").arg(src, dstClean));

    int pageCount = 1;
    if (type == QStringLiteral("pdf")) {
        pageCount = probePdfPageCount(dstClean);
        if (pageCount <= 0) {
            QFile::remove(dstClean);
            return fail(QStringLiteral("PDF probe returned 0 pages (corrupt or encrypted)"));
        }
    }

    return PendingImport{
        dstClean,
        info.completeBaseName(),
        type,
        QDateTime::currentMSecsSinceEpoch(),
        pageCount
    };
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
        : conn(path, db::OpenMode::ReadWriteCreate, QStringLiteral("MediaService"))
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

// Per-thread cache of opened QPdfDocuments, keyed by file path.
//
// renderPdfPageBlocking runs on QThreadPool workers. Before this cache it
// built a fresh QPdfDocument — and therefore re-parsed the whole file — on
// every render: every page change, every re-crop, and the separate live +
// projection passes a Go Live fires. That reparse, not the rasterization,
// dominated PDF latency.
//
// The cache is thread_local, so each worker owns its own QPdfDocument
// instances and one is never touched from a thread other than the one
// that created it — QPdfDocument is a QObject and cross-thread use is
// undefined behavior (ARCHITECTURE.md §3). QThreadPool reuses a small
// fixed set of threads, so the cache warms within the first few renders
// and stays warm for the rest of the session.
//
// An entry records the file's size + mtime; an in-place replacement of the
// file invalidates it. Crater is live-projection software — showing a
// stale page to the audience is a real failure, and the guard is one stat
// call. Bounded to kPdfCacheCap most-recently-used documents so browsing a
// large library (every media tile renders page 0) can't grow it unbounded.
class PdfDocumentCache
{
public:
    // Returns a loaded document for `path`, or nullptr if it can't be
    // opened. Owned by the cache; use synchronously, never retain.
    QPdfDocument* acquire(const QString& path)
    {
        const QFileInfo fi(path);
        const qint64 size  = fi.size();
        const qint64 mtime = fi.lastModified().toMSecsSinceEpoch();

        if (auto it = m_entries.find(path); it != m_entries.end()) {
            if (it->size == size && it->mtime == mtime) {
                touch(path);
                return it->doc.get();
            }
            m_order.removeAll(path);          // file changed on disk — drop
            m_entries.erase(it);
        }

        auto doc = std::make_shared<QPdfDocument>();
        if (doc->load(path) != QPdfDocument::Error::None) {
            return nullptr;
        }
        QPdfDocument* raw = doc.get();
        m_entries.insert(path, Entry{ doc, size, mtime });
        m_order.append(path);
        while (m_order.size() > kPdfCacheCap) {
            m_entries.remove(m_order.takeFirst());
        }
        return raw;
    }

private:
    // shared_ptr (not unique_ptr) only because QHash's value type must be
    // copyable; ownership is still effectively unique to the cache.
    struct Entry {
        std::shared_ptr<QPdfDocument> doc;
        qint64 size  = 0;
        qint64 mtime = 0;
    };

    void touch(const QString& path)
    {
        m_order.removeAll(path);
        m_order.append(path);                 // most-recently-used at the back
    }

    static constexpr int  kPdfCacheCap = 8;
    QHash<QString, Entry>  m_entries;
    QStringList            m_order;           // LRU order; front = oldest
};

// Render one PDF page on the calling thread. Returns a null QImage (and
// logs) on any failure so callers can fall back cleanly.
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

    // Per-thread document cache — see PdfDocumentCache. The first render of
    // a given PDF on a thread parses the file; later renders reuse it.
    thread_local PdfDocumentCache docCache;
    QPdfDocument* doc = docCache.acquire(path);
    if (!doc) {
        qWarning().noquote() << "renderPdfPage: load failed for" << path;
        return {};
    }

    const int pageCount = doc->pageCount();
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
    QSizeF ptSize = doc->pagePointSize(pageIndex);
    if (ptSize.width() <= 0 || ptSize.height() <= 0) {
        ptSize = QSizeF(targetSize);
    }
    QSize renderSize = ptSize.scaled(QSizeF(targetSize), Qt::KeepAspectRatio).toSize();
    renderSize = renderSize.expandedTo(QSize(1, 1));

    // Crop strategy: render the FULL page, then QImage::copy the sub-rect.
    // We deliberately do NOT use QPdfDocumentRenderOptions::setScaledClipRect
    // — it clips a page scaled to scaledSize(), and without a matching
    // scaledSize() pdfium returns an empty image (this was the blank-on-
    // crop bug). render(page, size) is the only PDF render call that's
    // proven to work here, so every path goes through it.
    //
    // To keep cropped text crisp: a sub-crop renders the full page UPSCALED
    // by 1/crop-fraction, so the copied region still lands near the caller's
    // requested resolution instead of being a low-res slice. Capped at 6×
    // so a tiny crop can't request an enormous raster.
    qreal scaleUp = 1.0;
    if (!fullPage) {
        const qreal minDim = qMax(qreal(0.04),
                                  qMin(clip.width(), clip.height()));
        scaleUp = qBound(1.0, 1.0 / minDim, 6.0);
    }
    QSize fullSize(qRound(renderSize.width()  * scaleUp),
                   qRound(renderSize.height() * scaleUp));
    fullSize = fullSize.expandedTo(QSize(1, 1));

    const QImage full = doc->render(pageIndex, fullSize);

    QImage img;
    QRect clipPx;
    if (fullPage || full.isNull()) {
        img = full;
    } else {
        clipPx = QRect(qRound(clip.x()      * full.width()),
                       qRound(clip.y()      * full.height()),
                       qRound(clip.width()  * full.width()),
                       qRound(clip.height() * full.height()));
        clipPx = clipPx.intersected(QRect(QPoint(0, 0), full.size()));
        img = clipPx.isEmpty() ? full : full.copy(clipPx);
    }

    qInfo().noquote() << "[pdf] render — page=" << pageIndex
                      << "target=" << targetSize << "renderSize=" << renderSize
                      << "fullPage=" << fullPage << "clip=" << clip
                      << "scaleUp=" << scaleUp << "fullSize=" << fullSize
                      << "fullRender=" << full.size() << "fullNull=" << full.isNull()
                      << "clipPx=" << clipPx
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
            QString reason;
            auto staged = tryStageOneFile(raw, cap, destDirCanonical, &reason);
            if (!staged) {
                qWarning().noquote() << "MediaService: skipping" << raw << "—" << reason;
                ++skipped;
                continue;
            }
            pending.append(*staged);
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

qint64 MediaService::importPathSync(QString path)
{
    m_lastImportError.clear();
    if (!m_impl) {
        m_lastImportError = QStringLiteral("MediaService not initialized");
        return 0;
    }

    const QString destDirCanonical =
        QFileInfo(db::DbPaths::mediaDir()).canonicalFilePath();

    QString reason;
    auto staged = tryStageOneFile(path, m_sizeCapBytes, destDirCanonical, &reason);
    if (!staged) {
        m_lastImportError = reason;
        return 0;
    }

    // INSERT inline on the owning connection — this method runs on the main
    // thread (the bundle importer's caller), so we hit the same connection
    // that owns this service's other writes. No QMetaObject::invokeMethod
    // round-trip needed.
    qint64 newId = 0;
    try {
        auto& s = m_impl->insertItem;
        s.reset();
        s.bind(1, staged->dst);
        s.bind(2, staged->title);
        s.bind(3, staged->type);
        s.bind(4, staged->addedAt);
        s.bind(5, qint64(staged->pageCount));
        s.step();
        newId = m_impl->conn.lastInsertRowId();
    } catch (const db::Error& e) {
        // Roll back the staged file copy so we don't leak.
        QFile::remove(staged->dst);
        m_lastImportError = QStringLiteral("INSERT failed: %1").arg(e.message());
        return 0;
    }

    invalidateCache();
    return newId;
}

QString MediaService::lastImportError() const
{
    return m_lastImportError;
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

void MediaService::sweepOrphans()
{
    if (!m_impl) return;
    try {
        // Snapshot every (id, path) the table still references. selectAll
        // is the already-prepared statement; reusing it avoids spinning
        // up an ad-hoc Statement for a one-shot pass. Paths are stored
        // post-cleanPath at import time (see line ~96), so cleanPath
        // again on the disk-walk side gives a like-for-like comparison
        // across OS path-separator quirks.
        QSet<QString> referenced;
        QSet<qint64>  referencedIds;
        {
            auto& sel = m_impl->selectAll;
            sel.reset();
            while (sel.step()) {
                referencedIds.insert(sel.columnInt64(0));
                referenced.insert(QDir::cleanPath(sel.columnText(1)));
            }
        }

        const QDir mediaDir(db::DbPaths::mediaDir());
        if (!mediaDir.exists()) return;  // first-run: nothing to sweep yet

        int removed = 0;

        // Top-level managed media. Layout is intentionally flat — every
        // imported file lives directly under mediaDir/, with thumbs/ the
        // only sub-dir we own. Files NOT in the referenced set are
        // orphans whose DB row was deleted but whose file QFile::remove
        // couldn't clear at the time (typically a Windows transient
        // file lock).
        const auto files = mediaDir.entryInfoList(
            QDir::Files | QDir::NoDotAndDotDot);
        for (const auto& fi : files) {
            const QString cleaned = QDir::cleanPath(fi.absoluteFilePath());
            if (referenced.contains(cleaned)) continue;
            if (QFile::remove(fi.absoluteFilePath())) {
                ++removed;
                qInfo().noquote() << "MediaService::sweepOrphans: removed orphan"
                                  << fi.fileName();
            } else {
                qWarning().noquote() << "MediaService::sweepOrphans: could not remove"
                                     << fi.fileName();
            }
        }

        // Thumbs: <mediaDir>/thumbs/<id>.jpg. An orphan thumb is any
        // .jpg whose stem doesn't parse as a referenced media id —
        // either the row was deleted (typical) or the file is stray
        // (filename never came from VideoThumbnailer's naming, also a
        // candidate for sweeping).
        const QDir thumbs(mediaDir.filePath(QStringLiteral("thumbs")));
        if (thumbs.exists()) {
            const auto thumbFiles = thumbs.entryInfoList(
                QStringList{QStringLiteral("*.jpg")},
                QDir::Files | QDir::NoDotAndDotDot);
            for (const auto& fi : thumbFiles) {
                bool ok = false;
                const qint64 id = fi.completeBaseName().toLongLong(&ok);
                if (ok && referencedIds.contains(id)) continue;
                if (QFile::remove(fi.absoluteFilePath())) {
                    ++removed;
                    qInfo().noquote() << "MediaService::sweepOrphans: removed orphan thumb"
                                      << fi.fileName();
                }
            }
        }

        if (removed > 0) {
            qInfo().noquote() << "MediaService::sweepOrphans: reclaimed"
                              << removed << "orphan file(s)";
        }
    } catch (const db::Error& e) {
        qWarning().noquote() << "MediaService::sweepOrphans():" << e.message();
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
    // the ARCHITECTURE.md §3 threading rule. renderPdfPageBlocking keeps a
    // thread_local QPdfDocument cache, so a document is reused across
    // renders on the same worker but never shared between threads.
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

void MediaService::prewarmPdf()
{
    // Find any PDF row and render its first page on a worker thread. The
    // point is the side effect: the first QPdfDocument operation of the
    // process triggers pdfium's one-time global init (library load + font
    // subsystem) — several seconds of cold-start otherwise paid on the
    // operator's first real PDF view. Doing it here moves that cost to
    // launch, off the main thread. As a bonus the worker's thread_local
    // cache keeps this document warm.
    qint64 pdfId = 0;
    for (const MediaItem& m : allMedia()) {
        if (m.type == QStringLiteral("pdf")) { pdfId = m.id; break; }
    }
    if (pdfId <= 0) {
        qInfo() << "MediaService: no PDF in library — skipping pdfium prewarm";
        return;
    }

    qInfo().noquote() << "MediaService: prewarming pdfium via media id" << pdfId;
    // Fire-and-forget. The QFuture is intentionally discarded — a
    // QtConcurrent::run task is queued the instant renderPdfPage() returns
    // and runs to completion whether or not the handle is retained. The
    // small target keeps the warm-up render cheap; the pixels are dropped.
    renderPdfPage(pdfId, 0, QSize(256, 256), QRectF(0, 0, 1, 1));
}

}  // namespace crater
