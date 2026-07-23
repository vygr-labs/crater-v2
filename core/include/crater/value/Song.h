#pragma once

#include "crater/value/SongSection.h"

#include <QList>
#include <QObject>
#include <QString>
#include <QtQmlIntegration>

namespace crater {

// A song with metadata + sections. For list-view rendering, `sections` is
// typically empty (SongService::allSongs returns metadata-only rows). The
// full song (with sections) is fetched on demand via fetchSong(id).
struct Song
{
    Q_GADGET
    QML_VALUE_TYPE(song)
    Q_PROPERTY(qint64                 id          MEMBER id)
    Q_PROPERTY(QString                title       MEMBER title)
    Q_PROPERTY(QString                author      MEMBER author)
    Q_PROPERTY(QString                copyright   MEMBER copyright)
    Q_PROPERTY(QString                ccli        MEMBER ccli)
    Q_PROPERTY(qint64                 themeId     MEMBER themeId)
    Q_PROPERTY(bool                   isFavorite  MEMBER isFavorite)
    // Unix epoch milliseconds. Used by SongsTab sort modes (recent / oldest /
    // newest) — empty Song defaults to 0, which sorts as the oldest possible.
    Q_PROPERTY(qint64                 createdAt   MEMBER createdAt)
    Q_PROPERTY(qint64                 updatedAt   MEMBER updatedAt)
    Q_PROPERTY(QList<crater::SongSection> sections MEMBER sections)
    // Search-only: a short excerpt of the lyric line that matched the query,
    // with word-boundary ellipses. Empty for non-search Songs and for hits
    // whose match fell in the title/author rather than the lyrics.
    Q_PROPERTY(QString                snippet     MEMBER snippet)

public:
    qint64                 id         = 0;
    QString                title;
    QString                author;
    QString                copyright;
    QString                ccli;
    qint64                 themeId    = 0;
    bool                   isFavorite = false;
    qint64                 createdAt  = 0;
    qint64                 updatedAt  = 0;
    QList<SongSection>     sections;
    QString                snippet;
};

}  // namespace crater
