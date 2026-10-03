#include "crater/ProfileService.h"

#include "db/DbPaths.h"
#include "profile/ProfileArchive.h"

#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QPointer>
#include <QRandomGenerator>
#include <QRegularExpression>
#include <QSaveFile>
#include <QSet>
#include <QUrl>
#include <QUuid>
#include <QtConcurrent>

#include <algorithm>
#include <atomic>

namespace crater {

namespace {

const QString kDefaultId = QStringLiteral("default");

// Marker a profile folder carries while it is being created. A folder that
// still has it at startup is the leftover of a crash mid-create and is the
// ONLY kind of profile folder ever removed automatically.
const QString kIncompleteMarker = QStringLiteral(".incomplete");

// Per-profile identity file, so the registry can be rebuilt from the
// folders if profiles.json is ever lost or damaged.
const QString kProfileInfoFile = QStringLiteral("profile.json");

const QString kStagingDirName = QStringLiteral(".staging");
const QString kTrashPrefix    = QStringLiteral(".trash-");

bool isValidId(const QString& id)
{
    static const QRegularExpression re(QStringLiteral("^p-[0-9a-f]{6,32}$"));
    return id == kDefaultId || re.match(id).hasMatch();
}

QString newProfileId()
{
    const quint64 r = QRandomGenerator::global()->generate64();
    return QStringLiteral("p-%1").arg(r & 0xFFFFFFFFFFFFull, 12, 16, QLatin1Char('0'));
}

QString registryPath()
{
    return QDir(db::DbPaths::appRootDir()).filePath(QStringLiteral("profiles.json"));
}

QString stagingParent()
{
    const QString p = QDir(db::DbPaths::profilesDir()).filePath(kStagingDirName);
    QDir().mkpath(p);
    return p;
}

// A profile folder this code may delete: directly inside profilesDir(),
// named like a profile id, and never the app root.
bool isDeletableProfileDir(const QString& dir)
{
    const QFileInfo fi(dir);
    if (!fi.isDir()) return false;
    const QString parent = QDir::cleanPath(fi.absolutePath());
    if (parent != QDir::cleanPath(QDir(db::DbPaths::profilesDir()).absolutePath())) return false;
    const QString name = fi.fileName();
    return isValidId(name) && name != kDefaultId;
}

bool writeMarker(const QString& root)
{
    QFile marker(QDir(root).filePath(kIncompleteMarker));
    if (!marker.open(QIODevice::WriteOnly)) return false;
    marker.write("creating\n");
    return true;
}

QString cleanName(const QString& raw)
{
    QString n = raw.simplified();
    n.remove(QRegularExpression(QStringLiteral("[\\x00-\\x1F]")));
    return n.left(80);
}

void writeProfileInfo(const QString& root, const QString& id, const QString& name, qint64 createdAt)
{
    QSaveFile f(QDir(root).filePath(kProfileInfoFile));
    if (!f.open(QIODevice::WriteOnly)) return;
    const QJsonObject o{
        { QStringLiteral("id"),        id },
        { QStringLiteral("name"),      name },
        { QStringLiteral("createdAt"), createdAt },
    };
    f.write(QJsonDocument(o).toJson(QJsonDocument::Indented));
    f.commit();
}

}  // namespace

struct ProfileService::Impl
{
    struct Entry {
        QString id;
        QString name;
        qint64  createdAt  = 0;
        qint64  lastUsedAt = 0;
    };

    QList<Entry> entries;
    QString      storedCurrent = kDefaultId;   // profiles.json "current"
    QString      currentId     = kDefaultId;   // what this process uses
    bool         askAtStartup  = false;
    bool         explicitLaunch = false;       // --profile=<id> on the command line
    bool         busy          = false;
    qreal        progress      = 0;
    QString      progressText;
    QString      lastError;

    Entry* find(const QString& id)
    {
        for (Entry& e : entries) if (e.id == id) return &e;
        return nullptr;
    }

    static QString rootFor(const QString& id)
    {
        if (id == kDefaultId) return db::DbPaths::appRootDir();
        return QDir(db::DbPaths::profilesDir()).filePath(id);
    }

    void ensureDefault()
    {
        if (find(kDefaultId)) return;
        Entry d;
        d.id = kDefaultId;
        d.name = QStringLiteral("Default");
        const QDateTime born = QFileInfo(db::DbPaths::appDbPathIn(db::DbPaths::appRootDir())).birthTime();
        d.createdAt = born.isValid() ? born.toMSecsSinceEpoch() : QDateTime::currentMSecsSinceEpoch();
        entries.prepend(d);
    }

