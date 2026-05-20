#pragma once

#include "crater/value/MediaItem.h"

#include <QFuture>
#include <QImage>
#include <QList>
#include <QObject>
#include <QRectF>
#include <QSize>
#include <QString>
#include <QStringList>

#include <memory>

namespace crater {

// Media library service — owns the operator's imported images and videos.
//
// Storage: media table in app.sqlite (see V002__media.sql). Imported files
// are COPIED into AppDataLocation/media/ so subsequent renames/deletes of
// the source can't break our reference.
//
// Validation (per ARCHITECTURE.md §5.1):
//   • magic-byte sniff to classify image vs video (not extension)
//   • size cap (default 4 GB, rejected above)
//   • path normalization (QDir::cleanPath) and destination-dir confinement
//
// Threading: reads/writes run on the main thread (sync, <5 ms each per §3).
// Import does a file copy which can be slow for large videos, so importPaths()
// runs on a QtConcurrent worker thread; the imported() signal fires on the
// main thread after each successful add.
class MediaService : public QObject
{
    Q_OBJECT

    // QML binds `model: MediaService.allMedia` directly. Re-emitted on any
    // mutation (import / remove / toggleFavorite).
    Q_PROPERTY(QList<crater::MediaItem> allMedia READ allMedia NOTIFY allMediaChanged)

public:
    explicit MediaService(QObject* parent = nullptr);
    ~MediaService() override;

    QList<crater::MediaItem> allMedia();

    // Import one or more files (drag-drop or future file picker). Each path is
    // validated, classified, copied into AppDataLocation/media/, and registered.
    // Invalid files are skipped with a warning. Returns the number of items
    // successfully imported.
    //
    // Runs on a worker thread when there's anything to copy; the call returns
    // immediately. Listen on importFinished() if you need a completion hook.
    Q_INVOKABLE int importPaths(QStringList paths);

    Q_INVOKABLE void remove(qint64 id);
    Q_INVOKABLE void toggleFavorite(qint64 id);

    // Rename a row's display title. The managed file on disk is NOT renamed —
    // its filename is collision-engineered at import time and we use the id
    // (not the title) as the stable reference for thumbnails and theme nodes.
    Q_INVOKABLE void rename(qint64 id, QString newTitle);

    // Record probed video metadata. Called by the app-side VideoThumbnailer
    // after it extracts a first frame from the imported video. Images call
    // this with durationMs == 0 (no-op for them).
    Q_INVOKABLE void setVideoMeta(qint64 id, qint64 durationMs);

    // Look up a single media item by id. Returns an empty MediaItem (id == 0)
    // on miss. Used by container theme nodes that reference a background
    // image/video by id rather than carrying the path inline.
    Q_INVOKABLE crater::MediaItem byId(qint64 id);

    // Absolute path to the thumbnail directory used by the app-side
    // VideoThumbnailer. Owned here because MediaService owns the on-disk
    // layout under AppDataLocation/media/ — keeping the convention in one
    // place means a future move (e.g. cache-aware location) only touches
    // this file.
    Q_INVOKABLE QString thumbsDir() const;

    // ── PDF rendering ─────────────────────────────────────────────────────
    // Opens the underlying QPdfDocument for `mediaId` and returns its page
    // count. Sync because a metadata read in pdfium is sub-millisecond — well
    // under the 5 ms ARCHITECTURE.md §3 sync threshold. Returns 0 when the
    // id doesn't resolve to a PDF row, the file is missing, or the document
    // refuses to open (corrupt / encrypted with a password we don't have).
    //
    // This caches the most-recently-opened QPdfDocument per call site since
    // construction is the expensive bit — repeat queries for the same id
    // reuse the in-memory document.
    Q_INVOKABLE int pdfPageCount(qint64 mediaId);

    // Render a single PDF page (optionally cropped to a normalized sub-region)
    // into a QImage sized to `targetSize`. `cropRect` is in 0..1 coordinates
    // with origin top-left; pass {0,0,1,1} for full-page. A sub-crop renders
    // the full page upscaled by 1/crop-fraction and copies out the sub-rect,
    // so text inside the crop stays crisp (never digital-zoomed from a
    // pre-rendered bitmap). See renderPdfPageBlocking for why
    // QPdfDocumentRenderOptions::setScaledClipRect is deliberately not used.
    //
    // The underlying QPdfDocument is cached per worker thread, so repeat
    // renders of the same file (page changes, re-crops, the live + projection
    // passes) skip re-parsing it — see PdfDocumentCache in MediaService.cpp.
    //
    // Async per §3 — even a single-page render at 1920×1080 can hit 30–100 ms
    // on the target HW floor (Intel HD 4000). Caller obtains the result via
    // QFuture / QFutureWatcher; the PdfPageImageProvider in qt/app/ wraps this
    // for QML's image source machinery.
    QFuture<QImage> renderPdfPage(qint64 mediaId,
                                  int     pageIndex,
                                  QSize   targetSize,
                                  QRectF  cropRect = QRectF(0, 0, 1, 1));

    // Trigger pdfium's one-time global initialization off the main thread.
    // pdfium lazily loads its library and sets up its font subsystem on the
    // first QPdfDocument operation of the process — a multi-second cold
    // start otherwise paid on the operator's first PDF view. Call once at
    // startup. No-op when the library holds no PDF to warm with (in which
    // case there is nothing for the operator to view yet either).
    Q_INVOKABLE void prewarmPdf();

    // Maximum size of a single import in bytes. Configurable so tests / power
    // users can adjust; defaults to 4 GiB per §5.1.
    Q_PROPERTY(qint64 sizeCapBytes READ sizeCapBytes WRITE setSizeCapBytes NOTIFY sizeCapBytesChanged)
    qint64 sizeCapBytes() const { return m_sizeCapBytes; }
    void   setSizeCapBytes(qint64 v);

signals:
    void allMediaChanged();
    void sizeCapBytesChanged();
    void importFinished(int imported, int skipped);

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
    qint64 m_sizeCapBytes = qint64(4) * 1024 * 1024 * 1024;   // 4 GiB

    void invalidateCache();
};

}  // namespace crater
