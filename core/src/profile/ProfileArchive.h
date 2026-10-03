#pragma once

#include <QJsonObject>
#include <QString>
#include <QStringList>
#include <QStringView>
#include <QVariantMap>

#include <functional>

namespace crater::profile {

// The data engine behind profiles (ARCHITECTURE.md §12): the .craterprofile
// archive (export, inspect, import) plus creating and duplicating a
// profile's data folder.
//
// Everything here takes explicit profile roots instead of reading
// DbPaths::dataDir(), because most of it works on a profile this process
// does NOT have open: exporting another profile, importing into a brand new
// one, duplicating. Each call opens its own SQLite connections, so all of it
// can run on a worker thread. Nothing here touches Qt GUI.
//
// Data safety rules every function follows:
//   • The source profile is only ever read. Databases are snapshotted with
//     VACUUM INTO, so a running Crater keeps writing undisturbed.
//   • Archive contents are extracted into a staging folder first and
//     validated there (§5.1): entry names against an allow-list, sizes
//     against caps, SHA-256 of every media and font file against the
//     manifest, magic bytes, and SQLite files are checked, stripped of any
//     triggers and views, and migrated in staging before a row is read.
//   • Imports only ever ADD rows and files. Nothing in the target is
//     updated or deleted, and an item that already exists is matched
//     instead of duplicated (see importArchive).

// The parts a profile archive can carry. "Themes" includes the user fonts
// themes use. "Settings" are the per-profile preferences listed in
// ProfileSettings.h.
enum Part : unsigned {
    PartThemes        = 1u << 0,
    PartMedia         = 1u << 1,
    PartPresentations = 1u << 2,
    PartScriptures    = 1u << 3,
    PartSongs         = 1u << 4,
    PartSchedules     = 1u << 5,
    PartSettings      = 1u << 6,
};
constexpr unsigned kAllParts = 0x7Fu;

// "themes", "media", "presentations", "scriptures", "songs", "schedules",
// "settings", in the order the UI lists them.
QStringList partKeys();
unsigned    partForKey(QStringView key);
unsigned    partsFromMap(const QVariantMap& map);   // { themes: true, ... }
QVariantMap partsToMap(unsigned parts);

// fraction is 0..1 across the whole operation; stage is a short
// operator-facing phrase ("Copying media").
using ProgressFn = std::function<void(double fraction, const QString& stage)>;

inline constexpr int kArchiveFormatVersion = 1;

struct ArchiveInfo
{
    bool        ok = false;
    QString     error;            // operator-facing, when !ok
    QString     profileName;
    QString     appVersion;
    qint64      exportedAt = 0;   // unix ms
    unsigned    parts = 0;        // parts actually present and readable
    QVariantMap counts;           // { songs: 120, media: 34, ... }
    qint64      totalBytes = 0;
    QJsonObject manifest;
};

// Validate an archive and read its manifest. Cheap: no payload is read
// beyond the manifest itself.
ArchiveInfo inspectArchive(const QString& archivePath);

struct ExportResult
{
    bool        ok = false;
    QString     error;
    QVariantMap counts;
    QStringList warnings;         // items left out (file missing on disk, ...)
};

// Write the selected parts of the profile rooted at `sourceRoot` to
// `destPath` (atomic: a failed export leaves no file behind).
// `stagingParent` must be on a writable volume; a per-call folder is made
// inside it and removed afterwards.
ExportResult exportArchive(const QString&    sourceRoot,
                           const QString&    profileName,
                           unsigned          parts,
                           const QString&    destPath,
                           const QString&    stagingParent,
                           const ProgressFn& progress = {});

struct ImportResult
{
    bool        ok = false;
    QString     error;
    QVariantMap added;            // per part: items written
    QVariantMap skipped;          // per part: items matched to existing ones
    QStringList warnings;
};

// Import the selected parts of an archive into the profile rooted at
// `targetRoot`, whose databases must already exist at the current schema
// (initProfileRoot). `targetIsNew` marks a profile created for this import:
// it also receives the archive's default-theme choices and, when Bibles
// come along, the first-run marker so the bundled Bibles are not added on
// top. Merging into an existing profile never changes its defaults.
//
// Dedupe rules (merge): songs by title plus lyrics, themes by kind, name
// and design, media by file content, fonts by content hash, Bibles by
// translation code, collections by name, presentations and schedules by
// title/name plus content.
ImportResult importArchive(const QString&    archivePath,
                           unsigned          parts,
                           const QString&    targetRoot,
                           bool              targetIsNew,
                           const QString&    stagingParent,
                           const ProgressFn& progress = {});

// Create a profile root's folders and bring its three databases to the
// current schema. Safe on an existing root (migrations are idempotent).
bool initProfileRoot(const QString& root, QString* error);

// Copy a whole profile: databases (snapshotted), media, fonts, schedule
// history, the first-run marker and the per-profile settings. Stored file
// paths in the copy are rebased onto the copy's own folders, so deleting
// an item in one profile can never delete the other profile's file.
bool duplicateProfileData(const QString&    sourceRoot,
                          const QString&    destRoot,
                          const ProgressFn& progress,
                          QString*          error);

}  // namespace crater::profile