    // Rebuild the list from the folders on disk. Used only when
    // profiles.json is unreadable, so a damaged registry never hides data.
    void recoverFromDisk()
    {
        entries.clear();
        ensureDefault();
        QDir dir(db::DbPaths::profilesDir());
        for (const QString& name : dir.entryList(QDir::Dirs | QDir::NoDotAndDotDot)) {
            if (!isValidId(name) || name == kDefaultId) continue;
            const QString root = dir.filePath(name);
            if (QFile::exists(QDir(root).filePath(kIncompleteMarker))) continue;
            Entry e;
            e.id = name;
            QFile f(QDir(root).filePath(kProfileInfoFile));
            if (f.open(QIODevice::ReadOnly)) {
                const QJsonObject o = QJsonDocument::fromJson(f.readAll()).object();
                e.name = cleanName(o.value(QStringLiteral("name")).toString());
                e.createdAt = o.value(QStringLiteral("createdAt")).toVariant().toLongLong();
            }
            if (e.name.isEmpty()) e.name = name;
            entries.append(e);
        }
    }

    void load()
    {
        entries.clear();
        QFile f(registryPath());
        if (!f.exists()) {
            ensureDefault();
            return;
        }
        QJsonParseError pe{};
        const QJsonDocument doc = f.open(QIODevice::ReadOnly)
            ? QJsonDocument::fromJson(f.readAll(), &pe) : QJsonDocument();
        f.close();
        if (pe.error != QJsonParseError::NoError || !doc.isObject()) {
            // Keep the damaged file for inspection, never overwrite it.
            const QString aside = registryPath() + QStringLiteral(".damaged-")
                                + QString::number(QDateTime::currentMSecsSinceEpoch());
            QFile::copy(registryPath(), aside);
            qWarning().noquote() << "ProfileService: profiles.json unreadable, rebuilt from"
                                 << "the profile folders (copy kept at" << aside << ")";
            recoverFromDisk();
            return;
        }
        const QJsonObject o = doc.object();
        askAtStartup  = o.value(QStringLiteral("askAtStartup")).toBool(false);
        storedCurrent = o.value(QStringLiteral("current")).toString(kDefaultId);
        QSet<QString> seen;
        for (const QJsonValue& v : o.value(QStringLiteral("profiles")).toArray()) {
            const QJsonObject p = v.toObject();
            Entry e;
            e.id         = p.value(QStringLiteral("id")).toString();
            e.name       = cleanName(p.value(QStringLiteral("name")).toString());
            e.createdAt  = p.value(QStringLiteral("createdAt")).toVariant().toLongLong();
            e.lastUsedAt = p.value(QStringLiteral("lastUsedAt")).toVariant().toLongLong();
            if (!isValidId(e.id) || seen.contains(e.id)) continue;
            if (e.name.isEmpty()) e.name = e.id == kDefaultId ? QStringLiteral("Default") : e.id;
            seen.insert(e.id);
            entries.append(e);
        }
        ensureDefault();
    }

    bool save()
    {
        QJsonArray list;
        for (const Entry& e : entries) {
            list.append(QJsonObject{
                { QStringLiteral("id"),         e.id },
                { QStringLiteral("name"),       e.name },
                { QStringLiteral("createdAt"),  e.createdAt },
                { QStringLiteral("lastUsedAt"), e.lastUsedAt },
            });
        }
        const QJsonObject o{
            { QStringLiteral("version"),      1 },
            { QStringLiteral("current"),      storedCurrent },
            { QStringLiteral("askAtStartup"), askAtStartup },
            { QStringLiteral("profiles"),     list },
        };
        // Atomic replace (§8): a power cut mid-write leaves the old list.
        QSaveFile f(registryPath());
        if (!f.open(QIODevice::WriteOnly)) return false;
        f.write(QJsonDocument(o).toJson(QJsonDocument::Indented));
        return f.commit();
    }

