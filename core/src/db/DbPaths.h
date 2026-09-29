#pragma once

#include <QString>

namespace crater::db {

// Centralized writable-path helpers. All methods are lazy: the underlying
// directory is created on demand the first time it is requested.
class DbPaths
{
public:
    // Writable app-data directory. Windows: %APPDATA%/Crater/. macOS:
    // ~/Library/Application Support/Crater/. Linux: ~/.local/share/Crater/.
    static QString dataDir();

    // SQLite DB file paths inside `dataDir()`.
    static QString biblesDbPath();
    static QString songsDbPath();
    static QString appDbPath();

    // First-run import sentinel — file presence means the one-time copy from
    // electron's bundled DBs has completed.
    static QString importSentinelPath();

    // Directories the services create on demand.
    static QString scheduleHistoryDir();   // schedules/.history/
    static QString thumbnailsDir();        // thumbnails/
    static QString mediaDir();             // media/  (MediaService destination)
    static QString fontsDir();             // fonts/  (FontService destination)
    static QString importStagingDir();     // .import-staging/  (.craterheme v2 temp)

    // Current location of a file Crater manages in a flat directory such as
    // mediaDir() or fontsDir(). Rows store the absolute path the file had
    // when it was imported, which goes stale when the whole data folder is
    // restored somewhere else (another user profile, another machine). The
    // managed copy is looked up by file name in `managedDir` first; the
    // stored path is returned unchanged when no such file exists there.
    static QString relocate(const QString& storedPath, const QString& managedDir);
};

}  // namespace crater::db
