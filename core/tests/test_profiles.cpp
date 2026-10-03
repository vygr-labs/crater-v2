// Tests for profiles (ARCHITECTURE.md §12).
//
// Three layers:
//   1. Path routing   — DbPaths resolves every per-profile path under the
//                       active profile's root, and Default stays at the
//                       app data root.
//   2. Zip wrapper    — the ZIP64 and streaming additions profile archives
//                       rely on (addFile / extractToFile / entrySize).
//   3. Archive engine — export -> inspect -> import as a new profile, then
//                       the same file merged again without duplicating
//                       anything, partial exports, hostile archives, and
//                       duplicating a profile.
//
// Everything runs inside the test-mode AppDataLocation (~/.qttest/...), in
// profile roots below it, so the Default profile's registry-backed
// settings are never written.

#include <QByteArray>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRandomGenerator>
#include <QCryptographicHash>
#include <QSettings>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QTest>

#include "bundle/Zip.h"
#include "db/Connection.h"
#include "db/DbPaths.h"
#include "db/Migrator.h"
#include "db/Statement.h"
#include "profile/ProfileArchive.h"
#include "profile/ProfileSettings.h"

using crater::bundle::ZipReader;
using crater::bundle::ZipWriter;
using crater::db::Connection;
using crater::db::DbPaths;
namespace profile = crater::profile;