    // Startup housekeeping inside profiles/: half-created profiles (they
    // carry the marker), deleted profiles still on their way out, and
    // staging folders from an interrupted export or import. Nothing else
    // in there is ever touched.
    static void sweep()
    {
        QDir dir(db::DbPaths::profilesDir());
        for (const QString& name : dir.entryList(QDir::Dirs | QDir::NoDotAndDotDot | QDir::Hidden)) {
            const QString path = dir.filePath(name);
            if (name == kStagingDirName || name.startsWith(kTrashPrefix)) {
                QDir(path).removeRecursively();
                continue;
            }
            if (isDeletableProfileDir(path) && QFile::exists(QDir(path).filePath(kIncompleteMarker))) {
                qInfo().noquote() << "ProfileService: removing unfinished profile folder" << name;
                QDir(path).removeRecursively();
            }
        }
    }
};

ProfileService::ProfileService(QObject* parent)
    : QObject(parent)
    , m_impl(std::make_unique<Impl>())
{
    m_impl->load();
}

ProfileService::~ProfileService() = default;

void ProfileService::activate(const QStringList& arguments)
{
    Impl::sweep();

    QString wanted;
    for (const QString& a : arguments) {
        if (a.startsWith(QStringLiteral("--profile="))) {
            wanted = a.mid(10);
            m_impl->explicitLaunch = true;
        }
    }
    if (wanted.isEmpty()) wanted = m_impl->storedCurrent;

    // Fall back to Default for anything unknown or whose folder is gone,
    // rather than silently creating an empty profile in its place.
    const bool known = m_impl->find(wanted) != nullptr;
    const bool hasFolder = wanted == kDefaultId || QFileInfo(Impl::rootFor(wanted)).isDir();
    if (!known || !hasFolder) {
        if (wanted != kDefaultId)
            qWarning().noquote() << "ProfileService: profile" << wanted
                                 << "is not available, opening Default";
        wanted = kDefaultId;
    }

    m_impl->currentId = wanted;
    db::DbPaths::setDataDir(wanted == kDefaultId ? QString() : Impl::rootFor(wanted));

    if (Impl::Entry* e = m_impl->find(wanted)) e->lastUsedAt = QDateTime::currentMSecsSinceEpoch();
    m_impl->storedCurrent = wanted;
    m_impl->save();

    qInfo().noquote() << "ProfileService: using profile" << wanted
                      << "(" << currentProfileName() << ") at" << db::DbPaths::dataDir();
}

QVariantList ProfileService::profiles() const
{
    QList<Impl::Entry> sorted = m_impl->entries;
    std::stable_sort(sorted.begin(), sorted.end(), [](const Impl::Entry& a, const Impl::Entry& b) {
        if (a.id == kDefaultId) return b.id != kDefaultId;
        if (b.id == kDefaultId) return false;
        return QString::compare(a.name, b.name, Qt::CaseInsensitive) < 0;
    });
    QVariantList out;
    for (const Impl::Entry& e : sorted) {
        out.append(QVariantMap{
            { QStringLiteral("id"),         e.id },
            { QStringLiteral("name"),       e.name },
            { QStringLiteral("createdAt"),  e.createdAt },
            { QStringLiteral("lastUsedAt"), e.lastUsedAt },
            { QStringLiteral("isDefault"),  e.id == kDefaultId },
            { QStringLiteral("isCurrent"),  e.id == m_impl->currentId },
        });
    }
    return out;
}

QString ProfileService::currentProfileId() const { return m_impl->currentId; }

QString ProfileService::currentProfileName() const
{
    const Impl::Entry* e = m_impl->find(m_impl->currentId);
    return e ? e->name : QStringLiteral("Default");
}

bool ProfileService::askAtStartup() const { return m_impl->askAtStartup; }

void ProfileService::setAskAtStartup(bool on)
{
    if (m_impl->askAtStartup == on) return;
    m_impl->askAtStartup = on;
    m_impl->save();
    emit askAtStartupChanged();
}

bool ProfileService::shouldPromptAtStartup() const
{
    return m_impl->askAtStartup && m_impl->entries.size() > 1 && !m_impl->explicitLaunch;
}

bool    ProfileService::busy() const         { return m_impl->busy; }
qreal   ProfileService::progress() const     { return m_impl->progress; }
QString ProfileService::progressText() const { return m_impl->progressText; }
QString ProfileService::lastError() const    { return m_impl->lastError; }

QStringList ProfileService::partKeys() const
{
    return profile::partKeys();
}

void ProfileService::setBusy(bool on)
{
    if (m_impl->busy == on) return;
    m_impl->busy = on;
    if (on) setProgress(0, QString());
    emit busyChanged();
}

void ProfileService::setProgress(qreal fraction, const QString& text)
{
    m_impl->progress = qBound<qreal>(0, fraction, 1);
    m_impl->progressText = text;
    emit progressChanged();
}

namespace {

// Worker-side progress reporter. Posts to the service on its own thread,
// at most once per half percent or stage change so a multi-GB copy does not
// flood the event loop.
profile::ProgressFn makeProgress(QObject* ctx, std::function<void(qreal, QString)> apply)
{
    struct State { std::atomic<int> lastStep{-1}; QString lastText; };
    auto state = std::make_shared<State>();
    QPointer<QObject> guard(ctx);
    return [state, guard, apply](double f, const QString& text) {
        const int step = int(f * 200);
        if (step == state->lastStep.load() && text == state->lastText) return;
        state->lastStep = step;
        state->lastText = text;
        if (!guard) return;
        QMetaObject::invokeMethod(guard.data(), [apply, f, text] { apply(f, text); },
                                  Qt::QueuedConnection);
    };
}

struct WorkResult {
    bool        ok = false;
    QString     error;
    QVariantMap details;
};

}  // namespace

bool ProfileService::createProfile(QString name, bool duplicateCurrent)
{
    m_impl->lastError.clear();
    const QString clean = cleanName(name);
    if (m_impl->busy) { m_impl->lastError = QStringLiteral("Another profile task is still running."); return false; }
    if (clean.isEmpty()) { m_impl->lastError = QStringLiteral("Enter a name for the profile."); return false; }

    QString id = newProfileId();
    while (m_impl->find(id) || QFileInfo::exists(Impl::rootFor(id))) id = newProfileId();
    const QString root = Impl::rootFor(id);
    if (!QDir().mkpath(root)) {
        m_impl->lastError = QStringLiteral("Could not create the profile folder.");
        return false;
    }
    if (!writeMarker(root)) {
        m_impl->lastError = QStringLiteral("Could not create the profile folder.");
        return false;
    }

    const QString source = Impl::rootFor(m_impl->currentId);
    setBusy(true);
    setProgress(0, duplicateCurrent ? QStringLiteral("Copying profile") : QStringLiteral("Creating profile"));
    auto progress = makeProgress(this, [this](qreal f, QString t) { if (m_impl->busy) setProgress(f, t); });

    QtConcurrent::run([root, source, duplicateCurrent, progress]() -> WorkResult {
        WorkResult r;
        try {
            QString err;
            r.ok = duplicateCurrent ? profile::duplicateProfileData(source, root, progress, &err)
                                    : profile::initProfileRoot(root, &err);
            r.error = err;
        } catch (const std::exception& e) {
            qWarning() << "ProfileService::createProfile:" << e.what();
            r.error = QStringLiteral("could not create the profile");
        }
        return r;
    }).then(this, [this, id, root, clean](WorkResult r) {
        if (r.ok) {
            const qint64 now = QDateTime::currentMSecsSinceEpoch();
            writeProfileInfo(root, id, clean, now);
            QFile::remove(QDir(root).filePath(kIncompleteMarker));
            m_impl->entries.append(Impl::Entry{ id, clean, now, 0 });
            m_impl->save();
            emit profilesChanged();
        } else if (isDeletableProfileDir(root)) {
            QDir(root).removeRecursively();
        }
        setBusy(false);
        emit operationFinished(QStringLiteral("create"), r.ok, r.error,
                               QVariantMap{ { QStringLiteral("id"), id },
                                            { QStringLiteral("name"), clean } });
    });
    return true;
}

bool ProfileService::renameProfile(QString id, QString name)
{
    m_impl->lastError.clear();
    const QString clean = cleanName(name);
    Impl::Entry* e = m_impl->find(id);
    if (!e || clean.isEmpty()) {
        m_impl->lastError = QStringLiteral("Enter a name for the profile.");
        return false;
    }
    if (e->name == clean) return true;
    e->name = clean;
    if (id != kDefaultId) writeProfileInfo(Impl::rootFor(id), id, clean, e->createdAt);
    m_impl->save();
    emit profilesChanged();
    return true;
}

bool ProfileService::deleteProfile(QString id)
{
    m_impl->lastError.clear();
    if (m_impl->busy) { m_impl->lastError = QStringLiteral("Another profile task is still running."); return false; }
    if (id == kDefaultId) { m_impl->lastError = QStringLiteral("The Default profile cannot be deleted."); return false; }
    if (id == m_impl->currentId) {
        m_impl->lastError = QStringLiteral("Switch to another profile before deleting this one.");
        return false;
    }
    const Impl::Entry* e = m_impl->find(id);
    if (!e) { m_impl->lastError = QStringLiteral("That profile no longer exists."); return false; }
    const QString name = e->name;

    // Move the folder aside first (one rename, all or nothing), then drop
    // the entry, then delete in the background. A crash part way leaves a
    // .trash- folder that the next startup finishes removing.
    const QString root = Impl::rootFor(id);
    QString trash;
    if (QFileInfo(root).isDir()) {
        if (!isDeletableProfileDir(root)) {
            m_impl->lastError = QStringLiteral("That profile's folder is not where Crater expects it.");
            return false;
        }
        trash = QDir(db::DbPaths::profilesDir()).filePath(
            kTrashPrefix + id + QLatin1Char('-') + QUuid::createUuid().toString(QUuid::Id128).left(8));
        if (!QDir().rename(root, trash)) {
            m_impl->lastError = QStringLiteral("The profile's files are in use. Close anything using them and try again.");
            return false;
        }
    }
    m_impl->entries.erase(std::remove_if(m_impl->entries.begin(), m_impl->entries.end(),
                                         [&](const Impl::Entry& x) { return x.id == id; }),
                          m_impl->entries.end());
    if (m_impl->storedCurrent == id) m_impl->storedCurrent = m_impl->currentId;
    m_impl->save();
    emit profilesChanged();

    setBusy(true);
    setProgress(0, QStringLiteral("Deleting profile"));
    QtConcurrent::run([trash]() -> WorkResult {
        WorkResult r;
        r.ok = true;
        if (!trash.isEmpty() && !QDir(trash).removeRecursively())
            qWarning().noquote() << "ProfileService: some files in" << trash
                                 << "could not be removed yet; they go at next startup";
        return r;
    }).then(this, [this, id, name](WorkResult r) {
        setBusy(false);
        emit operationFinished(QStringLiteral("delete"), r.ok, r.error,
                               QVariantMap{ { QStringLiteral("id"), id },
                                            { QStringLiteral("name"), name } });
    });
    return true;
}

bool ProfileService::switchTo(QString id)
{
    m_impl->lastError.clear();
    if (m_impl->busy) { m_impl->lastError = QStringLiteral("Wait for the current profile task to finish."); return false; }
    if (!m_impl->find(id) || (id != kDefaultId && !QFileInfo(Impl::rootFor(id)).isDir())) {
        m_impl->lastError = QStringLiteral("That profile no longer exists.");
        return false;
    }
    m_impl->storedCurrent = id;
    if (!m_impl->save()) {
        m_impl->lastError = QStringLiteral("Could not save the profile choice.");
        return false;
    }
    emit restartRequested(id);
    return true;
}

void ProfileService::restart()
{
    if (m_impl->busy) return;
    emit restartRequested(m_impl->currentId);
}

QVariantMap ProfileService::inspectArchive(QString path)
{
    const profile::ArchiveInfo info = profile::inspectArchive(path);
    return QVariantMap{
        { QStringLiteral("ok"),          info.ok },
        { QStringLiteral("error"),       info.error },
        { QStringLiteral("profileName"), info.profileName },
        { QStringLiteral("appVersion"),  info.appVersion },
        { QStringLiteral("exportedAt"),  info.exportedAt },
        { QStringLiteral("totalBytes"),  info.totalBytes },
        { QStringLiteral("parts"),       profile::partsToMap(info.parts) },
        { QStringLiteral("counts"),      info.counts },
    };
}

bool ProfileService::exportProfile(QString path, QVariantMap parts)
{
    m_impl->lastError.clear();
    if (m_impl->busy) { m_impl->lastError = QStringLiteral("Another profile task is still running."); return false; }
    if (path.startsWith(QStringLiteral("file:"))) path = QUrl(path).toLocalFile();
    if (path.isEmpty()) { m_impl->lastError = QStringLiteral("Choose where to save the file."); return false; }
    const unsigned mask = profile::partsFromMap(parts);
    if (mask == 0) { m_impl->lastError = QStringLiteral("Choose at least one thing to export."); return false; }

    const QString source  = Impl::rootFor(m_impl->currentId);
    const QString name    = currentProfileName();
    const QString staging = stagingParent();
    setBusy(true);
    setProgress(0, QStringLiteral("Preparing export"));
    auto progress = makeProgress(this, [this](qreal f, QString t) { if (m_impl->busy) setProgress(f, t); });

    QtConcurrent::run([source, name, mask, path, staging, progress]() -> WorkResult {
        WorkResult r;
        try {
            const profile::ExportResult x =
                profile::exportArchive(source, name, mask, path, staging, progress);
            r.ok = x.ok;
            r.error = x.error;
            r.details.insert(QStringLiteral("counts"), x.counts);
            r.details.insert(QStringLiteral("warnings"), x.warnings);
        } catch (const std::exception& e) {
            qWarning() << "ProfileService::exportProfile:" << e.what();
            r.error = QStringLiteral("The export failed.");
        }
        return r;
    }).then(this, [this, path](WorkResult r) {
        r.details.insert(QStringLiteral("path"), path);
        setBusy(false);
        emit operationFinished(QStringLiteral("export"), r.ok, r.error, r.details);
    });
    return true;
}

bool ProfileService::importArchive(QString path, QVariantMap parts, bool asNewProfile, QString newName)
{
    m_impl->lastError.clear();
    if (m_impl->busy) { m_impl->lastError = QStringLiteral("Another profile task is still running."); return false; }
    if (path.startsWith(QStringLiteral("file:"))) path = QUrl(path).toLocalFile();
    const unsigned mask = profile::partsFromMap(parts);
    if (mask == 0) { m_impl->lastError = QStringLiteral("Choose at least one thing to import."); return false; }

    const QString staging = stagingParent();
    QString id, root, name;
    if (asNewProfile) {
        name = cleanName(newName);
        if (name.isEmpty()) name = QStringLiteral("Imported profile");
        id = newProfileId();
        while (m_impl->find(id) || QFileInfo::exists(Impl::rootFor(id))) id = newProfileId();
        root = Impl::rootFor(id);
        if (!QDir().mkpath(root)) {
            m_impl->lastError = QStringLiteral("Could not create the profile folder.");
            return false;
        }
        if (!writeMarker(root)) {
            m_impl->lastError = QStringLiteral("Could not create the profile folder.");
            return false;
        }
    } else {
        root = Impl::rootFor(m_impl->currentId);
    }

    setBusy(true);
    setProgress(0, QStringLiteral("Preparing import"));
    auto progress = makeProgress(this, [this](qreal f, QString t) { if (m_impl->busy) setProgress(f, t); });

    QtConcurrent::run([path, mask, root, asNewProfile, staging, progress]() -> WorkResult {
        WorkResult r;
        try {
            if (asNewProfile) {
                QString err;
                if (!profile::initProfileRoot(root, &err)) {
                    r.error = QStringLiteral("Could not prepare the new profile.");
                    return r;
                }
            }
            const profile::ImportResult x =
                profile::importArchive(path, mask, root, asNewProfile, staging, progress);
            r.ok = x.ok;
            r.error = x.error;
            r.details.insert(QStringLiteral("added"), x.added);
            r.details.insert(QStringLiteral("skipped"), x.skipped);
            r.details.insert(QStringLiteral("warnings"), x.warnings);
        } catch (const std::exception& e) {
            qWarning() << "ProfileService::importArchive:" << e.what();
            r.error = QStringLiteral("The import failed.");
        }
        return r;
    }).then(this, [this, id, root, name, asNewProfile](WorkResult r) {
        r.details.insert(QStringLiteral("asNewProfile"), asNewProfile);
        if (asNewProfile) {
            if (r.ok) {
                const qint64 now = QDateTime::currentMSecsSinceEpoch();
                writeProfileInfo(root, id, name, now);
                QFile::remove(QDir(root).filePath(kIncompleteMarker));
                m_impl->entries.append(Impl::Entry{ id, name, now, 0 });
                m_impl->save();
                emit profilesChanged();
                r.details.insert(QStringLiteral("id"), id);
                r.details.insert(QStringLiteral("name"), name);
            } else if (isDeletableProfileDir(root)
                       && QFile::exists(QDir(root).filePath(kIncompleteMarker))) {
                // Only ever the folder made for this import, still marked.
                QDir(root).removeRecursively();
            }
        }
        setBusy(false);
        emit operationFinished(QStringLiteral("import"), r.ok, r.error, r.details);
    });
    return true;
}

QString ProfileService::suggestedExportName() const
{
    QString base = currentProfileName();
    base.replace(QRegularExpression(QStringLiteral("[<>:\"/\\\\|?*\\x00-\\x1F]")), QStringLiteral(" "));
    base = base.simplified();
    if (base.isEmpty()) base = QStringLiteral("Crater profile");
    return base + QStringLiteral(".craterprofile");
}

}  // namespace crater
