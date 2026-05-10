#pragma once

#include <QObject>
#include <QString>
#include <QtQmlIntegration>

namespace crater {

// Pattern stub for the engine API surface.
//
// Mirrors electron/src/backend/database/bible-operations.ts. Each TS
// function becomes a Q_INVOKABLE method (or a Q_PROPERTY when the
// data is observable). Future siblings: SongService, ThemeService,
// StrongsService, ScheduleService, NdiService, RemoteService.
class BibleService : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

public:
    explicit BibleService(QObject *parent = nullptr);

    // TODO: port from bible-operations.ts
    //   fetchScripture, fetchChapter, fetchChapterCounts,
    //   fetchAllScripture, fetchTranslations, searchScriptures,
    //   rebuildScriptureFtsIndex, initializeScriptureFtsIndexIfEmpty
};

}