namespace {

QByteArray fakePng(const QByteArray& tag)
{
    QByteArray b("\x89PNG\r\n\x1a\n", 8);
    b += tag;
    return b;
}

bool writeFile(const QString& path, const QByteArray& bytes)
{
    QFile f(path);
    if (!f.open(QIODevice::WriteOnly)) return false;
    return f.write(bytes) == bytes.size();
}

QByteArray readFile(const QString& path)
{
    QFile f(path);
    return f.open(QIODevice::ReadOnly) ? f.readAll() : QByteArray();
}

qint64 scalar(Connection& c, const QString& sql)
{
    auto st = c.prepare(sql);
    const qint64 v = st.step() ? st.columnInt64(0) : -1;
    st.reset();
    return v;
}

QString scalarText(Connection& c, const QString& sql)
{
    auto st = c.prepare(sql);
    const QString v = st.step() ? st.columnText(0) : QString();
    st.reset();
    return v;
}

// Valid v2 tokens with one background container pointing at `mediaId`,
// the shape test_theme_bundle uses (validateTokens accepts it).
QJsonObject tokensWithMedia(qint64 mediaId)
{
    const QJsonObject container{
        { "id", "bg" }, { "kind", "container" },
        { "style", QJsonObject{ { "x", 0 }, { "y", 0 }, { "width", 100 }, { "height", 100 },
                                { "z", 0 }, { "opacity", 1 }, { "backgroundColor", "#0a0a0d" } } },
        { "data", QJsonObject{ { "layerName", "Background" }, { "mediaId", mediaId },
                               { "bgOpacity", 1 }, { "overlayColor", QJsonValue() } } },
    };
    const QJsonObject text{
        { "id", "txt" }, { "kind", "text" },
        { "style", QJsonObject{ { "x", 5 }, { "y", 35 }, { "width", 90 }, { "height", 30 },
                                { "z", 10 }, { "opacity", 1 }, { "color", "#f5f5f0" },
                                { "fontFamily", "Funnel Sans" }, { "fontPixelSize", 64 },
                                { "fontWeight", 500 } } },
        { "data", QJsonObject{ { "layerName", "Verse" }, { "linkage", "scriptureText" },
                               { "autoResize", true }, { "maxFontSize", 220 } } },
    };
    return QJsonObject{
        { "version", 2 },
        { "canvas", QJsonObject{ { "width", 1920 }, { "height", 1080 } } },
        { "nodes", QJsonArray{ container, text } },
    };
}

qint64 firstMediaId(const QJsonValue& v)
{
    if (v.isArray()) {
        for (const QJsonValue& e : v.toArray())
            if (const qint64 id = firstMediaId(e)) return id;
        return 0;
    }
    if (!v.isObject()) return 0;
    const QJsonObject o = v.toObject();
    if (o.contains("mediaId") && o.value("mediaId").toVariant().toLongLong() > 0)
        return o.value("mediaId").toVariant().toLongLong();
    for (auto it = o.begin(); it != o.end(); ++it)
        if (const qint64 id = firstMediaId(it.value())) return id;
    return 0;
}

struct Seeded {
    qint64  mediaId = 0;
    qint64  themeId = 0;
    qint64  songId  = 0;
    QString mediaPath;
    QByteArray mediaBytes;
};

// A small but complete profile: one picture, a theme using it, a song in
// a collection, a deck whose slide shows the picture, a schedule pointing
// at all of them, a one-book Bible and two preferences.
// The Bible library is shared by every profile (DbPaths::biblesDbPath).
void ensureSharedBibles()
{
    Connection c(DbPaths::biblesDbPath(), crater::db::OpenMode::ReadWriteCreate);
    crater::db::Migrator::run(c, QStringLiteral("bibles"));
}

// Start the shared library over, empty.
void resetSharedBibles()
{
    for (const char* suffix : { "", "-wal", "-shm" })
        QFile::remove(DbPaths::biblesDbPath() + QLatin1String(suffix));
    ensureSharedBibles();
}

Seeded seedProfile(const QString& root)
{
    Seeded s;
    QString err;
    if (!profile::initProfileRoot(root, &err)) qFatal("initProfileRoot: %s", qPrintable(err));

    s.mediaBytes = fakePng("sunrise-bytes");
    s.mediaPath = QDir::cleanPath(QDir(DbPaths::mediaDirIn(root)).filePath("sunrise.png"));
    if (!writeFile(s.mediaPath, s.mediaBytes)) qFatal("cannot write media");

    {
        Connection app(DbPaths::appDbPathIn(root));
        auto m = app.prepare(QStringLiteral(
            "INSERT INTO media (path, title, type, is_favorite, added_at, page_count, fit_mode) "
            "VALUES (?, 'Sunrise', 'image', 1, 1000, 1, 'cover')"));
        m.bind(1, s.mediaPath);
        m.step();
        s.mediaId = app.lastInsertRowId();

        auto t = app.prepare(QStringLiteral(
            "INSERT INTO themes (kind, name, tokens_json, is_builtin, tokens_version, created_at, updated_at) "
            "VALUES ('song', 'Sunrise Theme', ?, 0, 2, 1, 1)"));
        t.bind(1, QString::fromUtf8(QJsonDocument(tokensWithMedia(s.mediaId)).toJson(QJsonDocument::Compact)));
        t.step();
        s.themeId = app.lastInsertRowId();

        auto kv = app.prepare(QStringLiteral(
            "INSERT INTO kv (key, value) VALUES ('default_song_theme_id', ?) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value"));
        kv.bind(1, QString::number(s.themeId));
        kv.step();

        const QJsonArray slides{ QJsonObject{ { "title", "Welcome" }, { "body", "Hello" },
                                              { "notes", "" }, { "layout", "" },
                                              { "subtitle", "" }, { "bodyRight", "" },
                                              { "mediaId", s.mediaId } } };
        auto p = app.prepare(QStringLiteral(
            "INSERT INTO presentations (title, slides_json, slide_count, theme_id, created_at, updated_at) "
            "VALUES ('Welcome deck', ?, 1, ?, 1, 1)"));
        p.bind(1, QString::fromUtf8(QJsonDocument(slides).toJson(QJsonDocument::Compact)));
        p.bind(2, s.themeId);
        p.step();
    }
    {
        Connection songs(DbPaths::songsDbPathIn(root));
        auto st = songs.prepare(QStringLiteral(
            "INSERT INTO songs (title, author, theme_id, is_favorite, created_at, updated_at) "
            "VALUES ('Amazing Grace', 'John Newton', ?, 0, 1, 1)"));
        st.bind(1, s.themeId);
        st.step();
        s.songId = songs.lastInsertRowId();
        auto sec = songs.prepare(QStringLiteral(
            "INSERT INTO song_sections (song_id, label, kind, lines_json, sort_order) VALUES (?, ?, ?, ?, ?)"));
        sec.bind(1, s.songId); sec.bind(2, QStringLiteral("Verse 1")); sec.bind(3, QStringLiteral("verse"));
        sec.bind(4, QStringLiteral("[\"Amazing grace how sweet the sound\",\"That saved a wretch like me\"]"));
        sec.bind(5, 0);
        sec.step();
        sec.reset();
        sec.bind(1, s.songId); sec.bind(2, QStringLiteral("Verse 2")); sec.bind(3, QStringLiteral("verse"));
        sec.bind(4, QStringLiteral("[\"Twas grace that taught my heart to fear\"]"));
        sec.bind(5, 1);
        sec.step();
        songs.exec(QStringLiteral(
            "INSERT INTO collections (name, created_at, updated_at) VALUES ('Hymns', 1, 1)"));
        const qint64 col = songs.lastInsertRowId();
        auto mem = songs.prepare(QStringLiteral(
            "INSERT INTO collection_songs (collection_id, song_id, sort_order) VALUES (?, ?, 0)"));
        mem.bind(1, col);
        mem.bind(2, s.songId);
        mem.step();
    }
    {
        Connection app(DbPaths::appDbPathIn(root));
        const QJsonArray items{
            QJsonObject{ { "kind", "song" }, { "title", "Amazing Grace" }, { "songId", s.songId },
                         { "themeId", s.themeId },
                         { "pages", QJsonArray{ QJsonObject{ { "label", "Verse 1" }, { "content", "x" } } } } },
            QJsonObject{ { "kind", "image" }, { "title", "Sunrise" }, { "mediaId", s.mediaId },
                         { "mediaPath", s.mediaPath },
                         { "pages", QJsonArray{ QJsonObject{ { "label", "" }, { "content", "" } } } } },
        };
        auto st = app.prepare(QStringLiteral(
            "INSERT INTO schedules (name, items_json, item_count, created_at, modified_at) "
            "VALUES ('Sunday', ?, 2, 1, 1)"));
        st.bind(1, QString::fromUtf8(QJsonDocument(items).toJson(QJsonDocument::Compact)));
        st.step();
    }
    ensureSharedBibles();
    if (Connection probe(DbPaths::biblesDbPath(), crater::db::OpenMode::ReadOnly);
        probe.prepare(QStringLiteral("SELECT 1 FROM translations WHERE code = 'TST'")).step()) {
        // Already seeded by an earlier test: the library is shared.
    } else {
        Connection bib(DbPaths::biblesDbPath());
        bib.exec(QStringLiteral(
            "INSERT INTO translations (code, name, language) VALUES ('TST', 'Test Version', 'en')"));
        const qint64 tr = bib.lastInsertRowId();
        auto b = bib.prepare(QStringLiteral(
            "INSERT INTO books (translation_id, name, abbrev, testament, book_number) "
            "VALUES (?, 'John', 'Jn', 'NT', 43)"));
        b.bind(1, tr);
        b.step();
        const qint64 book = bib.lastInsertRowId();
        auto v = bib.prepare(QStringLiteral(
            "INSERT INTO verses (translation_id, book_id, chapter, verse, text) VALUES (?, ?, 3, ?, ?)"));
        v.bind(1, tr); v.bind(2, book); v.bind(3, 16); v.bind(4, QStringLiteral("For God so loved the world"));
        v.step();
        v.reset();
        v.bind(1, tr); v.bind(2, book); v.bind(3, 17); v.bind(4, QStringLiteral("For God sent not his Son"));
        v.step();
    }
    profile::writeProfilePreferences(root, QVariantMap{
        { QStringLiteral("Settings/showCcli"), false },
        { QStringLiteral("Settings/autoAdvanceDelaySeconds"), 42 },
        // Not a per-profile key: must never be written from an archive.
        { QStringLiteral("Settings/language"), QStringLiteral("es") },
    });
    return s;
}

}  // namespace

