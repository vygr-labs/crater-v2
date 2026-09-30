#include "db/DbPaths.h"

#include <QDir>
#include <QFileInfo>
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

QString DbPaths::fontsDir()
{
    return ensureDir(QDir(dataDir()).filePath(QStringLiteral("fonts")));
}

QString DbPaths::importStagingDir()
{
    return ensureDir(QDir(dataDir()).filePath(QStringLiteral(".import-staging")));
}

QString DbPaths::relocate(const QString& storedPath, const QString& managedDir)
{
    if (storedPath.isEmpty()) return storedPath;
    const QFileInfo stored(storedPath);
    const QString name = stored.fileName();
    if (name.isEmpty()) return storedPath;
    // Already under the managed folder, the usual case: nothing to look up.
    // Skips a disk hit per row on every media list reload.
    if (QDir::cleanPath(stored.absolutePath()) == QDir::cleanPath(managedDir))
        return storedPath;
    const QString current = QDir::cleanPath(QDir(managedDir).filePath(name));
    return QFileInfo::exists(current) ? current : storedPath;
}

}  // namespace crater::db
