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

// The active profile's root when it is not the Default profile. Empty means
// Default (appRootDir()). Written once at startup, before any worker thread
// exists, and only read afterwards — see DbPaths::setDataDir.
QString& overrideRoot()
{
    static QString root;
    return root;
}

}  // namespace

QString DbPaths::appRootDir()
{
    return ensureDir(QStandardPaths::writableLocation(QStandardPaths::AppDataLocation));
}

QString DbPaths::profilesDir()
{
    return ensureDir(QDir(appRootDir()).filePath(QStringLiteral("profiles")));
}

QString DbPaths::dataDir()
{
    const QString& o = overrideRoot();
    if (!o.isEmpty()) return ensureDir(o);
    return appRootDir();
}

void DbPaths::setDataDir(const QString& dir)
{
    if (dir.isEmpty()) {
        overrideRoot().clear();
        return;
    }
    const QString clean = QDir::cleanPath(QDir(dir).absolutePath());
    // Pointing at the app root IS the Default profile; store nothing so
    // isDefaultDataDir() stays a plain emptiness check.
    if (clean == QDir::cleanPath(appRootDir())) {
        overrideRoot().clear();
        return;
    }
    overrideRoot() = clean;
}

bool DbPaths::isDefaultDataDir()
{
    return overrideRoot().isEmpty();
}

QString DbPaths::biblesDbPath()
{
    // Shared by every profile (see the header).
    return biblesDbPathIn(appRootDir());
}

QString DbPaths::songsDbPath()
{
    return songsDbPathIn(dataDir());
}

QString DbPaths::appDbPath()
{
    return appDbPathIn(dataDir());
}

QString DbPaths::importSentinelPath()
{
    // The one-time Bible import fills the shared library, so its marker is
    // shared too.
    return importSentinelPathIn(appRootDir());
}

QString DbPaths::previousImportSentinelPath()
{
    return QDir(appRootDir()).filePath(QStringLiteral(".imported-v1"));
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
    return ensureDir(mediaDirIn(dataDir()));
}

QString DbPaths::fontsDir()
{
    return ensureDir(fontsDirIn(dataDir()));
}

QString DbPaths::importStagingDir()
{
    return ensureDir(QDir(dataDir()).filePath(QStringLiteral(".import-staging")));
}

QString DbPaths::biblesDbPathIn(const QString& root)
{
    return QDir(root).filePath(QStringLiteral("bibles.sqlite"));
}

QString DbPaths::songsDbPathIn(const QString& root)
{
    return QDir(root).filePath(QStringLiteral("songs.sqlite"));
}

QString DbPaths::appDbPathIn(const QString& root)
{
    return QDir(root).filePath(QStringLiteral("app.sqlite"));
}

QString DbPaths::importSentinelPathIn(const QString& root)
{
    return QDir(root).filePath(QStringLiteral(".imported-v2"));
}

QString DbPaths::mediaDirIn(const QString& root)
{
    return QDir(QDir(root).filePath(QStringLiteral("media"))).absolutePath();
}

QString DbPaths::fontsDirIn(const QString& root)
{
    return QDir(QDir(root).filePath(QStringLiteral("fonts"))).absolutePath();
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