class TestProfiles : public QObject
{
    Q_OBJECT

private:
    QString m_dataDir;

    QString root(const QString& name) const { return QDir(m_dataDir).filePath(name); }
    QString staging() const
    {
        const QString p = root(QStringLiteral("staging"));
        QDir().mkpath(p);
        return p;
    }

private slots:
    void initTestCase()
    {
        QStandardPaths::setTestModeEnabled(true);
        m_dataDir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
        QVERIFY(!m_dataDir.isEmpty());
        QDir(m_dataDir).removeRecursively();
        QDir().mkpath(m_dataDir);
    }

    void cleanupTestCase()
    {
        DbPaths::setDataDir(QString());
        QDir(m_dataDir).removeRecursively();
    }

    // ── Layer 1: path routing ───────────────────────────────────────────
    void testDefaultProfileStaysAtAppRoot()
    {
        DbPaths::setDataDir(QString());
        QVERIFY(DbPaths::isDefaultDataDir());
        QCOMPARE(QDir::cleanPath(DbPaths::dataDir()), QDir::cleanPath(m_dataDir));
        QCOMPARE(QDir::cleanPath(DbPaths::appDbPath()),
                 QDir::cleanPath(QDir(m_dataDir).filePath(QStringLiteral("app.sqlite"))));
        QCOMPARE(QDir::cleanPath(DbPaths::mediaDir()),
                 QDir::cleanPath(QDir(m_dataDir).filePath(QStringLiteral("media"))));
    }

    void testOtherProfileRoutesEveryPath()
    {
        const QString r = QDir(DbPaths::profilesDir()).filePath(QStringLiteral("p-0123456789ab"));
        DbPaths::setDataDir(r);
        QVERIFY(!DbPaths::isDefaultDataDir());
        const QString clean = QDir::cleanPath(r);
        for (const QString& p : { DbPaths::appDbPath(), DbPaths::songsDbPath(),
                                  DbPaths::mediaDir(), DbPaths::fontsDir(),
                                  DbPaths::scheduleHistoryDir(), DbPaths::thumbnailsDir(),
                                  DbPaths::importStagingDir() }) {
            QVERIFY2(QDir::cleanPath(p).startsWith(clean + QLatin1Char('/')), qPrintable(p));
        }
        // The machine-wide root never moves.
        QCOMPARE(QDir::cleanPath(DbPaths::appRootDir()), QDir::cleanPath(m_dataDir));
        // The Bible library and its first-run marker are shared: they stay
        // at the app root whichever profile is active.
        QCOMPARE(QFileInfo(DbPaths::biblesDbPath()).absolutePath(), QDir(m_dataDir).absolutePath());
        QCOMPARE(QFileInfo(DbPaths::importSentinelPath()).absolutePath(), QDir(m_dataDir).absolutePath());

        // Pointing at the app root is the Default profile, not an override.
        DbPaths::setDataDir(m_dataDir);
        QVERIFY(DbPaths::isDefaultDataDir());
        DbPaths::setDataDir(QString());
        QVERIFY(DbPaths::isDefaultDataDir());
    }

