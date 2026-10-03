#pragma once

#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantList>
#include <QVariantMap>

#include <memory>

namespace crater {

// Profiles: separate, named sets of everything an operator builds up
// (songs, themes, media, presentations, schedules, installed Bibles and the
// content preferences), in the EasyWorship sense. One church, service or
// operator per profile on a shared PC. Design: ARCHITECTURE.md §12.
//
// Storage. The Default profile IS the data folder Crater has always used,
// so nothing moves for an existing install. Other profiles live in
// <data>/profiles/<id>/ with the same layout. The list of profiles, the
// last one used and the ask-at-startup choice are machine-wide, in
// <data>/profiles.json.
//
// Switching. Every service opens its databases once, at startup, so a
// switch persists the choice and asks the app to restart (restartRequested,
// which main.cpp turns into a relaunch). crater-core does not start
// processes itself (§9).
//
// Startup. activate() must run before runAllMigrations(): it decides which
// profile this process uses and points DbPaths at it. A launch with
// --profile=<id> (what a switch restarts with) uses that profile and skips
// the ask-at-startup picker.
//
// Long operations (create by duplicating, delete, export, import) run on a
// worker thread, one at a time. `busy`, `progress` and `progressText` track
// the running one and operationFinished reports how it went.
class ProfileService : public QObject
{
    Q_OBJECT

    // [{ id, name, createdAt, lastUsedAt, isDefault, isCurrent }], Default
    // first, then by name.
    Q_PROPERTY(QVariantList profiles READ profiles NOTIFY profilesChanged)
    // Fixed for the life of the process: a switch restarts the app.
    Q_PROPERTY(QString currentProfileId READ currentProfileId CONSTANT)
    Q_PROPERTY(QString currentProfileName READ currentProfileName NOTIFY profilesChanged)
    // When on and more than one profile exists, the console opens with a
    // profile picker (unless the launch already named a profile).
    Q_PROPERTY(bool askAtStartup READ askAtStartup WRITE setAskAtStartup NOTIFY askAtStartupChanged)
    Q_PROPERTY(bool shouldPromptAtStartup READ shouldPromptAtStartup CONSTANT)
    Q_PROPERTY(bool    busy         READ busy         NOTIFY busyChanged)
    Q_PROPERTY(qreal   progress     READ progress     NOTIFY progressChanged)
    Q_PROPERTY(QString progressText READ progressText NOTIFY progressChanged)
    // "themes", "media", "presentations", "scriptures", "songs",
    // "schedules", "settings": the keys the export / import part maps use.
    Q_PROPERTY(QStringList partKeys READ partKeys CONSTANT)

public:
    explicit ProfileService(QObject* parent = nullptr);
    ~ProfileService() override;

    // Pick this process's profile and point DbPaths at it. Call once, in
    // main(), before runAllMigrations() and before any service exists.
    // `arguments` is QCoreApplication::arguments().
    void activate(const QStringList& arguments);

    QVariantList profiles() const;
    QString      currentProfileId() const;
    QString      currentProfileName() const;
    bool         askAtStartup() const;
    void         setAskAtStartup(bool on);
    bool         shouldPromptAtStartup() const;
    bool         busy() const;
    qreal        progress() const;
    QString      progressText() const;
    QStringList  partKeys() const;

    // New profile, empty (fresh-install contents: the built-in themes and
    // the bundled Bibles) or a full copy of the current one. Async; reports
    // through operationFinished("create", ...) with details.id.
    Q_INVOKABLE bool createProfile(QString name, bool duplicateCurrent);

    Q_INVOKABLE bool renameProfile(QString id, QString name);

    // Permanently removes a profile and its data. Refused for the Default
    // profile and for the one in use. The UI confirms first.
    // Async; reports through operationFinished("delete", ...).
    Q_INVOKABLE bool deleteProfile(QString id);

    // Remember `id` as the profile to open and ask for a restart into it.
    Q_INVOKABLE bool switchTo(QString id);

    // Restart into the current profile (after a merge import, so every
    // service reloads what was added).
    Q_INVOKABLE void restart();

    // Validate a .craterprofile and describe it:
    // { ok, error, profileName, appVersion, exportedAt, totalBytes,
    //   parts: { themes: bool, ... }, counts: { songs: n, ... } }
    Q_INVOKABLE QVariantMap inspectArchive(QString path);

    // What each part of the current profile holds, keyed like `partKeys`:
    // { songs: { count, bytes }, ... }. For the export dialog's sizes.
    Q_INVOKABLE QVariantMap partSizes() const;

    // Export the current profile. `parts` is { themes: true, ... }.
    // Async; reports through operationFinished("export", ...).
    Q_INVOKABLE bool exportProfile(QString path, QVariantMap parts);

    // Import an archive, either as a new profile named `newName` (the
    // archive's own name when empty) or merged into the current profile.
    // Async; reports through operationFinished("import", ...). A merge is
    // complete on disk when it reports, but the running services only show
    // it after restart().
    Q_INVOKABLE bool importArchive(QString path, QVariantMap parts,
                                   bool asNewProfile, QString newName);

    // "<current profile name>.craterprofile", safe as a file name.
    Q_INVOKABLE QString suggestedExportName() const;

    Q_INVOKABLE QString lastError() const;

signals:
    void profilesChanged();
    void askAtStartupChanged();
    void busyChanged();
    void progressChanged();
    // operation: "create" | "delete" | "export" | "import".
    // details: id / name of a new profile, added / skipped counts per part,
    // warnings (QStringList), and for imports `asNewProfile`.
    void operationFinished(QString operation, bool ok, QString message, QVariantMap details);
    // The app should relaunch itself with --profile=<profileId>.
    void restartRequested(QString profileId);

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;

    void setBusy(bool on);
    void setProgress(qreal fraction, const QString& text);
};

}  // namespace crater
