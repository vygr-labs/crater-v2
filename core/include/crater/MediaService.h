#pragma once

#include "crater/value/MediaItem.h"

#include <QList>
#include <QObject>
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
