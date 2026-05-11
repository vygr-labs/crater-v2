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
};

}  // namespace crater::db
