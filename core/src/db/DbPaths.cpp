#include "db/DbPaths.h"

#include <QDir>
#include <QStandardPaths>

namespace crater::db {

namespace {

QString ensureDir(QString p)
{
    QDir d(p);
    if (!d.exists()) d.mkpath(QStringLiteral("."));
    return d.absolutePath();
}

}  // namespace

QString DbPaths::dataDir()
{
    return ensureDir(QStandardPaths::writableLocation(QStandardPaths::AppDataLocation));
}

QString DbPaths::biblesDbPath()
{
    return QDir(dataDir()).filePath(QStringLiteral("bibles.sqlite"));
}

QString DbPaths::songsDbPath()
{
    return QDir(dataDir()).filePath(QStringLiteral("songs.sqlite"));
}

QString DbPaths::appDbPath()
{
    return QDir(dataDir()).filePath(QStringLiteral("app.sqlite"));
}

QString DbPaths::importSentinelPath()
{
    return QDir(dataDir()).filePath(QStringLiteral(".imported-v1"));
}

QString DbPaths::scheduleHistoryDir()
{
    return ensureDir(QDir(dataDir()).filePath(QStringLiteral("schedules/.history")));
}

QString DbPaths::thumbnailsDir()
{
    return ensureDir(QDir(dataDir()).filePath(QStringLiteral("thumbnails")));
}

QString DbPaths::mediaDir()
{
    return ensureDir(QDir(dataDir()).filePath(QStringLiteral("media")));
}

}  // namespace crater::db