    void testProfileSettingsStoreIsPerRoot()
    {
        const QString r = root(QStringLiteral("settings-root"));
        QDir().mkpath(r);
        QCOMPARE(profile::writeProfilePreferences(r, QVariantMap{
                     { QStringLiteral("Settings/showVerseNumbers"), false },
                     { QStringLiteral("Settings/mediaDefaultFit"), QStringLiteral("cover") },
                     { QStringLiteral("Settings/mediaDefaultFit2"), QStringLiteral("x") },  // unknown
                     { QStringLiteral("Settings/autoAdvanceDelaySeconds"), 9999 },        // out of range
                     { QStringLiteral("Settings/themeMode"), QStringLiteral("light") },   // global key
                 }), 2);
        QVERIFY(QFile::exists(QDir(r).filePath(QStringLiteral("settings.ini"))));
        const QVariantMap back = profile::readProfilePreferences(r);
        QCOMPARE(back.value(QStringLiteral("Settings/showVerseNumbers")).toBool(), false);
        QCOMPARE(back.value(QStringLiteral("Settings/mediaDefaultFit")).toString(), QStringLiteral("cover"));
        QVERIFY(!back.contains(QStringLiteral("Settings/themeMode")));
        QVERIFY(profile::isPerProfileSettingKey(u"Settings/showCcli"));
        QVERIFY(!profile::isPerProfileSettingKey(u"Settings/language"));
    }

    // ── Layer 2: zip additions ──────────────────────────────────────────
    void testZip64StreamingRoundTrip()
    {
        QTemporaryDir tmp;
        QVERIFY(tmp.isValid());
        QByteArray big(3 * 1024 * 1024 + 17, Qt::Uninitialized);
        for (qsizetype i = 0; i < big.size(); ++i) big[i] = char(QRandomGenerator::global()->bounded(256));
        const QString src = tmp.filePath(QStringLiteral("big.bin"));
        QVERIFY(writeFile(src, big));

        const QString zipPath = tmp.filePath(QStringLiteral("z64.zip"));
        {
            ZipWriter w(zipPath);
            w.setForceZip64(true);
            QVERIFY(w.addEntry(QStringLiteral("manifest.json"), QByteArray("{}")));
            qint64 lastSeen = 0;
            QVERIFY(w.addFile(QStringLiteral("media/big.bin"), src,
                              [&](qint64 done) { lastSeen = done; return true; }));
            QCOMPARE(lastSeen, qint64(big.size()));
            QVERIFY(w.commit());
        }
        ZipReader r(zipPath);
        QVERIFY2(r.isOpen(), qPrintable(r.errorString()));
        QVERIFY(!r.hasDuplicateNames());
        QCOMPARE(r.entryNames().size(), 2);
        QCOMPARE(r.entrySize(QStringLiteral("media/big.bin")), qint64(big.size()));
        QCOMPARE(r.readEntry(QStringLiteral("manifest.json")), QByteArray("{}"));
        const QString out = tmp.filePath(QStringLiteral("out.bin"));
        QVERIFY2(r.extractToFile(QStringLiteral("media/big.bin"), out), qPrintable(r.errorString()));
        QCOMPARE(readFile(out), big);
        QCOMPARE(r.entrySize(QStringLiteral("missing")), qint64(-1));
    }

    void testZipFlagsDuplicateNames()
    {
        QTemporaryDir tmp;
        const QString zipPath = tmp.filePath(QStringLiteral("dup.zip"));
        {
            ZipWriter w(zipPath);
            QVERIFY(w.addEntry(QStringLiteral("a.txt"), QByteArray("one")));
            QVERIFY(w.addEntry(QStringLiteral("a.txt"), QByteArray("two")));
            QVERIFY(w.commit());
        }
        ZipReader r(zipPath);
        QVERIFY(r.isOpen());
        QVERIFY(r.hasDuplicateNames());
    }

