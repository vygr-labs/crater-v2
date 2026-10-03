#include "profile/ProfileArchive.h"

#include "profile/ProfileSettings.h"

#include "bundle/Zip.h"
#include "crater/FontService.h"
#include "crater/LyricsDSL.h"
#include "crater/MediaService.h"
#include "crater/ThemeService.h"
#include "crater/Version.h"
#include "db/Connection.h"
#include "db/DbPaths.h"
#include "db/Error.h"
#include "db/Migrator.h"
#include "db/Statement.h"
#include "db/Transaction.h"

#include <QCryptographicHash>
#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonValue>
#include <QRegularExpression>
#include <QSet>
#include <QStorageInfo>
#include <QUuid>

#include <optional>

namespace crater::profile {

namespace {

// ─── Archive layout ─────────────────────────────────────────────────────
//
//   manifest.json          kind, formatVersion, parts, counts, schema
//                          versions, and the media / font file index
//   settings.json          per-profile preferences (Settings part)
//   db/app.sqlite          themes, fonts, media rows, presentations,
//                          schedules (filtered to the chosen parts)
//   db/songs.sqlite        songs, sections, collections
//   db/bibles.sqlite       installed Bibles
//   media/<sha256>.<ext>   content-addressed media files
//   fonts/<sha256>.<ext>   content-addressed font files
//
// Rows in the archived app.sqlite point at their files through the
// manifest index (by row id), never through a path: a path from another
// machine means nothing here, and an archive must not be able to name one.

constexpr const char* kKind = "craterprofile";

const QString kManifest   = QStringLiteral("manifest.json");
const QString kSettings   = QStringLiteral("settings.json");
const QString kAppDb      = QStringLiteral("db/app.sqlite");
const QString kSongsDb    = QStringLiteral("db/songs.sqlite");
const QString kBiblesDb   = QStringLiteral("db/bibles.sqlite");

// Size caps (§5.1). Media matches MediaService's own import cap so an
// archive cannot carry a file the normal import path would refuse.
constexpr qint64 kMaxManifestBytes = qint64(16) * 1024 * 1024;
constexpr qint64 kMaxSettingsBytes = qint64(1) * 1024 * 1024;
constexpr qint64 kMaxDbBytes       = qint64(8) * 1024 * 1024 * 1024;
constexpr qint64 kMaxMediaBytes    = qint64(4) * 1024 * 1024 * 1024;
constexpr qint64 kMaxFontBytes     = qint64(64) * 1024 * 1024;

const QRegularExpression& mediaEntryRe()
{
    static const QRegularExpression re(QStringLiteral("^media/([0-9a-f]{64})(\\.[a-z0-9]{1,8})?$"));
    return re;
}

const QRegularExpression& fontEntryRe()
{
    static const QRegularExpression re(QStringLiteral("^fonts/([0-9a-f]{64})(\\.[a-z0-9]{1,8})?$"));
    return re;
}

constexpr unsigned kAppParts = PartThemes | PartMedia | PartPresentations | PartSchedules;

struct PartName { unsigned part; const char* key; };
const PartName kPartNames[] = {
    { PartThemes,        "themes"        },
    { PartMedia,         "media"         },
    { PartPresentations, "presentations" },
    { PartScriptures,    "scriptures"    },
    { PartSongs,         "songs"         },
    { PartSchedules,     "schedules"     },
    { PartSettings,      "settings"      },
};

// ─── Small helpers ──────────────────────────────────────────────────────

// Removes a folder tree when it goes out of scope, so every early return
// cleans its staging area. Refuses to act on an empty path.
struct ScopedDir
{
    QString path;
    explicit ScopedDir(QString p) : path(std::move(p)) { QDir().mkpath(path); }
    ~ScopedDir() { if (!path.isEmpty()) QDir(path).removeRecursively(); }
    ScopedDir(const ScopedDir&) = delete;
    ScopedDir& operator=(const ScopedDir&) = delete;
    QString file(const QString& name) const { return QDir(path).filePath(name); }
};

QString newStagingDir(const QString& parent)
{
    return QDir(parent).filePath(QUuid::createUuid().toString(QUuid::WithoutBraces));
}

// Streams a file through SHA-256. Empty on read failure.
QString sha256File(const QString& path, qint64* outSize = nullptr)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return {};
    QCryptographicHash h(QCryptographicHash::Sha256);
    if (!h.addData(&f)) return {};
    if (outSize) *outSize = f.size();
    return QString::fromLatin1(h.result().toHex());
}

QString sha256Text(const QString& s)
{
    return QString::fromLatin1(QCryptographicHash::hash(s.toUtf8(),
                                                        QCryptographicHash::Sha256).toHex());
}

// Lower-case extension safe for an archive entry name, or empty.
QString safeExt(const QString& fileName)
{
    const QString ext = QFileInfo(fileName).suffix().toLower();
    static const QRegularExpression re(QStringLiteral("^[a-z0-9]{1,8}$"));
    return re.match(ext).hasMatch() ? ext : QString();
}

// A file name from an archive turned into something safe to create inside
// a managed folder: the leaf name only, no characters Windows refuses, no
// leading dots, bounded length. Falls back to `fallback` when nothing
// usable is left.
QString sanitizeFileName(const QString& raw, const QString& fallback)
{
    QString name = QFileInfo(raw).fileName();
    static const QRegularExpression bad(QStringLiteral("[<>:\"/\\\\|?*\\x00-\\x1F]"));
    name.replace(bad, QStringLiteral("_"));
    while (name.startsWith(QLatin1Char('.')) || name.startsWith(QLatin1Char(' ')))
        name.remove(0, 1);
    while (name.endsWith(QLatin1Char('.')) || name.endsWith(QLatin1Char(' ')))
        name.chop(1);
    if (name.size() > 120) {
        const QString ext = QFileInfo(name).suffix().left(8);
        name = name.left(110) + (ext.isEmpty() ? QString() : QStringLiteral(".") + ext);
    }
    return name.isEmpty() ? fallback : name;
}

// Collision-free destination inside `dir`, keeping the base name and adding
// "-N" before the extension, the same convention MediaService uses.
QString pickDestination(const QString& dir, const QString& fileName)
{
    const QFileInfo fi(fileName);
    const QString stem = fi.completeBaseName();
    const QString ext  = fi.suffix();
    QDir d(dir);
    QString candidate = fileName;
    for (int n = 1; d.exists(candidate) && n < 100000; ++n) {
        candidate = ext.isEmpty() ? QStringLiteral("%1-%2").arg(stem).arg(n)
                                  : QStringLiteral("%1-%2.%3").arg(stem).arg(n).arg(ext);
    }
    return QDir::cleanPath(d.absoluteFilePath(candidate));
}

// True when `path` is directly inside `dir` (§5.1 path confinement).
bool isInside(const QString& path, const QString& dir)
{
    const QString p = QDir::cleanPath(QFileInfo(path).absoluteFilePath());
    const QString d = QDir::cleanPath(QDir(dir).absolutePath());
    return QDir::cleanPath(QFileInfo(p).absolutePath()) == d;
}

// Move a staged file into place. Same volume in practice (staging lives
// under the app data root), so this is a rename; a copy is the fallback.
bool moveInto(const QString& from, const QString& to)
{
    if (QFile::rename(from, to)) return true;
    if (!QFile::copy(from, to)) return false;
    QFile::remove(from);
    return true;
}

// Consistent snapshot of a live database into a new file. VACUUM INTO reads
// one transaction's view of the source, so a running Crater can keep writing
// while this runs, and the source file is never modified.
void vacuumInto(const QString& srcDb, const QString& dest)
{
    QFile::remove(dest);
    db::Connection src(srcDb, db::OpenMode::ReadOnly, QStringLiteral("ProfileSnapshot"));
    auto st = src.prepare(QStringLiteral("VACUUM INTO ?"));
    st.bind(1, dest);
    st.step();
}

// Leave a snapshot as one self-contained file: compact it and switch it out
// of WAL (Connection turns WAL on for every read-write open).
void finalizeSnapshot(db::Connection& c)
{
    c.exec(QStringLiteral("VACUUM"));
    c.exec(QStringLiteral("PRAGMA journal_mode = DELETE"));
}

qint64 countRows(db::Connection& c, const QString& sql)
{
    auto st = c.prepare(sql);
    const qint64 n = st.step() ? st.columnInt64(0) : 0;
    st.reset();
    return n;
}

// Rewrites every numeric "mediaId" in a JSON tree through `map`. A miss
// becomes null (theme tokens, matching the bundle importer's convention for
// a reference it cannot satisfy) or 0 (slides and schedule items, where 0 is
// the "no picture" value).
QJsonValue remapMediaIds(const QJsonValue& v, const QHash<qint64, qint64>& map, bool nullOnMiss)
{
    if (v.isArray()) {
        QJsonArray out;
        for (const QJsonValue& e : v.toArray()) out.append(remapMediaIds(e, map, nullOnMiss));
        return out;
    }
    if (!v.isObject()) return v;
    QJsonObject o = v.toObject();
    for (auto it = o.begin(); it != o.end(); ++it) {
        if (it.key() == QLatin1String("mediaId")) {
            const qint64 id = it.value().toVariant().toLongLong();
            if (id <= 0) continue;
            const auto hit = map.constFind(id);
            if (hit != map.constEnd()) *it = QJsonValue(hit.value());
            else *it = nullOnMiss ? QJsonValue(QJsonValue::Null) : QJsonValue(0);
        } else if (it.value().isObject() || it.value().isArray()) {
            *it = remapMediaIds(it.value(), map, nullOnMiss);
        }
    }
    return o;
}

QString compactJson(const QJsonValue& v)
{
    const QJsonDocument doc = v.isArray() ? QJsonDocument(v.toArray()) : QJsonDocument(v.toObject());
    return QString::fromUtf8(doc.toJson(QJsonDocument::Compact));
}

// Canonical form of stored JSON text for equality checks: parsed and
// re-serialised, so whitespace and key order never make two equal designs
// look different.
QString canonicalJson(const QString& text)
{
    const QJsonDocument doc = QJsonDocument::fromJson(text.toUtf8());
    if (doc.isNull()) return text;
    return QString::fromUtf8(doc.toJson(QJsonDocument::Compact));
}

// Same normalisation and apostrophe stripping as SongService, so a song
// imported here is found by search exactly like one typed in.
QString flattenLyrics(const QStringList& linesJsonPerSection)
{
    QString lyrics;
    bool first = true;
    for (const QString& linesJson : linesJsonPerSection) {
        const QJsonDocument doc = QJsonDocument::fromJson(linesJson.toUtf8());
        if (!doc.isArray()) continue;
        for (const QJsonValue& v : doc.array()) {
            const QString plain = crater::lyrics::flattenLine(v.toString());
            if (plain.isEmpty()) continue;
            if (!first) lyrics.append(QLatin1Char(' '));
            first = false;
            lyrics.append(plain);
        }
    }
    return lyrics;
}

struct SongSection { QString kind; QString label; QString linesJson; qint64 sortOrder; };

// Identity of a song for dedupe: its title (case and surrounding space
// ignored) plus every section's kind, label and lines, in order.
QString songSignature(const QString& title, const QList<SongSection>& sections)
{
    QString s = title.trimmed().toLower();
    s += QChar(0x1D);
    for (const SongSection& sec : sections) {
        s += sec.kind + QChar(0x1F) + sec.label + QChar(0x1F) + canonicalJson(sec.linesJson);
        s += QChar(0x1E);
    }
    return sha256Text(s);
}

QHash<qint64, QList<SongSection>> loadSections(db::Connection& c)
{
    QHash<qint64, QList<SongSection>> out;
    auto st = c.prepare(QStringLiteral(
        "SELECT song_id, kind, COALESCE(label, ''), lines_json, sort_order "
        "FROM song_sections ORDER BY song_id, sort_order, id"));
    while (st.step()) {
        out[st.columnInt64(0)].append(SongSection{
            st.columnText(1), st.columnText(2), st.columnText(3), st.columnInt64(4) });
    }
    return out;
}

// ─── Staged database checks ─────────────────────────────────────────────

// A database from an archive is untrusted input (§5.3). Before any row is
// read: confirm it is SQLite, run SQLite's own consistency check, drop any
// trigger or view (our schemas have none, and either could make a read or
// a migration run code the file supplied), refuse a schema newer than this
// build, then migrate it to the current schema. All on the staged copy.
std::optional<QString> vetStagedDb(const QString& path, const QString& dbName)
{
    {
        QFile f(path);
        if (!f.open(QIODevice::ReadOnly)) return QStringLiteral("cannot read the archived %1 data").arg(dbName);
        const QByteArray head = f.read(16);
        if (head != QByteArray("SQLite format 3\0", 16))
            return QStringLiteral("the archived %1 data is not a database").arg(dbName);
    }
    try {
        db::Connection c(path, db::OpenMode::ReadWrite, QStringLiteral("ProfileImport-vet"));
        c.exec(QStringLiteral("PRAGMA trusted_schema = OFF"));
        {
            auto qc = c.prepare(QStringLiteral("PRAGMA quick_check"));
            const QString verdict = qc.step() ? qc.columnText(0) : QString();
            qc.reset();
            if (verdict != QLatin1String("ok"))
                return QStringLiteral("the archived %1 data is damaged").arg(dbName);
        }
        QStringList drops;
        {
            auto st = c.prepare(QStringLiteral(
                "SELECT type, name FROM sqlite_master WHERE type IN ('trigger', 'view')"));
            while (st.step()) {
                QString name = st.columnText(1);
                name.replace(QLatin1Char('"'), QStringLiteral("\"\""));
                drops.append(QStringLiteral("DROP %1 IF EXISTS \"%2\"")
                                 .arg(st.columnText(0).toUpper(), name));
            }
        }
        for (const QString& d : drops) c.exec(d);
        db::Migrator::run(c, dbName);
    } catch (const db::Error& e) {
        const QString msg = e.message();
        if (msg.contains(QLatin1String("newer"), Qt::CaseInsensitive)
            || msg.contains(QLatin1String("downgrad"), Qt::CaseInsensitive))
            return QStringLiteral("this archive was made by a newer version of Crater. Update Crater and try again");
        qWarning().noquote() << "ProfileArchive: staged" << dbName << "rejected:" << msg;
        return QStringLiteral("the archived %1 data could not be read").arg(dbName);
    }
    return std::nullopt;
}

}  // namespace

