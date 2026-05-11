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
    Q_PROPERTY(QList<crater::SongSection> sections MEMBER sections)

public:
    qint64                 id         = 0;
    QString                title;
    QString                author;
    QString                copyright;
    QString                ccli;
    qint64                 themeId    = 0;
    bool                   isFavorite = false;
    QList<SongSection>     sections;
};

}  // namespace crater