    // ── Layer 3: archive engine ─────────────────────────────────────────
    void testExportImportAsNewProfile()
    {
        const QString src = root(QStringLiteral("src-a"));
        const Seeded s = seedProfile(src);

        QTemporaryDir tmp;
        const QString archive = tmp.filePath(QStringLiteral("a.craterprofile"));
        const profile::ExportResult ex =
            profile::exportArchive(src, QStringLiteral("Main church"), profile::kAllParts, archive, staging());
        QVERIFY2(ex.ok, qPrintable(ex.error));
        QVERIFY(ex.warnings.isEmpty());

        const profile::ArchiveInfo info = profile::inspectArchive(archive);
        QVERIFY2(info.ok, qPrintable(info.error));
        QCOMPARE(info.parts, profile::kAllParts);
        QCOMPARE(info.profileName, QStringLiteral("Main church"));
        QCOMPARE(info.counts.value(QStringLiteral("songs")).toLongLong(), 1);
        QCOMPARE(info.counts.value(QStringLiteral("media")).toLongLong(), 1);
        QCOMPARE(info.counts.value(QStringLiteral("themes")).toLongLong(), 1);
        QCOMPARE(info.counts.value(QStringLiteral("scriptures")).toLongLong(), 1);

        // Nothing from the source machine's paths ships in the archive.
        {
            ZipReader z(archive);
            QVERIFY(z.isOpen());
            for (const QString& n : z.entryNames())
                QVERIFY2(!n.contains(QLatin1String("..")) && !n.startsWith(QLatin1Char('/')), qPrintable(n));
        }

        // Another machine: its shared library doesn't have TST yet.
        resetSharedBibles();

        const QString dst = root(QStringLiteral("dst-a"));
        QString err;
        QVERIFY2(profile::initProfileRoot(dst, &err), qPrintable(err));
        const profile::ImportResult im =
            profile::importArchive(archive, profile::kAllParts, dst, true, staging());
        QVERIFY2(im.ok, qPrintable(im.error));
        QVERIFY2(im.warnings.isEmpty(), qPrintable(im.warnings.join("; ")));
        QCOMPARE(im.added.value(QStringLiteral("songs")).toLongLong(), 1);
        QCOMPARE(im.added.value(QStringLiteral("media")).toLongLong(), 1);
        QCOMPARE(im.added.value(QStringLiteral("themes")).toLongLong(), 1);

        Connection app(DbPaths::appDbPathIn(dst), crater::db::OpenMode::ReadOnly);
        const qint64 newMedia = scalar(app, QStringLiteral("SELECT id FROM media WHERE title = 'Sunrise'"));
        QVERIFY(newMedia > 0);
        const QString newPath = scalarText(app, QStringLiteral("SELECT path FROM media WHERE title = 'Sunrise'"));
        QVERIFY2(QDir::cleanPath(QFileInfo(newPath).absolutePath())
                     == QDir::cleanPath(DbPaths::mediaDirIn(dst)), qPrintable(newPath));
        QCOMPARE(readFile(newPath), s.mediaBytes);
        QCOMPARE(scalarText(app, QStringLiteral("SELECT fit_mode FROM media WHERE id = %1").arg(newMedia)),
                 QStringLiteral("cover"));

        // Theme token now points at the new media row.
        const qint64 newTheme = scalar(app, QStringLiteral(
            "SELECT id FROM themes WHERE name = 'Sunrise Theme' AND is_builtin = 0"));
        QVERIFY(newTheme > 0);
        const QJsonObject tokens = QJsonDocument::fromJson(scalarText(app, QStringLiteral(
            "SELECT tokens_json FROM themes WHERE id = %1").arg(newTheme)).toUtf8()).object();
        QCOMPARE(firstMediaId(tokens), newMedia);
        QCOMPARE(scalarText(app, QStringLiteral(
            "SELECT value FROM kv WHERE key = 'default_song_theme_id'")), QString::number(newTheme));

        // Deck: slide picture and theme remapped.
        const QJsonArray slides = QJsonDocument::fromJson(scalarText(app, QStringLiteral(
            "SELECT slides_json FROM presentations WHERE title = 'Welcome deck'")).toUtf8()).array();
        QCOMPARE(slides.size(), 1);
        QCOMPARE(slides.at(0).toObject().value("mediaId").toVariant().toLongLong(), newMedia);
        QCOMPARE(scalar(app, QStringLiteral("SELECT theme_id FROM presentations WHERE title = 'Welcome deck'")),
                 newTheme);

        // Songs: rows, sections, collection, searchable.
        Connection songs(DbPaths::songsDbPathIn(dst), crater::db::OpenMode::ReadOnly);
        const qint64 newSong = scalar(songs, QStringLiteral("SELECT id FROM songs WHERE title = 'Amazing Grace'"));
        QVERIFY(newSong > 0);
        QCOMPARE(scalar(songs, QStringLiteral("SELECT count(*) FROM song_sections WHERE song_id = %1").arg(newSong)), 2);
        QCOMPARE(scalar(songs, QStringLiteral("SELECT theme_id FROM songs WHERE id = %1").arg(newSong)), newTheme);
        QCOMPARE(scalar(songs, QStringLiteral(
            "SELECT count(*) FROM collection_songs cs JOIN collections c ON c.id = cs.collection_id "
            "WHERE c.name = 'Hymns' AND cs.song_id = %1").arg(newSong)), 1);
        QCOMPARE(scalar(songs, QStringLiteral(
            "SELECT count(*) FROM songs_fts WHERE songs_fts MATCH 'wretch'")), 1);

        // Schedule items point at the imported rows.
        const QJsonArray items = QJsonDocument::fromJson(scalarText(app, QStringLiteral(
            "SELECT items_json FROM schedules WHERE name = 'Sunday'")).toUtf8()).array();
        QCOMPARE(items.size(), 2);
        QCOMPARE(items.at(0).toObject().value("songId").toVariant().toLongLong(), newSong);
        QCOMPARE(items.at(0).toObject().value("themeId").toVariant().toLongLong(), newTheme);
        QCOMPARE(items.at(1).toObject().value("mediaId").toVariant().toLongLong(), newMedia);
        QCOMPARE(items.at(1).toObject().value("mediaPath").toString(), newPath);

        // The Bible lands in the shared library, with its search index.
        Connection bib(DbPaths::biblesDbPath(), crater::db::OpenMode::ReadOnly);
        QCOMPARE(scalar(bib, QStringLiteral(
            "SELECT count(*) FROM verses v JOIN translations t ON t.id = v.translation_id WHERE t.code = 'TST'")), 2);
        QCOMPARE(scalar(bib, QStringLiteral("SELECT count(*) FROM verses_fts WHERE verses_fts MATCH 'loved'")), 1);

        // Per-profile preferences only.
        const QVariantMap prefs = profile::readProfilePreferences(dst);
        QCOMPARE(prefs.value(QStringLiteral("Settings/showCcli")).toBool(), false);
        QCOMPARE(prefs.value(QStringLiteral("Settings/autoAdvanceDelaySeconds")).toInt(), 42);
        QSettings ini(QDir(dst).filePath(QStringLiteral("settings.ini")), QSettings::IniFormat);
        QVERIFY(!ini.contains(QStringLiteral("Settings/language")));

        // The source profile was only read.
        QCOMPARE(readFile(s.mediaPath), s.mediaBytes);
    }