// ═══════════════════════════════════════════════════════════════════════
// Parts
// ═══════════════════════════════════════════════════════════════════════

QStringList partKeys()
{
    QStringList out;
    for (const PartName& p : kPartNames) out.append(QString::fromLatin1(p.key));
    return out;
}

unsigned partForKey(QStringView key)
{
    for (const PartName& p : kPartNames)
        if (key == QLatin1String(p.key)) return p.part;
    return 0;
}

unsigned partsFromMap(const QVariantMap& map)
{
    unsigned out = 0;
    for (auto it = map.constBegin(); it != map.constEnd(); ++it)
        if (it.value().toBool()) out |= partForKey(it.key());
    return out;
}

QVariantMap partsToMap(unsigned parts)
{
    QVariantMap out;
    for (const PartName& p : kPartNames)
        out.insert(QString::fromLatin1(p.key), (parts & p.part) != 0);
    return out;
}

// ═══════════════════════════════════════════════════════════════════════
// Profile roots
// ═══════════════════════════════════════════════════════════════════════

bool initProfileRoot(const QString& root, QString* error)
{
    QDir d(root);
    if (!d.mkpath(QStringLiteral("."))
        || !QDir().mkpath(db::DbPaths::mediaDirIn(root))
        || !QDir().mkpath(db::DbPaths::fontsDirIn(root))) {
        if (error) *error = QStringLiteral("could not create the profile folder");
        return false;
    }
    try {
        {
            db::Connection c(db::DbPaths::biblesDbPathIn(root), db::OpenMode::ReadWriteCreate,
                             QStringLiteral("Migrator-bibles"));
            db::Migrator::run(c, QStringLiteral("bibles"));
        }
        {
            db::Connection c(db::DbPaths::songsDbPathIn(root), db::OpenMode::ReadWriteCreate,
                             QStringLiteral("Migrator-songs"));
            db::Migrator::run(c, QStringLiteral("songs"));
        }
        {
            db::Connection c(db::DbPaths::appDbPathIn(root), db::OpenMode::ReadWriteCreate,
                             QStringLiteral("Migrator-app"));
            db::Migrator::run(c, QStringLiteral("app"));
        }
    } catch (const db::Error& e) {
        qWarning().noquote() << "ProfileArchive::initProfileRoot:" << e.message();
        if (error) *error = QStringLiteral("could not prepare the profile databases");
        return false;
    }
    return true;
}

bool duplicateProfileData(const QString& sourceRoot, const QString& destRoot,
                          const ProgressFn& progress, QString* error)
{
    const auto report = [&](double f, const QString& s) { if (progress) progress(f, s); };
    const auto fail = [&](const QString& why) {
        if (error) *error = why;
        return false;
    };

    if (!QDir().mkpath(destRoot)) return fail(QStringLiteral("could not create the profile folder"));

    // 1. Databases, snapshotted so the running profile is never paused.
    report(0.02, QStringLiteral("Copying libraries"));
    try {
        const QList<QPair<QString, QString>> dbs{
            { db::DbPaths::appDbPathIn(sourceRoot),    db::DbPaths::appDbPathIn(destRoot) },
            { db::DbPaths::songsDbPathIn(sourceRoot),  db::DbPaths::songsDbPathIn(destRoot) },
            { db::DbPaths::biblesDbPathIn(sourceRoot), db::DbPaths::biblesDbPathIn(destRoot) },
        };
        for (const auto& [from, to] : dbs) {
            if (QFile::exists(from)) vacuumInto(from, to);
        }
    } catch (const db::Error& e) {
        qWarning().noquote() << "duplicateProfileData: snapshot failed:" << e.message();
        return fail(QStringLiteral("could not copy the libraries"));
    }

    // 2. Managed files. Listed explicitly: the Default profile's root also
    //    holds the other profiles, logs and translations, none of which
    //    belong in a copy.
    const QStringList dirs{ QStringLiteral("media"), QStringLiteral("fonts"),
                            QStringLiteral("schedules") };
    qint64 total = 0;
    QList<QPair<QString, QString>> files;
    for (const QString& dir : dirs) {
        const QString from = QDir(sourceRoot).filePath(dir);
        if (!QFileInfo(from).isDir()) continue;
        QDirIterator it(from, QDir::Files | QDir::Hidden | QDir::NoDotAndDotDot,
                        QDirIterator::Subdirectories);
        while (it.hasNext()) {
            const QString f = it.next();
            const QString rel = QDir(sourceRoot).relativeFilePath(f);
            files.append({ f, QDir(destRoot).filePath(rel) });
            total += QFileInfo(f).size();
        }
    }
    qint64 done = 0;
    for (const auto& [from, to] : files) {
        QDir().mkpath(QFileInfo(to).absolutePath());
        if (!QFile::exists(to) && !QFile::copy(from, to))
            return fail(QStringLiteral("could not copy %1").arg(QFileInfo(from).fileName()));
        done += QFileInfo(from).size();
        report(0.1 + 0.8 * (total > 0 ? double(done) / double(total) : 1.0),
               QStringLiteral("Copying media"));
    }
    const QString sentinel = db::DbPaths::importSentinelPathIn(sourceRoot);
    if (QFile::exists(sentinel))
        QFile::copy(sentinel, db::DbPaths::importSentinelPathIn(destRoot));

    // 3. Make sure the copy is at the current schema (a no-op normally).
    report(0.92, QStringLiteral("Finishing"));
    QString initError;
    if (!initProfileRoot(destRoot, &initError)) return fail(initError);

    // 4. Rebase stored paths onto the copy's own folders. Without this a
    //    row whose file failed to copy would still name the SOURCE
    //    profile's file, and deleting that item here would delete it there.
    try {
        db::Connection c(db::DbPaths::appDbPathIn(destRoot), db::OpenMode::ReadWrite,
                         QStringLiteral("ProfileDuplicate"));
        db::Transaction tx(c);
        const QString mediaDir = db::DbPaths::mediaDirIn(destRoot);
        const QString fontsDir = db::DbPaths::fontsDirIn(destRoot);
        const auto rebase = [&](const QString& table, const QString& dir) {
            QList<QPair<qint64, QString>> rows;
            auto sel = c.prepare(QStringLiteral("SELECT id, path FROM %1").arg(table));
            while (sel.step()) rows.append({ sel.columnInt64(0), sel.columnText(1) });
            auto upd = c.prepare(QStringLiteral("UPDATE %1 SET path = ? WHERE id = ?").arg(table));
            for (const auto& [id, path] : rows) {
                const QString name = QFileInfo(path).fileName();
                if (name.isEmpty()) continue;
                upd.reset();
                upd.bind(1, QDir::cleanPath(QDir(dir).filePath(name)));
                upd.bind(2, id);
                upd.step();
            }
        };
        rebase(QStringLiteral("media"), mediaDir);
        rebase(QStringLiteral("user_fonts"), fontsDir);
        // The logo background is a media file path kept in kv.
        {
            auto sel = c.prepare(QStringLiteral(
                "SELECT value FROM kv WHERE key = 'projection.logoBgPath'"));
            const QString logo = sel.step() ? sel.columnText(0) : QString();
            sel.reset();
            if (!logo.isEmpty() && !QFileInfo(logo).fileName().isEmpty()) {
                auto upd = c.prepare(QStringLiteral(
                    "UPDATE kv SET value = ? WHERE key = 'projection.logoBgPath'"));
                upd.bind(1, QDir::cleanPath(QDir(mediaDir).filePath(QFileInfo(logo).fileName())));
                upd.step();
            }
        }
        tx.commit();
    } catch (const db::Error& e) {
        qWarning().noquote() << "duplicateProfileData: path rebase failed:" << e.message();
        return fail(QStringLiteral("could not finish copying the media library"));
    }

    // 5. Per-profile preferences and theme pins.
    copyProfileSettings(sourceRoot, destRoot);
    report(1.0, QStringLiteral("Done"));
    return true;
}

