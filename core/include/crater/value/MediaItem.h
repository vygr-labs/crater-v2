#pragma once

#include <QObject>
#include <QString>
#include <QtQmlIntegration>

namespace crater {

// A single image or video the operator has imported. Backed by a row in the
// `media` table of app.sqlite (see V002__media.sql).
//
// `path` is always the *managed* absolute path inside AppDataLocation/media/
// — MediaService copies the source on import so subsequent renames/deletes
// of the original file don't break our reference (per ARCHITECTURE.md §5.1).
// `type` is one of "image" | "video"; that classification happens at import
// time via magic-byte sniffing, not extension.
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

public:
    qint64  id         = 0;
    QString path;
    QString title;
    QString type;        // "image" | "video"
    bool    isFavorite = false;
    qint64  addedAt    = 0;   // unix epoch ms
    qint64  durationMs = 0;   // video clip length in ms; 0 for images / not yet probed
};

}  // namespace crater