    void testMergeTwiceAddsNothing()
    {
        const QString src = root(QStringLiteral("src-b"));
        seedProfile(src);
        QTemporaryDir tmp;
        const QString archive = tmp.filePath(QStringLiteral("b.craterprofile"));
        QVERIFY(profile::exportArchive(src, QStringLiteral("B"), profile::kAllParts, archive, staging()).ok);

        // Merge into a profile that already holds the same content: the
        // source itself.
        const profile::ImportResult im =
            profile::importArchive(archive, profile::kAllParts, src, false, staging());
        QVERIFY2(im.ok, qPrintable(im.error));
        QCOMPARE(im.added.value(QStringLiteral("songs")).toLongLong(), 0);
        QCOMPARE(im.added.value(QStringLiteral("media")).toLongLong(), 0);
        QCOMPARE(im.added.value(QStringLiteral("themes")).toLongLong(), 0);
        QCOMPARE(im.added.value(QStringLiteral("presentations")).toLongLong(), 0);
        QCOMPARE(im.added.value(QStringLiteral("schedules")).toLongLong(), 0);
        QCOMPARE(im.added.value(QStringLiteral("scriptures")).toLongLong(), 0);
        QCOMPARE(im.skipped.value(QStringLiteral("songs")).toLongLong(), 1);
        QCOMPARE(im.skipped.value(QStringLiteral("media")).toLongLong(), 1);

        Connection app(DbPaths::appDbPathIn(src), crater::db::OpenMode::ReadOnly);
        QCOMPARE(scalar(app, QStringLiteral("SELECT count(*) FROM media")), 1);
        QCOMPARE(scalar(app, QStringLiteral("SELECT count(*) FROM themes WHERE is_builtin = 0")), 1);
        QCOMPARE(scalar(app, QStringLiteral("SELECT count(*) FROM schedules")), 1);
        Connection songs(DbPaths::songsDbPathIn(src), crater::db::OpenMode::ReadOnly);
        QCOMPARE(scalar(songs, QStringLiteral("SELECT count(*) FROM songs")), 1);
        QCOMPARE(scalar(songs, QStringLiteral("SELECT count(*) FROM collections")), 1);
        QCOMPARE(QDir(DbPaths::mediaDirIn(src)).entryList(QDir::Files).size(), 1);
    }

    void testPartialExportCarriesOnlyThatPart()
    {
        const QString src = root(QStringLiteral("src-c"));
        seedProfile(src);
        QTemporaryDir tmp;
        const QString archive = tmp.filePath(QStringLiteral("c.craterprofile"));
        const auto ex = profile::exportArchive(src, QStringLiteral("C"), profile::PartSongs, archive, staging());
        QVERIFY2(ex.ok, qPrintable(ex.error));

        const auto info = profile::inspectArchive(archive);
        QVERIFY(info.ok);
        QCOMPARE(info.parts, unsigned(profile::PartSongs));
        ZipReader z(archive);
        QVERIFY(!z.hasEntry(QStringLiteral("db/app.sqlite")));
        QVERIFY(!z.hasEntry(QStringLiteral("db/bibles.sqlite")));
        QVERIFY(!z.hasEntry(QStringLiteral("settings.json")));
        for (const QString& n : z.entryNames()) QVERIFY(!n.startsWith(QLatin1String("media/")));

        // Songs without their themes come across with no theme.
        const QString dst = root(QStringLiteral("dst-c"));
        QString err;
        QVERIFY(profile::initProfileRoot(dst, &err));
        QVERIFY(profile::importArchive(archive, profile::kAllParts, dst, true, staging()).ok);
        Connection songs(DbPaths::songsDbPathIn(dst), crater::db::OpenMode::ReadOnly);
        QCOMPARE(scalar(songs, QStringLiteral("SELECT count(*) FROM songs WHERE theme_id IS NULL")), 1);
    }