// ═══════════════════════════════════════════════════════════════════════
// Export
// ═══════════════════════════════════════════════════════════════════════

ExportResult exportArchive(const QString& sourceRoot, const QString& profileName,
                           unsigned parts, const QString& destPath,
                           const QString& stagingParent, const ProgressFn& progress)
{
    ExportResult r;
    const auto report = [&](double f, const QString& s) { if (progress) progress(f, s); };
    parts &= kAllParts;
    if (parts == 0) {
        r.error = QStringLiteral("Choose at least one thing to export.");
        return r;
    }

    ScopedDir staging(newStagingDir(stagingParent));
    struct FileEntry { QString entry; QString path; qint64 size; };
    QList<FileEntry> files;
    QSet<QString>    entryNames;
    QJsonArray       mediaIndex;
    QJsonArray       fontIndex;
    QJsonObject      counts;
    QJsonObject      schema;
    QByteArray       settingsJson;

    try {
        // ── app.sqlite: themes, fonts, media, presentations, schedules ──
        if (parts & kAppParts) {
            report(0.02, QStringLiteral("Reading themes and media"));
            const QString snap = staging.file(QStringLiteral("app.sqlite"));
            vacuumInto(db::DbPaths::appDbPathIn(sourceRoot), snap);

            db::Connection c(snap, db::OpenMode::ReadWrite, QStringLiteral("ProfileExport-app"));
            {
                db::Transaction tx(c);
                // Never part of an archive: the working schedule and every
                // kv entry except the per-kind default themes.
                c.exec(QStringLiteral("UPDATE current_schedule SET items_json = '[]'"));
                if (parts & PartThemes) {
                    c.exec(QStringLiteral(
                        "DELETE FROM kv WHERE key NOT IN ('default_song_theme_id', "
                        "'default_scripture_theme_id', 'default_presentation_theme_id')"));
                } else {
                    c.exec(QStringLiteral("DELETE FROM kv"));
                    c.exec(QStringLiteral("DELETE FROM themes"));
                    c.exec(QStringLiteral("DELETE FROM user_fonts"));
                }
                if (!(parts & PartMedia))         c.exec(QStringLiteral("DELETE FROM media"));
                if (!(parts & PartPresentations)) c.exec(QStringLiteral("DELETE FROM presentations"));
                if (!(parts & PartSchedules))     c.exec(QStringLiteral("DELETE FROM schedules"));

                // Media files: hash each one, index it by row id, and
                // replace the row's path with a reference into the archive.
                if (parts & PartMedia) {
                    const QString mediaDir = db::DbPaths::mediaDirIn(sourceRoot);
                    struct Row { qint64 id; QString path; QString title; };
                    QList<Row> rows;
                    {
                        auto st = c.prepare(QStringLiteral("SELECT id, path, title FROM media ORDER BY id"));
                        while (st.step()) rows.append({ st.columnInt64(0), st.columnText(1), st.columnText(2) });
                    }
                    auto upd = c.prepare(QStringLiteral("UPDATE media SET path = ? WHERE id = ?"));
                    auto del = c.prepare(QStringLiteral("DELETE FROM media WHERE id = ?"));
                    int n = 0;
                    for (const Row& row : rows) {
                        report(0.03 + 0.12 * double(++n) / double(qMax<qsizetype>(1, rows.size())),
                               QStringLiteral("Checking media"));
                        const QString actual = db::DbPaths::relocate(row.path, mediaDir);
                        qint64 size = 0;
                        const QString sha = QFileInfo(actual).isFile() ? sha256File(actual, &size) : QString();
                        if (sha.isEmpty()) {
                            r.warnings.append(QStringLiteral("\"%1\" is missing on disk and was left out").arg(row.title));
                            del.reset(); del.bind(1, row.id); del.step();
                            continue;
                        }
                        const QString ext = safeExt(actual);
                        const QString entry = QStringLiteral("media/") + sha
                                            + (ext.isEmpty() ? QString() : QStringLiteral(".") + ext);
                        if (!entryNames.contains(entry)) {
                            entryNames.insert(entry);
                            files.append({ entry, actual, size });
                        }
                        mediaIndex.append(QJsonObject{
                            { QStringLiteral("id"),     row.id },
                            { QStringLiteral("entry"),  entry },
                            { QStringLiteral("name"),   QFileInfo(actual).fileName() },
                            { QStringLiteral("bytes"),  size },
                            { QStringLiteral("sha256"), sha },
                        });
                        upd.reset();
                        upd.bind(1, QStringLiteral("crater-archive:media/%1").arg(row.id));
                        upd.bind(2, row.id);
                        upd.step();
                    }
                }

                // Schedule items snapshot the absolute path of their media
                // file. It means nothing on another machine (the import
                // rebuilds it from the media id) and it would carry this
                // computer's user folder into the file, so blank it.
                if (parts & PartSchedules) {
                    std::function<QJsonValue(const QJsonValue&)> strip = [&](const QJsonValue& v) -> QJsonValue {
                        if (v.isArray()) {
                            QJsonArray out;
                            for (const QJsonValue& e : v.toArray()) out.append(strip(e));
                            return out;
                        }
                        if (!v.isObject()) return v;
                        QJsonObject o = v.toObject();
                        for (auto it = o.begin(); it != o.end(); ++it) {
                            if (it.key() == QLatin1String("mediaPath")) *it = QString();
                            else if (it.value().isArray() || it.value().isObject()) *it = strip(it.value());
                        }
                        return o;
                    };
                    QList<QPair<qint64, QString>> rows;
                    {
                        auto st = c.prepare(QStringLiteral("SELECT id, items_json FROM schedules"));
                        while (st.step()) rows.append({ st.columnInt64(0), st.columnText(1) });
                    }
                    auto upd = c.prepare(QStringLiteral("UPDATE schedules SET items_json = ? WHERE id = ?"));
                    for (const auto& [id, json] : rows) {
                        const QJsonDocument doc = QJsonDocument::fromJson(json.toUtf8());
                        if (!doc.isArray()) continue;
                        upd.reset();
                        upd.bind(1, compactJson(strip(doc.array())));
                        upd.bind(2, id);
                        upd.step();
                    }
                }

                // Fonts travel with themes.
                if (parts & PartThemes) {
                    const QString fontsDir = db::DbPaths::fontsDirIn(sourceRoot);
                    struct Row { qint64 id; QString path; QString family; };
                    QList<Row> rows;
                    {
                        auto st = c.prepare(QStringLiteral("SELECT id, path, family FROM user_fonts ORDER BY id"));
                        while (st.step()) rows.append({ st.columnInt64(0), st.columnText(1), st.columnText(2) });
                    }
                    auto upd = c.prepare(QStringLiteral("UPDATE user_fonts SET path = ? WHERE id = ?"));
                    auto del = c.prepare(QStringLiteral("DELETE FROM user_fonts WHERE id = ?"));
                    for (const Row& row : rows) {
                        const QString actual = db::DbPaths::relocate(row.path, fontsDir);
                        qint64 size = 0;
                        const QString sha = QFileInfo(actual).isFile() ? sha256File(actual, &size) : QString();
                        if (sha.isEmpty()) {
                            r.warnings.append(QStringLiteral("Font \"%1\" is missing on disk and was left out").arg(row.family));
                            del.reset(); del.bind(1, row.id); del.step();
                            continue;
                        }
                        const QString ext = safeExt(actual);
                        const QString entry = QStringLiteral("fonts/") + sha
                                            + (ext.isEmpty() ? QString() : QStringLiteral(".") + ext);
                        if (!entryNames.contains(entry)) {
                            entryNames.insert(entry);
                            files.append({ entry, actual, size });
                        }
                        fontIndex.append(QJsonObject{
                            { QStringLiteral("id"),     row.id },
                            { QStringLiteral("entry"),  entry },
                            { QStringLiteral("family"), row.family },
                            { QStringLiteral("bytes"),  size },
                            { QStringLiteral("sha256"), sha },
                        });
                        upd.reset();
                        upd.bind(1, QStringLiteral("crater-archive:fonts/%1").arg(row.id));
                        upd.bind(2, row.id);
                        upd.step();
                    }
                }
                tx.commit();
            }

            if (parts & PartThemes) {
                counts.insert(QStringLiteral("themes"),
                              countRows(c, QStringLiteral("SELECT count(*) FROM themes WHERE is_builtin = 0")));
                counts.insert(QStringLiteral("fonts"),
                              countRows(c, QStringLiteral("SELECT count(*) FROM user_fonts")));
            }
            if (parts & PartMedia)
                counts.insert(QStringLiteral("media"), countRows(c, QStringLiteral("SELECT count(*) FROM media")));
            if (parts & PartPresentations)
                counts.insert(QStringLiteral("presentations"),
                              countRows(c, QStringLiteral("SELECT count(*) FROM presentations")));
            if (parts & PartSchedules)
                counts.insert(QStringLiteral("schedules"),
                              countRows(c, QStringLiteral("SELECT count(*) FROM schedules")));
            schema.insert(QStringLiteral("app"), c.userVersion());
            finalizeSnapshot(c);
            files.prepend({ kAppDb, snap, 0 });
        }

        // ── songs.sqlite ────────────────────────────────────────────────
        if (parts & PartSongs) {
            report(0.16, QStringLiteral("Reading songs"));
            const QString snap = staging.file(QStringLiteral("songs.sqlite"));
            vacuumInto(db::DbPaths::songsDbPathIn(sourceRoot), snap);
            db::Connection c(snap, db::OpenMode::ReadWrite, QStringLiteral("ProfileExport-songs"));
            // A theme id only means something with the themes alongside it.
            if (!(parts & PartThemes)) c.exec(QStringLiteral("UPDATE songs SET theme_id = NULL"));
            // The search index is rebuilt on import; shipping it only adds size.
            c.exec(QStringLiteral("INSERT INTO songs_fts(songs_fts) VALUES('delete-all')"));
            counts.insert(QStringLiteral("songs"), countRows(c, QStringLiteral("SELECT count(*) FROM songs")));
            counts.insert(QStringLiteral("collections"),
                          countRows(c, QStringLiteral("SELECT count(*) FROM collections")));
            schema.insert(QStringLiteral("songs"), c.userVersion());
            finalizeSnapshot(c);
            files.append({ kSongsDb, snap, 0 });
        }

        // ── bibles.sqlite ───────────────────────────────────────────────
        if (parts & PartScriptures) {
            report(0.2, QStringLiteral("Reading Bibles"));
            const QString snap = staging.file(QStringLiteral("bibles.sqlite"));
            vacuumInto(db::DbPaths::biblesDbPathIn(sourceRoot), snap);
            db::Connection c(snap, db::OpenMode::ReadWrite, QStringLiteral("ProfileExport-bibles"));
            c.exec(QStringLiteral("INSERT INTO verses_fts(verses_fts) VALUES('delete-all')"));
            counts.insert(QStringLiteral("scriptures"),
                          countRows(c, QStringLiteral("SELECT count(*) FROM translations")));
            schema.insert(QStringLiteral("bibles"), c.userVersion());
            finalizeSnapshot(c);
            files.append({ kBiblesDb, snap, 0 });
        }
    } catch (const db::Error& e) {
        qWarning().noquote() << "ProfileArchive::exportArchive:" << e.message();
        r.error = QStringLiteral("Could not read this profile's libraries.");
        return r;
    }

    if (parts & PartSettings) {
        const QVariantMap prefs = readProfilePreferences(sourceRoot);
        settingsJson = QJsonDocument(QJsonObject::fromVariantMap(prefs)).toJson(QJsonDocument::Indented);
        counts.insert(QStringLiteral("settings"), qint64(prefs.size()));
    }

    // Sizes of the snapshots, now that they are final.
    qint64 totalBytes = 0;
    for (FileEntry& f : files) {
        if (f.size == 0) f.size = QFileInfo(f.path).size();
        totalBytes += f.size;
    }

    QJsonArray partList;
    for (const PartName& p : kPartNames)
        if (parts & p.part) partList.append(QString::fromLatin1(p.key));

    const QJsonObject manifest{
        { QStringLiteral("kind"),          QString::fromLatin1(kKind) },
        { QStringLiteral("formatVersion"), kArchiveFormatVersion },
        { QStringLiteral("appVersion"),    crater::versionString() },
        { QStringLiteral("exportedAt"),    QDateTime::currentMSecsSinceEpoch() },
        { QStringLiteral("profileName"),   profileName },
        { QStringLiteral("parts"),         partList },
        { QStringLiteral("counts"),        counts },
        { QStringLiteral("schema"),        schema },
        { QStringLiteral("media"),         mediaIndex },
        { QStringLiteral("fonts"),         fontIndex },
    };

    // Free space for the archive itself. QSaveFile writes beside the target.
    {
        const QStorageInfo vol(QFileInfo(destPath).absolutePath());
        if (vol.isValid() && vol.bytesAvailable() >= 0
            && vol.bytesAvailable() < totalBytes + qint64(16) * 1024 * 1024) {
            r.error = QStringLiteral("There is not enough free space for this export.");
            return r;
        }
    }

    bundle::ZipWriter zip(destPath);
    if (!zip.isOpen()) {
        r.error = QStringLiteral("Could not create the file. Check the folder is writable.");
        qWarning().noquote() << zip.errorString();
        return r;
    }
    const auto zipFail = [&]() {
        qWarning().noquote() << "ProfileArchive::exportArchive:" << zip.errorString();
        r.error = QStringLiteral("Writing the archive failed. Check there is enough free space.");
        return r;
    };
    if (!zip.addEntry(kManifest, QJsonDocument(manifest).toJson(QJsonDocument::Indented)))
        return zipFail();
    if ((parts & PartSettings) && !zip.addEntry(kSettings, settingsJson))
        return zipFail();

    qint64 written = 0;
    for (const FileEntry& f : files) {
        const qint64 base = written;
        const auto onChunk = [&](qint64 done) {
            report(0.25 + 0.74 * (totalBytes > 0 ? double(base + done) / double(totalBytes) : 1.0),
                   QStringLiteral("Writing archive"));
            return true;
        };
        if (!zip.addFile(f.entry, f.path, onChunk)) return zipFail();
        written += f.size;
    }
    if (!zip.commit()) return zipFail();

    r.ok = true;
    r.counts = counts.toVariantMap();
    report(1.0, QStringLiteral("Done"));
    qInfo().noquote() << "ProfileArchive: exported" << partList.size() << "parts,"
                      << files.size() << "files," << totalBytes << "bytes to" << destPath;
    return r;
}

