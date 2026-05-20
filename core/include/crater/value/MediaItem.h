#pragma once

#include <QObject>
#include <QString>
#include <QtQmlIntegration>

namespace crater {

// A single image, video, or PDF the operator has imported. Backed by a row
// in the `media` table of app.sqlite (see V002__media.sql + V005__media_pdf.sql).
//
// `path` is always the *managed* absolute path inside AppDataLocation/media/
// — MediaService copies the source on import so subsequent renames/deletes
// of the original file don't break our reference (per ARCHITECTURE.md §5.1).
// `type` is one of "image" | "video" | "pdf"; classification happens at
// import time via magic-byte sniffing, not extension.
//
// `pageCount` is meaningful only for PDFs (set to QPdfDocument::pageCount()
// at import time). Images and videos carry the default 1.
struct MediaItem
{
    Q_GADGET
    QML_VALUE_TYPE(mediaItem)
    Q_PROPERTY(qint64  id         MEMBER id)
    Q_PROPERTY(QString path       MEMBER path)
    Q_PROPERTY(QString title      MEMBER title)
    Q_PROPERTY(QString type       MEMBER type)
    Q_PROPERTY(bool    isFavorite MEMBER isFavorite)
    Q_PROPERTY(qint64  addedAt    MEMBER addedAt)
    Q_PROPERTY(qint64  durationMs MEMBER durationMs)
    Q_PROPERTY(int     pageCount  MEMBER pageCount)

public:
    qint64  id         = 0;
    QString path;
    QString title;
    QString type;        // "image" | "video" | "pdf"
    bool    isFavorite = false;
    qint64  addedAt    = 0;   // unix epoch ms
    qint64  durationMs = 0;   // video clip length in ms; 0 for images / not yet probed
    int     pageCount  = 1;   // PDF page count; 1 for images/videos
};

}  // namespace crater