    // Fonts are their own part: themes travel without the font files
    // unless Fonts is ticked too.
    void testFontsAreTheirOwnPart()
    {
        const QString src = root(QStringLiteral("src-f"));
        seedProfile(src);
        QByteArray fontBytes("\x00\x01\x00\x00", 4);
        fontBytes.append(QByteArray(256, 'f'));
        const QString sha = QString::fromLatin1(
            QCryptographicHash::hash(fontBytes, QCryptographicHash::Sha256).toHex());
        const QString fontPath = QDir(DbPaths::fontsDirIn(src)).filePath(sha + QStringLiteral(".ttf"));
        QDir().mkpath(DbPaths::fontsDirIn(src));
        {
            QFile f(fontPath);
            QVERIFY(f.open(QIODevice::WriteOnly));
            f.write(fontBytes);
        }
        {
            Connection app(DbPaths::appDbPathIn(src));
            auto st = app.prepare(QStringLiteral(
                "INSERT INTO user_fonts (hash, family, path, added_at) VALUES (?, 'Test Sans', ?, 1)"));
            st.bind(1, sha);
            st.bind(2, fontPath);
            st.step();
        }

        QTemporaryDir tmp;
        const auto hasFontEntry = [](const QString& archive) {
            ZipReader z(archive);
            for (const QString& n : z.entryNames())
                if (n.startsWith(QLatin1String("fonts/"))) return true;
            return false;
        };

        const QString themesOnly = tmp.filePath(QStringLiteral("t.craterprofile"));
        QVERIFY(profile::exportArchive(src, QStringLiteral("T"), profile::PartThemes,
                                       themesOnly, staging()).ok);
        QCOMPARE(profile::inspectArchive(themesOnly).parts, unsigned(profile::PartThemes));
        QVERIFY(!hasFontEntry(themesOnly));

        const QString withFonts = tmp.filePath(QStringLiteral("tf.craterprofile"));
        QVERIFY(profile::exportArchive(src, QStringLiteral("TF"),
                                       profile::PartThemes | profile::PartFonts,
                                       withFonts, staging()).ok);
        QCOMPARE(profile::inspectArchive(withFonts).parts,
                 unsigned(profile::PartThemes | profile::PartFonts));
        QVERIFY(hasFontEntry(withFonts));

        const QString dst = root(QStringLiteral("dst-f"));
        QString err;
        QVERIFY(profile::initProfileRoot(dst, &err));
        const auto im = profile::importArchive(withFonts, profile::kAllParts, dst, true, staging());
        QVERIFY2(im.ok, qPrintable(im.error));
        Connection app(DbPaths::appDbPathIn(dst), crater::db::OpenMode::ReadOnly);
        QCOMPARE(scalar(app, QStringLiteral("SELECT count(*) FROM user_fonts WHERE hash = '%1'").arg(sha)), 1);

        // The estimate the export dialog shows counts the font and its bytes.
        const QVariantMap est = profile::estimateParts(src);
        QCOMPARE(est.value(QStringLiteral("fonts")).toMap().value(QStringLiteral("count")).toLongLong(), 1);
        QCOMPARE(est.value(QStringLiteral("fonts")).toMap().value(QStringLiteral("bytes")).toLongLong(),
                 qint64(fontBytes.size()));
    }

    void testInspectRejectsHostileArchives()
    {
        QTemporaryDir tmp;
        const QByteArray manifest = QJsonDocument(QJsonObject{
            { "kind", "craterprofile" }, { "formatVersion", 1 },
            { "parts", QJsonArray{ "settings" } } }).toJson();

        // Path traversal in an entry name.
        {
            const QString p = tmp.filePath(QStringLiteral("trav.craterprofile"));
            ZipWriter w(p);
            QVERIFY(w.addEntry(QStringLiteral("manifest.json"), manifest));
            QVERIFY(w.addEntry(QStringLiteral("settings.json"), QByteArray("{}")));
            QVERIFY(w.addEntry(QStringLiteral("media/../../evil.dll"), QByteArray("MZ")));
            QVERIFY(w.commit());
            QVERIFY(!profile::inspectArchive(p).ok);
        }
        // Wrong kind.
        {
            const QString p = tmp.filePath(QStringLiteral("kind.craterprofile"));
            ZipWriter w(p);
            QVERIFY(w.addEntry(QStringLiteral("manifest.json"),
                               QJsonDocument(QJsonObject{ { "kind", "craterheme" }, { "formatVersion", 1 } }).toJson()));
            QVERIFY(w.commit());
            QVERIFY(!profile::inspectArchive(p).ok);
        }
        // From a newer Crater.
        {
            const QString p = tmp.filePath(QStringLiteral("newer.craterprofile"));
            ZipWriter w(p);
            QVERIFY(w.addEntry(QStringLiteral("manifest.json"),
                               QJsonDocument(QJsonObject{ { "kind", "craterprofile" },
                                                          { "formatVersion", 99 } }).toJson()));
            QVERIFY(w.commit());
            QVERIFY(!profile::inspectArchive(p).ok);
        }
        // A media index entry whose hash does not match its name.
        {
            const QString p = tmp.filePath(QStringLiteral("hash.craterprofile"));
            const QString entry = QStringLiteral("media/") + QString(64, QLatin1Char('a')) + QStringLiteral(".png");
            const QByteArray m = QJsonDocument(QJsonObject{
                { "kind", "craterprofile" }, { "formatVersion", 1 }, { "parts", QJsonArray{ "settings" } },
                { "media", QJsonArray{ QJsonObject{ { "id", 1 }, { "entry", entry },
                                                    { "sha256", QString(64, QLatin1Char('b')) },
                                                    { "bytes", 3 } } } } }).toJson();
            ZipWriter w(p);
            QVERIFY(w.addEntry(QStringLiteral("manifest.json"), m));
            QVERIFY(w.addEntry(QStringLiteral("settings.json"), QByteArray("{}")));
            QVERIFY(w.addEntry(entry, QByteArray("abc")));
            QVERIFY(w.commit());
            QVERIFY(!profile::inspectArchive(p).ok);
        }
        // Not a zip at all.
        {
            const QString p = tmp.filePath(QStringLiteral("text.craterprofile"));
            QVERIFY(writeFile(p, QByteArray("{\"kind\":\"craterprofile\"}")));
            QVERIFY(!profile::inspectArchive(p).ok);
        }
    }