// ═══════════════════════════════════════════════════════════════════════
// Inspect
// ═══════════════════════════════════════════════════════════════════════

ArchiveInfo inspectArchive(const QString& archivePath)
{
    ArchiveInfo info;
    const auto fail = [&](const QString& why) {
        info.ok = false;
        info.error = why;
        return info;
    };

    {
        QFile probe(archivePath);
        if (!probe.open(QIODevice::ReadOnly))
            return fail(QStringLiteral("The file could not be opened."));
        const QByteArray head = probe.read(4);
        if (head != QByteArray("PK\x03\x04", 4))
            return fail(QStringLiteral("This is not a Crater profile file."));
    }

    bundle::ZipReader zip(archivePath);
    if (!zip.isOpen()) return fail(QStringLiteral("This file is damaged or is not a Crater profile file."));
    if (zip.hasDuplicateNames()) return fail(QStringLiteral("This profile file is damaged."));

    // Allow-list every entry name (§5.1 path traversal): fixed names plus
    // content-addressed media/fonts. Anything else, including any "..",
    // absolute path or backslash, refuses the whole archive.
    for (const QString& name : zip.entryNames()) {
        const bool known = name == kManifest || name == kSettings || name == kAppDb
                        || name == kSongsDb || name == kBiblesDb
                        || mediaEntryRe().match(name).hasMatch()
                        || fontEntryRe().match(name).hasMatch();
        if (!known) return fail(QStringLiteral("This profile file contains unexpected content and was not opened."));
        const qint64 size = zip.entrySize(name);
        const qint64 cap = name == kManifest ? kMaxManifestBytes
                         : name == kSettings ? kMaxSettingsBytes
                         : name.startsWith(QLatin1String("db/")) ? kMaxDbBytes
                         : name.startsWith(QLatin1String("fonts/")) ? kMaxFontBytes
                         : kMaxMediaBytes;
        if (size < 0 || size > cap)
            return fail(QStringLiteral("A file inside this profile is larger than Crater allows."));
        info.totalBytes += size;
    }

    if (!zip.hasEntry(kManifest)) return fail(QStringLiteral("This is not a Crater profile file."));
    QJsonParseError pe{};
    const QJsonDocument doc = QJsonDocument::fromJson(zip.readEntry(kManifest), &pe);
    if (pe.error != QJsonParseError::NoError || !doc.isObject())
        return fail(QStringLiteral("This profile file is damaged."));
    const QJsonObject m = doc.object();
    if (m.value(QStringLiteral("kind")).toString() != QLatin1String(kKind))
        return fail(QStringLiteral("This is not a Crater profile file."));
    const int version = m.value(QStringLiteral("formatVersion")).toInt();
    if (version > kArchiveFormatVersion)
        return fail(QStringLiteral("This profile was exported by a newer version of Crater. Update Crater to import it."));
    if (version < 1) return fail(QStringLiteral("This profile file is damaged."));

    // Every media and font index entry must name an entry that exists, with
    // the size it claims and a hash matching its content-addressed name.
    const auto checkIndex = [&](const QString& key, const QRegularExpression& re) -> bool {
        for (const QJsonValue& v : m.value(key).toArray()) {
            const QJsonObject o = v.toObject();
            const QString entry = o.value(QStringLiteral("entry")).toString();
            const auto match = re.match(entry);
            if (!match.hasMatch() || !zip.hasEntry(entry)) return false;
            if (o.value(QStringLiteral("id")).toVariant().toLongLong() <= 0) return false;
            if (o.value(QStringLiteral("sha256")).toString() != match.captured(1)) return false;
            if (o.value(QStringLiteral("bytes")).toVariant().toLongLong() != zip.entrySize(entry)) return false;
        }
        return true;
    };
    if (!checkIndex(QStringLiteral("media"), mediaEntryRe())
        || !checkIndex(QStringLiteral("fonts"), fontEntryRe()))
        return fail(QStringLiteral("This profile file is damaged."));

    // A part counts only when the manifest lists it AND its data is there.
    unsigned listed = 0;
    for (const QJsonValue& v : m.value(QStringLiteral("parts")).toArray())
        listed |= partForKey(v.toString());
    unsigned present = 0;
    if (zip.hasEntry(kAppDb))    present |= kAppParts;
    if (zip.hasEntry(kSongsDb))  present |= PartSongs;
    if (zip.hasEntry(kBiblesDb)) present |= PartScriptures;
    if (zip.hasEntry(kSettings)) present |= PartSettings;

    info.ok          = true;
    info.manifest    = m;
    info.parts       = listed & present;
    info.profileName = m.value(QStringLiteral("profileName")).toString().left(200);
    info.appVersion  = m.value(QStringLiteral("appVersion")).toString().left(40);
    info.exportedAt  = m.value(QStringLiteral("exportedAt")).toVariant().toLongLong();
    const QJsonObject counts = m.value(QStringLiteral("counts")).toObject();
    for (auto it = counts.constBegin(); it != counts.constEnd(); ++it)
        if (partKeys().contains(it.key()) || it.key() == QLatin1String("fonts")
            || it.key() == QLatin1String("collections"))
            info.counts.insert(it.key(), it.value().toVariant().toLongLong());
    if (info.parts == 0) return fail(QStringLiteral("This profile file has nothing Crater can import."));
    return info;
}

