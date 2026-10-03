#pragma once

#include <QString>

namespace crater::db {

// Centralized writable-path helpers. All methods are lazy: the underlying
// directory is created on demand the first time it is requested.
//
// Profiles (ARCHITECTURE.md §12). Every per-profile path below resolves
// under dataDir(), the ACTIVE profile's root. The Default profile's root is
// appRootDir() itself, so an install that predates profiles keeps every
// file exactly where it always was. Any other profile lives in
// profilesDir()/<id>/ with the same layout. ProfileService picks the
// profile once at startup, before any service opens a database, and calls
// setDataDir(); nothing re-points it while the process runs (switching
// profiles restarts the app).
class DbPaths
{
public:
    // The machine-wide root. Windows: %APPDATA%/Crater/. macOS:
    // ~/Library/Application Support/Crater/. Linux: ~/.local/share/Crater/.
    // Holds the profile registry, the Default profile's data, logs and
    // drop-in UI translations. Never changes with the active profile.
    static QString appRootDir();

    // Where non-default profiles live: appRootDir()/profiles/.
    static QString profilesDir();

    // The active profile's data root. appRootDir() for the Default profile.
    static QString dataDir();

    // Point dataDir() at another root. Empty restores the Default profile.
    // Called once by ProfileService::activate() before any DB is opened.
    // Not thread-safe by design: it must run before any worker exists.
    static void setDataDir(const QString& dir);

    // True while dataDir() is the Default profile's root (appRootDir()).
    static bool isDefaultDataDir();

    // The Bible library. Unlike everything else it is NOT per profile: one
    // file at appRootDir() that every profile reads, so a translation added
    // once is there for all of them. Each profile only chooses which
    // translations it shows, and in what order (SettingsService).
    static QString biblesDbPath();

    // SQLite DB file paths inside `dataDir()`.
    static QString songsDbPath();
    static QString appDbPath();

    // First-run import sentinel — file presence means the one-time copy from
    // electron's bundled DBs into the shared Bible library has completed.
    // Shared, like the library it guards.
    static QString importSentinelPath();

    // Directories the services create on demand.
    static QString scheduleHistoryDir();   // schedules/.history/
    static QString thumbnailsDir();        // thumbnails/
    static QString mediaDir();             // media/  (MediaService destination)
    static QString fontsDir();             // fonts/  (FontService destination)
    static QString importStagingDir();     // .import-staging/  (.craterheme v2 temp)

    // The same file names resolved against an explicit root instead of the
    // active profile. Used by the profile code, which reads and writes
    // profiles other than the one this process has open (duplicate, export,
    // import as a new profile). Nothing is created on disk.
    static QString biblesDbPathIn(const QString& root);
    static QString songsDbPathIn(const QString& root);
    static QString appDbPathIn(const QString& root);
    static QString importSentinelPathIn(const QString& root);
    static QString mediaDirIn(const QString& root);
    static QString fontsDirIn(const QString& root);

    // Current location of a file Crater manages in a flat directory such as
    // mediaDir() or fontsDir(). Rows store the absolute path the file had
    // when it was imported, which goes stale when the whole data folder is
    // restored somewhere else (another user profile, another machine). The
    // managed copy is looked up by file name in `managedDir` first; the
    // stored path is returned unchanged when no such file exists there.
    static QString relocate(const QString& storedPath, const QString& managedDir);
};

}  // namespace crater::db