    // Profiles made before the library was shared kept their own Bibles.
    // Consolidation folds what only they have into the shared library and
    // retires their file.
    void testConsolidateMergesProfileBibles()
    {
        ensureSharedBibles();
        const QString legacyRoot = QDir(DbPaths::profilesDir()).filePath(QStringLiteral("p-legacy00000"));
        QDir().mkpath(legacyRoot);
        const QString legacy = DbPaths::biblesDbPathIn(legacyRoot);
        {
            Connection c(legacy, crater::db::OpenMode::ReadWriteCreate);
            crater::db::Migrator::run(c, QStringLiteral("bibles"));
            c.exec(QStringLiteral(
                "INSERT INTO translations (code, name, language) VALUES ('OLD', 'Old Version', 'en')"));
            const qint64 tr = c.lastInsertRowId();
            auto b = c.prepare(QStringLiteral(
                "INSERT INTO books (translation_id, name, abbrev, testament, book_number) "
                "VALUES (?, 'Genesis', 'Gen', 'OT', 1)"));
            b.bind(1, tr);
            b.step();
            const qint64 book = c.lastInsertRowId();
            auto v = c.prepare(QStringLiteral(
                "INSERT INTO verses (translation_id, book_id, chapter, verse, text) VALUES (?, ?, 1, 1, ?)"));
            v.bind(1, tr); v.bind(2, book); v.bind(3, QStringLiteral("In the beginning"));
            v.step();
        }

        QCOMPARE(profile::consolidateProfileBibles(), 1);
        // Left in place for older versions, marked as merged.
        QVERIFY(QFile::exists(legacy));
        QVERIFY(QFile::exists(legacy + QStringLiteral(".merged")));
        {
            Connection bib(DbPaths::biblesDbPath(), crater::db::OpenMode::ReadOnly);
            QCOMPARE(scalar(bib, QStringLiteral(
                "SELECT count(*) FROM verses v JOIN translations t ON t.id = v.translation_id "
                "WHERE t.code = 'OLD'")), 1);
        }
        // Done once: nothing left to merge.
        QCOMPARE(profile::consolidateProfileBibles(), 0);
    }

    void testDuplicateRebasesPathsOntoTheCopy()
    {
        const QString src = root(QStringLiteral("src-d"));
        const Seeded s = seedProfile(src);
        const QString dup = root(QStringLiteral("dup-d"));
        QString err;
        QVERIFY2(profile::duplicateProfileData(src, dup, {}, &err), qPrintable(err));

        Connection app(DbPaths::appDbPathIn(dup), crater::db::OpenMode::ReadOnly);
        const QString path = scalarText(app, QStringLiteral("SELECT path FROM media"));
        QCOMPARE(QDir::cleanPath(QFileInfo(path).absolutePath()), QDir::cleanPath(DbPaths::mediaDirIn(dup)));
        QCOMPARE(readFile(path), s.mediaBytes);
        Connection songs(DbPaths::songsDbPathIn(dup), crater::db::OpenMode::ReadOnly);
        QCOMPARE(scalar(songs, QStringLiteral("SELECT count(*) FROM songs")), 1);
        QCOMPARE(profile::readProfilePreferences(dup).value(QStringLiteral("Settings/autoAdvanceDelaySeconds")).toInt(), 42);

        // Removing the copy's file leaves the original alone.
        QVERIFY(QFile::remove(path));
        QCOMPARE(readFile(s.mediaPath), s.mediaBytes);
    }
};

QTEST_MAIN(TestProfiles)
#include "test_profiles.moc"