// ═══════════════════════════════════════════════════════════════════════
// Import
// ═══════════════════════════════════════════════════════════════════════

ImportResult importArchive(const QString& archivePath, unsigned parts,
                           const QString& targetRoot, bool targetIsNew,
                           const QString& stagingParent, const ProgressFn& progress)
{
    ImportResult r;
    const auto report = [&](double f, const QString& s) { if (progress) progress(f, s); };
    const auto addCount = [](QVariantMap& m, const char* key, qint64 n) {
        if (n == 0) return;
        const QString k = QString::fromLatin1(key);
        m.insert(k, m.value(k).toLongLong() + n);
    };

    report(0.0, QStringLiteral("Checking the file"));
    const ArchiveInfo info = inspectArchive(archivePath);
    if (!info.ok) {
        r.error = info.error;
        return r;
    }
    parts &= info.parts;
    if (parts == 0) {
        r.error = QStringLiteral("Choose at least one thing to import.");
        return r;
    }

    bundle::ZipReader zip(archivePath);
    if (!zip.isOpen()) {
        r.error = QStringLiteral("The file could not be opened.");
        return r;
    }

    // Index the manifest's file lists by archived row id.
    struct FileRef { QString entry; QString name; QString sha; qint64 bytes; };
    QHash<qint64, FileRef> mediaRefs, fontRefs;
    for (const QJsonValue& v : info.manifest.value(QStringLiteral("media")).toArray()) {
        const QJsonObject o = v.toObject();
        mediaRefs.insert(o.value(QStringLiteral("id")).toVariant().toLongLong(),
                         FileRef{ o.value(QStringLiteral("entry")).toString(),
                                  o.value(QStringLiteral("name")).toString(),
                                  o.value(QStringLiteral("sha256")).toString(),
                                  o.value(QStringLiteral("bytes")).toVariant().toLongLong() });
    }
    for (const QJsonValue& v : info.manifest.value(QStringLiteral("fonts")).toArray()) {
        const QJsonObject o = v.toObject();
        fontRefs.insert(o.value(QStringLiteral("id")).toVariant().toLongLong(),
                        FileRef{ o.value(QStringLiteral("entry")).toString(),
                                 o.value(QStringLiteral("family")).toString(),
                                 o.value(QStringLiteral("sha256")).toString(),
                                 o.value(QStringLiteral("bytes")).toVariant().toLongLong() });
    }

    // Free space: staged databases plus room for them to land in the
    // target, plus every file that might be copied in.
    {
        qint64 need = qint64(64) * 1024 * 1024;
        if (parts & kAppParts)      need += 2 * zip.entrySize(kAppDb);
        if (parts & PartSongs)      need += 2 * zip.entrySize(kSongsDb);
        if (parts & PartScriptures) need += 3 * zip.entrySize(kBiblesDb);
        if (parts & PartMedia)  for (const FileRef& f : mediaRefs) need += f.bytes;
        if (parts & PartThemes) for (const FileRef& f : fontRefs)  need += f.bytes;
        const QStorageInfo vol(targetRoot);
        if (vol.isValid() && vol.bytesAvailable() >= 0 && vol.bytesAvailable() < need) {
            r.error = QStringLiteral("There is not enough free space to import this profile.");
            return r;
        }
    }

    ScopedDir staging(newStagingDir(stagingParent));

    // ── Stage + vet the databases ───────────────────────────────────────
    report(0.02, QStringLiteral("Checking the libraries"));
    QString stagedApp, stagedSongs, stagedBibles;
    const auto stageDb = [&](const QString& entry, const QString& dbName, QString* out) -> bool {
        const QString path = staging.file(dbName + QStringLiteral(".sqlite"));
        if (!zip.extractToFile(entry, path)) {
            qWarning().noquote() << "ProfileArchive: extract failed:" << zip.errorString();
            r.error = QStringLiteral("This profile file is damaged.");
            return false;
        }
        if (const auto why = vetStagedDb(path, dbName)) {
            r.error = QStringLiteral("Import stopped: %1.").arg(*why);
            return false;
        }
        *out = path;
        return true;
    };
    if ((parts & kAppParts) && !stageDb(kAppDb, QStringLiteral("app"), &stagedApp)) return r;
    if ((parts & PartSongs) && !stageDb(kSongsDb, QStringLiteral("songs"), &stagedSongs)) return r;
    if ((parts & PartScriptures) && !stageDb(kBiblesDb, QStringLiteral("bibles"), &stagedBibles)) return r;

    const QString targetMediaDir = db::DbPaths::mediaDirIn(targetRoot);
    const QString targetFontsDir = db::DbPaths::fontsDirIn(targetRoot);
    QDir().mkpath(targetMediaDir);
    QDir().mkpath(targetFontsDir);

    // Files written into the target during this import. Removed again if
    // the database transaction that would reference them fails, so a failed
    // import leaves no orphan files behind (the startup orphan sweep would
    // also catch them, but only for media).
    QStringList createdFiles;
    const auto rollbackFiles = [&]() {
        for (const QString& p : createdFiles) QFile::remove(p);
        createdFiles.clear();
    };

    QHash<qint64, qint64> mediaMap;        // archived media id  -> target id
    QHash<qint64, qint64> themeMap;        // archived theme id  -> target id
    QHash<qint64, qint64> presentationMap; // archived deck id   -> target id
    QHash<qint64, qint64> songMap;         // archived song id   -> target id
    QHash<qint64, QString> targetMediaPath; // target media id   -> stored path

    try {
        // ── Bibles first: the biggest write, and independent of the rest ─
        if (parts & PartScriptures) {
            report(0.08, QStringLiteral("Adding Bibles"));
            db::Connection src(stagedBibles, db::OpenMode::ReadOnly, QStringLiteral("ProfileImport-src"));
            db::Connection dst(db::DbPaths::biblesDbPathIn(targetRoot), db::OpenMode::ReadWrite,
                               QStringLiteral("ProfileImport-bibles"));
            QSet<QString> haveCodes;
            {
                auto st = dst.prepare(QStringLiteral("SELECT code FROM translations"));
                while (st.step()) haveCodes.insert(st.columnText(0).toUpper());
            }
            struct T { qint64 id; QString code, name, language, description; bool yearNull; qint64 year; qint64 sort; };
            QList<T> trans;
            {
                auto st = src.prepare(QStringLiteral(
                    "SELECT id, code, name, language, year, COALESCE(description, ''), sort_order "
                    "FROM translations ORDER BY sort_order, id"));
                while (st.step())
                    trans.append({ st.columnInt64(0), st.columnText(1), st.columnText(2), st.columnText(3),
                                   st.columnText(5), st.columnIsNull(4), st.columnInt64(4), st.columnInt64(6) });
            }
            int done = 0;
            for (const T& t : trans) {
                report(0.08 + 0.22 * double(done++) / double(qMax<qsizetype>(1, trans.size())),
                       QStringLiteral("Adding Bibles"));
                if (t.code.trimmed().isEmpty() || haveCodes.contains(t.code.toUpper())) {
                    addCount(r.skipped, "scriptures", 1);
                    continue;
                }
                db::Transaction tx(dst);
                auto insT = dst.prepare(QStringLiteral(
                    "INSERT INTO translations (code, name, language, year, description, sort_order) "
                    "VALUES (?, ?, ?, ?, ?, ?)"));
                insT.bind(1, t.code);
                insT.bind(2, t.name);
                insT.bind(3, t.language.isEmpty() ? QStringLiteral("en") : t.language);
                if (t.yearNull) insT.bindNull(4); else insT.bind(4, t.year);
                insT.bind(5, t.description);
                insT.bind(6, t.sort);
                insT.step();
                const qint64 newT = dst.lastInsertRowId();

                QHash<qint64, qint64> bookMap;
                auto selB = src.prepare(QStringLiteral(
                    "SELECT id, name, abbrev, testament, book_number FROM books WHERE translation_id = ?"));
                auto insB = dst.prepare(QStringLiteral(
                    "INSERT INTO books (translation_id, name, abbrev, testament, book_number) "
                    "VALUES (?, ?, ?, ?, ?)"));
                selB.bind(1, t.id);
                while (selB.step()) {
                    insB.reset();
                    insB.bind(1, newT);
                    insB.bind(2, selB.columnText(1));
                    insB.bind(3, selB.columnText(2));
                    insB.bind(4, selB.columnText(3));
                    insB.bind(5, selB.columnInt64(4));
                    insB.step();
                    bookMap.insert(selB.columnInt64(0), dst.lastInsertRowId());
                }
                auto selV = src.prepare(QStringLiteral(
                    "SELECT book_id, chapter, verse, text FROM verses WHERE translation_id = ?"));
                auto insV = dst.prepare(QStringLiteral(
                    "INSERT OR IGNORE INTO verses (translation_id, book_id, chapter, verse, text) "
                    "VALUES (?, ?, ?, ?, ?)"));
                selV.bind(1, t.id);
                while (selV.step()) {
                    const qint64 book = bookMap.value(selV.columnInt64(0), 0);
                    if (book == 0) continue;
                    insV.reset();
                    insV.bind(1, newT);
                    insV.bind(2, book);
                    insV.bind(3, selV.columnInt64(1));
                    insV.bind(4, selV.columnInt64(2));
                    insV.bind(5, selV.columnText(3));
                    insV.step();
                }
                // Same index shape and apostrophe stripping as the first-run
                // importer and BibleService::rebuildFtsIndex.
                auto fts = dst.prepare(QStringLiteral(
                    "INSERT INTO verses_fts (rowid, text, book_name, translation_code) "
                    "SELECT v.id, replace(replace(v.text, '''', ''), char(8217), ''), b.name, t.code "
                    "FROM verses v JOIN books b ON b.id = v.book_id "
                    "JOIN translations t ON t.id = v.translation_id WHERE v.translation_id = ?"));
                fts.bind(1, newT);
                fts.step();
                tx.commit();
                haveCodes.insert(t.code.toUpper());
                addCount(r.added, "scriptures", 1);
            }
        }

        // ── Files: fonts and media, staged, verified, then moved in ─────
        struct PendingFont { QString hash, family, path; qint64 addedAt; };
        struct PendingMedia {
            qint64 archiveId; QString path, title, type; bool fav; qint64 addedAt, durationMs;
            int pageCount; QString fit; double cx, cy, cw, ch; bool loop, muted;
        };
        QList<PendingFont>  pendingFonts;
        QList<PendingMedia> pendingMedia;

        std::optional<db::Connection> appSrc;
        if (parts & kAppParts)
            appSrc.emplace(stagedApp, db::OpenMode::ReadOnly, QStringLiteral("ProfileImport-src"));

        if ((parts & PartThemes) && appSrc) {
            report(0.32, QStringLiteral("Adding fonts"));
            QSet<QString> haveHashes;
            {
                db::Connection dst(db::DbPaths::appDbPathIn(targetRoot), db::OpenMode::ReadOnly,
                                   QStringLiteral("ProfileImport-read"));
                auto st = dst.prepare(QStringLiteral("SELECT hash FROM user_fonts"));
                while (st.step()) haveHashes.insert(st.columnText(0));
            }
            auto st = appSrc->prepare(QStringLiteral("SELECT id, family, added_at FROM user_fonts ORDER BY id"));
            while (st.step()) {
                const qint64 id = st.columnInt64(0);
                const QString family = st.columnText(1);
                const auto ref = fontRefs.constFind(id);
                if (ref == fontRefs.constEnd()) {
                    r.warnings.append(QStringLiteral("Font \"%1\" was not in the file").arg(family));
                    continue;
                }
                if (haveHashes.contains(ref->sha)) {
                    addCount(r.skipped, "fonts", 1);
                    continue;
                }
                const QString tmp = staging.file(QStringLiteral("font-%1").arg(id));
                if (!zip.extractToFile(ref->entry, tmp) || sha256File(tmp) != ref->sha) {
                    r.warnings.append(QStringLiteral("Font \"%1\" was damaged and was skipped").arg(family));
                    QFile::remove(tmp);
                    continue;
                }
                QByteArray head;
                {
                    QFile f(tmp);
                    if (f.open(QIODevice::ReadOnly)) head = f.read(16);
                }
                const QString ext = FontService::sniffFontExtension(head);
                if (ext.isEmpty()) {
                    r.warnings.append(QStringLiteral("Font \"%1\" is not a font file and was skipped").arg(family));
                    QFile::remove(tmp);
                    continue;
                }
                // FontService's own naming: <fontsDir>/<sha256><ext>.
                const QString dest = QDir::cleanPath(QDir(targetFontsDir).filePath(ref->sha + ext));
                if (!isInside(dest, targetFontsDir)) { QFile::remove(tmp); continue; }
                if (QFile::exists(dest)) {
                    QFile::remove(tmp);   // identical bytes already on disk (name is the hash)
                } else if (!moveInto(tmp, dest)) {
                    r.warnings.append(QStringLiteral("Font \"%1\" could not be copied").arg(family));
                    continue;
                } else {
                    createdFiles.append(dest);
                }
                pendingFonts.append({ ref->sha, family.left(200), dest, st.columnInt64(2) });
                haveHashes.insert(ref->sha);
            }
        }

        if ((parts & PartMedia) && appSrc) {
            // Existing media in the target, by size, hashed only on demand:
            // hashing a whole video library to import three pictures would
            // take minutes for nothing.
            QHash<qint64, QList<QPair<qint64, QString>>> targetBySize;
            {
                db::Connection dst(db::DbPaths::appDbPathIn(targetRoot), db::OpenMode::ReadOnly,
                                   QStringLiteral("ProfileImport-read"));
                auto st = dst.prepare(QStringLiteral("SELECT id, path FROM media"));
                while (st.step()) {
                    const QString p = db::DbPaths::relocate(st.columnText(1), targetMediaDir);
                    const QFileInfo fi(p);
                    targetMediaPath.insert(st.columnInt64(0), st.columnText(1));
                    if (fi.isFile()) targetBySize[fi.size()].append({ st.columnInt64(0), p });
                }
            }
            QHash<QString, QString> hashCache;
            const auto existingFor = [&](const FileRef& ref) -> qint64 {
                const auto it = targetBySize.constFind(ref.bytes);
                if (it == targetBySize.constEnd()) return 0;
                for (const auto& [id, path] : it.value()) {
                    auto h = hashCache.constFind(path);
                    if (h == hashCache.constEnd()) h = hashCache.insert(path, sha256File(path));
                    if (h.value() == ref.sha) return id;
                }
                return 0;
            };

            qint64 totalBytes = 0;
            for (const FileRef& f : mediaRefs) totalBytes += f.bytes;
            qint64 doneBytes = 0;

            auto st = appSrc->prepare(QStringLiteral(
                "SELECT id, title, type, is_favorite, added_at, duration_ms, page_count, "
                "fit_mode, crop_x, crop_y, crop_w, crop_h, loop_video, muted FROM media ORDER BY id"));
            while (st.step()) {
                const qint64 id = st.columnInt64(0);
                const QString title = st.columnText(1);
                const auto ref = mediaRefs.constFind(id);
                if (ref == mediaRefs.constEnd()) {
                    r.warnings.append(QStringLiteral("\"%1\" was not in the file").arg(title));
                    continue;
                }
                doneBytes += ref->bytes;
                report(0.34 + 0.4 * (totalBytes > 0 ? double(doneBytes) / double(totalBytes) : 1.0),
                       QStringLiteral("Copying media"));

                if (const qint64 existing = existingFor(*ref)) {
                    mediaMap.insert(id, existing);
                    addCount(r.skipped, "media", 1);
                    continue;
                }
                if (ref->bytes > kMaxMediaBytes) {
                    r.warnings.append(QStringLiteral("\"%1\" is larger than Crater allows and was skipped").arg(title));
                    continue;
                }
                const QString tmp = staging.file(QStringLiteral("media-%1").arg(id));
                if (!zip.extractToFile(ref->entry, tmp) || sha256File(tmp) != ref->sha) {
                    r.warnings.append(QStringLiteral("\"%1\" was damaged and was skipped").arg(title));
                    QFile::remove(tmp);
                    continue;
                }
                // §5.1: classify by magic bytes, never by the archive's word.
                const QString type = MediaService::sniffFileType(tmp);
                if (type.isEmpty()) {
                    r.warnings.append(QStringLiteral("\"%1\" is not a supported picture, video or PDF and was skipped").arg(title));
                    QFile::remove(tmp);
                    continue;
                }
                int pageCount = qMax(1, st.columnInt(6));
                if (type == QLatin1String("pdf")) {
                    pageCount = MediaService::probePdfPageCount(tmp);
                    if (pageCount <= 0) {
                        r.warnings.append(QStringLiteral("\"%1\" is a damaged or locked PDF and was skipped").arg(title));
                        QFile::remove(tmp);
                        continue;
                    }
                }
                const QString ext = safeExt(ref->entry);
                const QString fallback = ref->sha.left(16) + (ext.isEmpty() ? QString() : QStringLiteral(".") + ext);
                const QString dest = pickDestination(targetMediaDir, sanitizeFileName(ref->name, fallback));
                if (!isInside(dest, targetMediaDir) || !moveInto(tmp, dest)) {
                    r.warnings.append(QStringLiteral("\"%1\" could not be copied").arg(title));
                    QFile::remove(tmp);
                    continue;
                }
                createdFiles.append(dest);
                pendingMedia.append({ id, dest, title, type, st.columnInt(3) != 0, st.columnInt64(4),
                                      st.columnInt64(5), pageCount, st.columnText(7),
                                      st.columnDouble(8), st.columnDouble(9), st.columnDouble(10),
                                      st.columnDouble(11), st.columnInt(12) != 0, st.columnInt(13) != 0 });
            }
        }

        // ── Transaction 1 (app.sqlite): fonts, media, themes, decks ─────
        if (appSrc && (parts & (PartThemes | PartMedia | PartPresentations))) {
            report(0.76, QStringLiteral("Adding themes and media"));
            db::Connection dst(db::DbPaths::appDbPathIn(targetRoot), db::OpenMode::ReadWrite,
                               QStringLiteral("ProfileImport-app"));
            try {
                db::Transaction tx(dst);

                {
                    auto ins = dst.prepare(QStringLiteral(
                        "INSERT OR IGNORE INTO user_fonts (hash, family, path, added_at) VALUES (?, ?, ?, ?)"));
                    for (const PendingFont& f : pendingFonts) {
                        ins.reset();
                        ins.bind(1, f.hash);
                        ins.bind(2, f.family);
                        ins.bind(3, f.path);
                        ins.bind(4, f.addedAt);
                        ins.step();
                        addCount(r.added, "fonts", dst.changes());
                    }
                }
                {
                    auto ins = dst.prepare(QStringLiteral(
                        "INSERT INTO media (path, title, type, is_favorite, added_at, duration_ms, page_count, "
                        "fit_mode, crop_x, crop_y, crop_w, crop_h, loop_video, muted) "
                        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"));
                    for (const PendingMedia& m : pendingMedia) {
                        ins.reset();
                        ins.bind(1, m.path);
                        ins.bind(2, m.title.left(500));
                        ins.bind(3, m.type);
                        ins.bind(4, qint64(m.fav ? 1 : 0));
                        ins.bind(5, m.addedAt);
                        ins.bind(6, m.type == QLatin1String("video") ? qMax<qint64>(0, m.durationMs) : qint64(0));
                        ins.bind(7, qint64(m.pageCount));
                        static const QSet<QString> fits{ QStringLiteral("default"), QStringLiteral("contain"),
                                                         QStringLiteral("cover"), QStringLiteral("stretch") };
                        ins.bind(8, fits.contains(m.fit) ? m.fit : QStringLiteral("default"));
                        ins.bind(9,  qBound(0.0, m.cx, 1.0));
                        ins.bind(10, qBound(0.0, m.cy, 1.0));
                        ins.bind(11, qBound(0.0, m.cw, 1.0));
                        ins.bind(12, qBound(0.0, m.ch, 1.0));
                        ins.bind(13, qint64(m.loop ? 1 : 0));
                        ins.bind(14, qint64(m.muted ? 1 : 0));
                        ins.step();
                        const qint64 newId = dst.lastInsertRowId();
                        mediaMap.insert(m.archiveId, newId);
                        targetMediaPath.insert(newId, m.path);
                        addCount(r.added, "media", 1);
                    }
                }

                if (parts & PartThemes) {
                    struct Existing { qint64 id; QString kind, name, tokens; bool builtin; };
                    QList<Existing> have;
                    {
                        auto st = dst.prepare(QStringLiteral(
                            "SELECT id, kind, name, tokens_json, is_builtin FROM themes"));
                        while (st.step())
                            have.append({ st.columnInt64(0), st.columnText(1), st.columnText(2),
                                          canonicalJson(st.columnText(3)), st.columnInt(4) != 0 });
                    }
                    const auto nameTaken = [&](const QString& kind, const QString& name) {
                        for (const Existing& e : have)
                            if (e.kind == kind && e.name.compare(name, Qt::CaseInsensitive) == 0) return true;
                        return false;
                    };
                    auto ins = dst.prepare(QStringLiteral(
                        "INSERT INTO themes (kind, name, tokens_json, is_builtin, tokens_version, created_at, updated_at) "
                        "VALUES (?, ?, ?, 0, ?, ?, ?)"));
                    auto st = appSrc->prepare(QStringLiteral(
                        "SELECT id, kind, name, tokens_json, is_builtin, tokens_version, created_at, updated_at "
                        "FROM themes ORDER BY id"));
                    static const QSet<QString> kinds{ QStringLiteral("song"), QStringLiteral("scripture"),
                                                      QStringLiteral("presentation") };
                    while (st.step()) {
                        const qint64  id      = st.columnInt64(0);
                        const QString kind    = st.columnText(1);
                        const QString name    = st.columnText(2).trimmed().left(200);
                        const bool    builtin = st.columnInt(4) != 0;
                        if (!kinds.contains(kind)) continue;

                        const QJsonDocument tokDoc = QJsonDocument::fromJson(st.columnText(3).toUtf8());
                        if (!tokDoc.isObject()) {
                            r.warnings.append(QStringLiteral("Theme \"%1\" is damaged and was skipped").arg(name));
                            continue;
                        }
                        const QJsonObject remapped =
                            remapMediaIds(tokDoc.object(), mediaMap, true).toObject();
                        const QString tokens = compactJson(remapped);

                        // A built-in ships with every install: match it by
                        // name instead of importing a second copy.
                        if (builtin) {
                            bool matched = false;
                            for (const Existing& e : have) {
                                if (e.builtin && e.kind == kind && e.name == name) {
                                    themeMap.insert(id, e.id);
                                    matched = true;
                                    break;
                                }
                            }
                            if (matched) continue;
                        }
                        bool dup = false;
                        for (const Existing& e : have) {
                            if (e.kind == kind && e.name.compare(name, Qt::CaseInsensitive) == 0
                                && e.tokens == tokens) {
                                themeMap.insert(id, e.id);
                                dup = true;
                                break;
                            }
                        }
                        if (dup) { addCount(r.skipped, "themes", 1); continue; }

                        // Themes are declarative data checked against the
                        // schema (§5.3), the same gate a .craterheme import
                        // passes. A design the renderer would refuse is
                        // reported, not written.
                        if (!ThemeService::validateThemeTokens(remapped.toVariantMap()).isEmpty()) {
                            r.warnings.append(QStringLiteral("Theme \"%1\" has an unreadable design and was skipped").arg(name));
                            continue;
                        }

                        QString finalName = name.isEmpty() ? QStringLiteral("Imported theme") : name;
                        if (nameTaken(kind, finalName)) {
                            QString candidate = finalName + QStringLiteral(" (Import)");
                            for (int i = 2; nameTaken(kind, candidate) && i < 1000; ++i)
                                candidate = QStringLiteral("%1 (Import %2)").arg(finalName).arg(i);
                            finalName = candidate;
                        }
                        ins.reset();
                        ins.bind(1, kind);
                        ins.bind(2, finalName);
                        ins.bind(3, tokens);
                        ins.bind(4, qMax<qint64>(1, st.columnInt64(5)));
                        ins.bind(5, st.columnInt64(6));
                        ins.bind(6, st.columnInt64(7));
                        ins.step();
                        const qint64 newId = dst.lastInsertRowId();
                        themeMap.insert(id, newId);
                        have.append({ newId, kind, finalName, tokens, false });
                        addCount(r.added, "themes", 1);
                    }

                    // A new profile adopts the archive's default themes. An
                    // existing profile keeps its own.
                    if (targetIsNew) {
                        auto sel = appSrc->prepare(QStringLiteral(
                            "SELECT key, value FROM kv WHERE key IN ('default_song_theme_id', "
                            "'default_scripture_theme_id', 'default_presentation_theme_id')"));
                        auto put = dst.prepare(QStringLiteral(
                            "INSERT INTO kv (key, value) VALUES (?, ?) "
                            "ON CONFLICT(key) DO UPDATE SET value = excluded.value"));
                        while (sel.step()) {
                            const qint64 mapped = themeMap.value(sel.columnText(1).toLongLong(), 0);
                            if (mapped <= 0) continue;
                            put.reset();
                            put.bind(1, sel.columnText(0));
                            put.bind(2, QString::number(mapped));
                            put.step();
                        }
                    }
                }

                if (parts & PartPresentations) {
                    struct Existing { QString title, slides; qint64 id; };
                    QList<Existing> have;
                    {
                        auto st = dst.prepare(QStringLiteral("SELECT id, title, slides_json FROM presentations"));
                        while (st.step())
                            have.append({ st.columnText(1), canonicalJson(st.columnText(2)), st.columnInt64(0) });
                    }
                    auto ins = dst.prepare(QStringLiteral(
                        "INSERT INTO presentations (title, slides_json, slide_count, theme_id, created_at, updated_at) "
                        "VALUES (?, ?, ?, ?, ?, ?)"));
                    auto st = appSrc->prepare(QStringLiteral(
                        "SELECT id, title, slides_json, theme_id, created_at, updated_at "
                        "FROM presentations ORDER BY id"));
                    while (st.step()) {
                        const qint64  id    = st.columnInt64(0);
                        const QString title = st.columnText(1).left(500);
                        const QJsonDocument doc = QJsonDocument::fromJson(st.columnText(2).toUtf8());
                        const QJsonArray slides = doc.isArray()
                            ? remapMediaIds(doc.array(), mediaMap, false).toArray() : QJsonArray();
                        const QString slidesJson = compactJson(slides);
                        bool dup = false;
                        for (const Existing& e : have) {
                            if (e.title == title && e.slides == slidesJson) {
                                presentationMap.insert(id, e.id);
                                dup = true;
                                break;
                            }
                        }
                        if (dup) { addCount(r.skipped, "presentations", 1); continue; }
                        ins.reset();
                        ins.bind(1, title);
                        ins.bind(2, slidesJson);
                        ins.bind(3, qint64(slides.size()));
                        ins.bind(4, (parts & PartThemes) ? themeMap.value(st.columnInt64(3), 0) : qint64(0));
                        ins.bind(5, st.columnInt64(4));
                        ins.bind(6, st.columnInt64(5));
                        ins.step();
                        const qint64 newId = dst.lastInsertRowId();
                        presentationMap.insert(id, newId);
                        have.append({ title, slidesJson, newId });
                        addCount(r.added, "presentations", 1);
                    }
                }

                tx.commit();
            } catch (...) {
                // The rows are gone with the transaction; take the files
                // they would have pointed at with them.
                rollbackFiles();
                throw;
            }
            createdFiles.clear();   // committed: these files are now owned by rows
        } else {
            // Nothing will reference files staged above (cannot happen with
            // the part masks used, but never leave orphans).
            rollbackFiles();
        }

        // ── Transaction 2 (songs.sqlite) ─────────────────────────────────
        if (parts & PartSongs) {
            report(0.86, QStringLiteral("Adding songs"));
            db::Connection src(stagedSongs, db::OpenMode::ReadOnly, QStringLiteral("ProfileImport-src"));
            db::Connection dst(db::DbPaths::songsDbPathIn(targetRoot), db::OpenMode::ReadWrite,
                               QStringLiteral("ProfileImport-songs"));

            QHash<QString, qint64> haveSigs;
            {
                const auto sections = loadSections(dst);
                auto st = dst.prepare(QStringLiteral("SELECT id, title FROM songs"));
                while (st.step())
                    haveSigs.insert(songSignature(st.columnText(1), sections.value(st.columnInt64(0))),
                                    st.columnInt64(0));
            }
            const auto srcSections = loadSections(src);

            db::Transaction tx(dst);
            auto insSong = dst.prepare(QStringLiteral(
                "INSERT INTO songs (title, author, copyright, ccli, theme_id, is_favorite, created_at, updated_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?)"));
            auto insSec = dst.prepare(QStringLiteral(
                "INSERT INTO song_sections (song_id, label, kind, lines_json, sort_order) VALUES (?, ?, ?, ?, ?)"));
            // Same statement shape as SongService::upsertFtsForSong.
            auto insFts = dst.prepare(QStringLiteral(
                "INSERT INTO songs_fts (rowid, title, author, lyrics) "
                "SELECT s.id, "
                "       replace(replace(s.title, '''', ''), char(8217), ''), "
                "       replace(replace(COALESCE(s.author, ''), '''', ''), char(8217), ''), "
                "       replace(replace(?, '''', ''), char(8217), '') "
                "FROM songs s WHERE s.id = ?"));
            static const QSet<QString> kinds{
                QStringLiteral("verse"), QStringLiteral("chorus"), QStringLiteral("bridge"),
                QStringLiteral("intro"), QStringLiteral("outro"), QStringLiteral("tag"),
                QStringLiteral("prechorus"), QStringLiteral("interlude"), QStringLiteral("other") };

            auto st = src.prepare(QStringLiteral(
                "SELECT id, title, author, copyright, ccli, theme_id, is_favorite, created_at, updated_at "
                "FROM songs ORDER BY id"));
            while (st.step()) {
                const qint64 id = st.columnInt64(0);
                const QString title = st.columnText(1).left(500);
                const QList<SongSection> sections = srcSections.value(id);
                const QString sig = songSignature(title, sections);
                if (const auto hit = haveSigs.constFind(sig); hit != haveSigs.constEnd()) {
                    songMap.insert(id, hit.value());
                    addCount(r.skipped, "songs", 1);
                    continue;
                }
                insSong.reset();
                insSong.bind(1, title);
                const auto bindText = [&](int idx, int col) {
                    if (st.columnIsNull(col)) insSong.bindNull(idx);
                    else insSong.bind(idx, st.columnText(col).left(2000));
                };
                bindText(2, 2);
                bindText(3, 3);
                bindText(4, 4);
                const qint64 theme = (parts & PartThemes) && !st.columnIsNull(5)
                                   ? themeMap.value(st.columnInt64(5), 0) : 0;
                if (theme > 0) insSong.bind(5, theme); else insSong.bindNull(5);
                insSong.bind(6, qint64(st.columnInt(6) != 0 ? 1 : 0));
                insSong.bind(7, st.columnInt64(7));
                insSong.bind(8, st.columnInt64(8));
                insSong.step();
                const qint64 newId = dst.lastInsertRowId();

                QStringList lines;
                for (const SongSection& sec : sections) {
                    insSec.reset();
                    insSec.bind(1, newId);
                    insSec.bind(2, sec.label);
                    insSec.bind(3, kinds.contains(sec.kind) ? sec.kind : QStringLiteral("other"));
                    insSec.bind(4, sec.linesJson);
                    insSec.bind(5, sec.sortOrder);
                    insSec.step();
                    lines.append(sec.linesJson);
                }
                insFts.reset();
                insFts.bind(1, flattenLyrics(lines));
                insFts.bind(2, newId);
                insFts.step();

                songMap.insert(id, newId);
                haveSigs.insert(sig, newId);
                addCount(r.added, "songs", 1);
            }

            // Collections: matched by name, membership merged.
            QHash<QString, qint64> haveCollections;
            {
                auto cs = dst.prepare(QStringLiteral("SELECT id, name FROM collections"));
                while (cs.step()) haveCollections.insert(cs.columnText(1).trimmed().toLower(), cs.columnInt64(0));
            }
            auto insCol = dst.prepare(QStringLiteral(
                "INSERT INTO collections (name, created_at, updated_at) VALUES (?, ?, ?)"));
            auto insMember = dst.prepare(QStringLiteral(
                "INSERT OR IGNORE INTO collection_songs (collection_id, song_id, sort_order) VALUES (?, ?, ?)"));
            auto selMembers = src.prepare(QStringLiteral(
                "SELECT song_id, sort_order FROM collection_songs WHERE collection_id = ?"));
            auto cs = src.prepare(QStringLiteral(
                "SELECT id, name, created_at, updated_at FROM collections ORDER BY id"));
            while (cs.step()) {
                const QString name = cs.columnText(1).trimmed().left(200);
                if (name.isEmpty()) continue;
                qint64 target = haveCollections.value(name.toLower(), 0);
                if (target == 0) {
                    insCol.reset();
                    insCol.bind(1, name);
                    insCol.bind(2, cs.columnInt64(2));
                    insCol.bind(3, cs.columnInt64(3));
                    insCol.step();
                    target = dst.lastInsertRowId();
                    haveCollections.insert(name.toLower(), target);
                    addCount(r.added, "collections", 1);
                } else {
                    addCount(r.skipped, "collections", 1);
                }
                selMembers.reset(true);
                selMembers.bind(1, cs.columnInt64(0));
                while (selMembers.step()) {
                    const qint64 song = songMap.value(selMembers.columnInt64(0), 0);
                    if (song == 0) continue;
                    insMember.reset();
                    insMember.bind(1, target);
                    insMember.bind(2, song);
                    insMember.bind(3, selMembers.columnInt64(1));
                    insMember.step();
                }
            }
            tx.commit();
        }

        // ── Transaction 3 (app.sqlite): schedules, which point at all of
        //    the above ─────────────────────────────────────────────────────
        if ((parts & PartSchedules) && appSrc) {
            report(0.94, QStringLiteral("Adding schedules"));
            db::Connection dst(db::DbPaths::appDbPathIn(targetRoot), db::OpenMode::ReadWrite,
                               QStringLiteral("ProfileImport-app"));
            // Paths for media matched to existing rows (new rows were
            // recorded as they were inserted).
            {
                auto st = dst.prepare(QStringLiteral("SELECT id, path FROM media"));
                while (st.step())
                    if (!targetMediaPath.contains(st.columnInt64(0)))
                        targetMediaPath.insert(st.columnInt64(0), st.columnText(1));
            }

            // Schedule items are snapshots that also carry ids into the
            // libraries. Point each id at its imported (or matched) row; an
            // id with nothing behind it becomes 0, which every consumer
            // already treats as "none" and the snapshot still projects.
            std::function<QJsonValue(const QJsonValue&)> remapItem = [&](const QJsonValue& v) -> QJsonValue {
                if (v.isArray()) {
                    QJsonArray out;
                    for (const QJsonValue& e : v.toArray()) out.append(remapItem(e));
                    return out;
                }
                if (!v.isObject()) return v;
                QJsonObject o = v.toObject();
                const auto mapKey = [&](const char* key, const QHash<qint64, qint64>& map) {
                    const QString k = QString::fromLatin1(key);
                    if (!o.contains(k)) return;
                    const qint64 old = o.value(k).toVariant().toLongLong();
                    if (old > 0) o.insert(k, map.value(old, 0));
                };
                mapKey("songId", songMap);
                mapKey("presentationId", presentationMap);
                mapKey("themeId", themeMap);
                mapKey("mediaId", mediaMap);
                if (o.contains(QStringLiteral("mediaPath"))) {
                    const qint64 mid = o.value(QStringLiteral("mediaId")).toVariant().toLongLong();
                    o.insert(QStringLiteral("mediaPath"),
                             mid > 0 ? targetMediaPath.value(mid) : QString());
                }
                for (auto it = o.begin(); it != o.end(); ++it)
                    if (it.value().isArray() || it.value().isObject()) *it = remapItem(it.value());
                return o;
            };

            db::Transaction tx(dst);
            QList<QPair<QString, QString>> have;
            {
                auto st = dst.prepare(QStringLiteral("SELECT name, items_json FROM schedules"));
                while (st.step()) have.append({ st.columnText(0), canonicalJson(st.columnText(1)) });
            }
            auto ins = dst.prepare(QStringLiteral(
                "INSERT INTO schedules (name, items_json, item_count, created_at, modified_at) "
                "VALUES (?, ?, ?, ?, ?)"));
            auto st = appSrc->prepare(QStringLiteral(
                "SELECT name, items_json, created_at, modified_at FROM schedules ORDER BY id"));
            while (st.step()) {
                const QString name = st.columnText(0).left(200);
                const QJsonDocument doc = QJsonDocument::fromJson(st.columnText(1).toUtf8());
                if (!doc.isArray()) {
                    r.warnings.append(QStringLiteral("Schedule \"%1\" is damaged and was skipped").arg(name));
                    continue;
                }
                const QJsonArray items = remapItem(doc.array()).toArray();
                const QString itemsJson = compactJson(items);
                if (have.contains(qMakePair(name, itemsJson))) {
                    addCount(r.skipped, "schedules", 1);
                    continue;
                }
                ins.reset();
                ins.bind(1, name);
                ins.bind(2, itemsJson);
                ins.bind(3, qint64(items.size()));
                ins.bind(4, st.columnInt64(2));
                ins.bind(5, st.columnInt64(3));
                ins.step();
                have.append(qMakePair(name, itemsJson));
                addCount(r.added, "schedules", 1);
            }
            tx.commit();
        }
    } catch (const db::Error& e) {
        rollbackFiles();
        qWarning().noquote() << "ProfileArchive::importArchive:" << e.message();
        r.error = targetIsNew
            ? QStringLiteral("Import failed while writing the new profile.")
            : QStringLiteral("Import stopped part way. Anything already added was kept and nothing was removed. Importing the same file again adds only what is missing.");
        return r;
    }

    // ── Settings ────────────────────────────────────────────────────────
    if (parts & PartSettings) {
        report(0.97, QStringLiteral("Applying settings"));
        const QJsonDocument doc = QJsonDocument::fromJson(zip.readEntry(kSettings));
        if (doc.isObject()) {
            const int n = writeProfilePreferences(targetRoot, doc.object().toVariantMap());
            addCount(r.added, "settings", n);
        } else {
            r.warnings.append(QStringLiteral("The settings in this file are damaged and were skipped"));
        }
    }

    // A new profile that received Bibles must not get the bundled set added
    // on top at its first launch.
    if (targetIsNew && (parts & PartScriptures)) {
        QFile f(db::DbPaths::importSentinelPathIn(targetRoot));
        if (f.open(QIODevice::WriteOnly)) f.write("v1\n");
    }

    r.ok = true;
    report(1.0, QStringLiteral("Done"));
    qInfo().noquote() << "ProfileArchive: imported into" << targetRoot
                      << "added" << r.added << "matched" << r.skipped
                      << "warnings" << r.warnings.size();
    return r;
}

}  // namespace crater::profile
