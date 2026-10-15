// Resetting a profile (ProfileService::resetProfile).
//
// The Default profile can't be deleted: its folder is the app root, which
// also holds every other profile, profiles.json, the shared Bible library and
// the logs. Reset is how it starts over. These tests pin what a reset may
// remove and, more importantly, what it must leave alone: a profile not in
// use resets in place and still opens, the profile in use is reset by the
// next startup before anything opens its databases, and a recorded reset runs
// exactly once.
//
// Everything runs inside the test-mode AppDataLocation. The machine-wide
// settings store is an INI file there too (ProfileSettings.h), so nothing
// here can reach the operator's real Crater settings.
//
// Run via CTest: `ctest --test-dir <build-dir> -R profile_reset --output-on-failure`

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QObject>
#include <QSignalSpy>
#include <QStandardPaths>
#include <QString>
#include <QTest>
#include <QThreadPool>

#include "crater/Bootstrap.h"
#include "crater/ProfileService.h"
#include "db/Connection.h"
#include "db/DbPaths.h"
#include "db/Statement.h"
#include "profile/ProfileSettings.h"

using crater::ProfileService;
using crater::db::DbPaths;

namespace {

void addSong(const QString& songsDb, const QString& title)
{
    crater::db::Connection c(songsDb);
    auto st = c.prepare(QStringLiteral(
        "INSERT INTO songs (title, created_at, updated_at) VALUES (?, 0, 0)"));
    st.bind(1, title);
    st.step();
}

int songCount(const QString& songsDb)
{
    crater::db::Connection c(songsDb, crater::db::OpenMode::ReadOnly);
    auto st = c.prepare(QStringLiteral("SELECT COUNT(*) FROM songs"));
    return st.step() ? st.columnInt(0) : -1;
}

int builtinThemeCount(const QString& appDb)
{
    crater::db::Connection c(appDb, crater::db::OpenMode::ReadOnly);
    auto st = c.prepare(QStringLiteral("SELECT COUNT(*) FROM themes WHERE is_builtin = 1"));
    return st.step() ? st.columnInt(0) : -1;
}

bool writeFile(const QString& path, const QByteArray& data)
{
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile f(path);
    return f.open(QIODevice::WriteOnly) && f.write(data) == data.size();
}

QByteArray readFile(const QString& path)
{
    QFile f(path);
    return f.open(QIODevice::ReadOnly) ? f.readAll() : QByteArray();
}

// Wait for operationFinished(op) and return its ok flag.
bool waitFor(ProfileService& svc, QSignalSpy& spy, const QString& op)
{
    for (int i = 0; i < 200; ++i) {
        for (const auto& args : spy)
            if (args.at(0).toString() == op) return args.at(1).toBool();
        QTest::qWait(50);
    }
    Q_UNUSED(svc);
    return false;
}

}  // namespace

class TestProfileReset : public QObject
{
    Q_OBJECT

private:
    QString m_root;      // the app root, which is also Default's root
    QString m_otherId;   // a second profile, created in initTestCase

private slots:
    void initTestCase()
    {
        QStandardPaths::setTestModeEnabled(true);
        m_root = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
        QVERIFY(!m_root.isEmpty());
        QDir(m_root).removeRecursively();
        QDir().mkpath(m_root);

        ProfileService svc;
        svc.activate({});
        crater::runAllMigrations();
        QCOMPARE(svc.currentProfileId(), QStringLiteral("default"));

        QSignalSpy done(&svc, &ProfileService::operationFinished);
        QVERIFY(svc.createProfile(QStringLiteral("Youth"), false));
        QVERIFY(waitFor(svc, done, QStringLiteral("create")));
        m_otherId = done.first().at(3).toMap().value(QStringLiteral("id")).toString();
        QVERIFY(!m_otherId.isEmpty());
    }

    void cleanupTestCase()
    {
        QThreadPool::globalInstance()->waitForDone();
        DbPaths::setDataDir(QString());
        QDir(m_root).removeRecursively();
    }

    void resetsAProfileNotInUse()
    {
        const QString other = QDir(DbPaths::profilesDir()).filePath(m_otherId);
        addSong(DbPaths::songsDbPathIn(other), QStringLiteral("Youth song"));
        QVERIFY(writeFile(QDir(other).filePath(QStringLiteral("media/clip.mp4")), "video"));
        QVERIFY(writeFile(QDir(other).filePath(QStringLiteral("schedules/sunday.json")), "{}"));
        crater::profile::writeProfilePreferences(other, {
            { QStringLiteral("Settings/showVerseNumbers"), false } });
        addSong(DbPaths::songsDbPathIn(m_root), QStringLiteral("Default song"));

        ProfileService svc;
        svc.activate({});   // Default in use
        QSignalSpy done(&svc, &ProfileService::operationFinished);
        QSignalSpy restart(&svc, &ProfileService::restartRequested);
        QVERIFY(svc.resetProfile(m_otherId));
        QVERIFY2(waitFor(svc, done, QStringLiteral("reset")), qPrintable(svc.lastError()));
        QCOMPARE(restart.size(), 0);   // not the profile in use: no restart

        // Its content is gone and it opens as a fresh profile.
        QCOMPARE(songCount(DbPaths::songsDbPathIn(other)), 0);
        QVERIFY(builtinThemeCount(DbPaths::appDbPathIn(other)) > 0);
        QVERIFY(!QFile::exists(QDir(other).filePath(QStringLiteral("media/clip.mp4"))));
        QVERIFY(!QFile::exists(QDir(other).filePath(QStringLiteral("schedules/sunday.json"))));
        QVERIFY(crater::profile::readProfilePreferences(other).isEmpty());
        QVERIFY(!QFile::exists(QDir(other).filePath(QStringLiteral(".reset-pending"))));

        // It keeps its identity and place in the list.
        QVERIFY(QFile::exists(QDir(other).filePath(QStringLiteral("profile.json"))));
        bool listed = false;
        for (const QVariant& p : svc.profiles())
            listed = listed || p.toMap().value(QStringLiteral("id")).toString() == m_otherId;
        QVERIFY(listed);

        // The profile in use is untouched.
        QCOMPARE(songCount(DbPaths::songsDbPathIn(m_root)), 1);
    }

    void resetsDefaultOnTheNextStartup()
    {
        const QString other = QDir(DbPaths::profilesDir()).filePath(m_otherId);
        addSong(DbPaths::songsDbPathIn(other), QStringLiteral("Survives"));
        QVERIFY(writeFile(QDir(m_root).filePath(QStringLiteral("media/logo.png")), "png"));
        QVERIFY(writeFile(QDir(m_root).filePath(QStringLiteral("crater.log")), "keep this log\n"));
        {
            const auto global = crater::profile::openGlobalSettings();
            global->setValue(QStringLiteral("Settings/showCcli"), false);       // per profile
            global->setValue(QStringLiteral("Settings/themeMode"), QStringLiteral("light"));  // machine-wide
            global->sync();
        }
        const QByteArray registryBefore = readFile(QDir(m_root).filePath(QStringLiteral("profiles.json")));
        QVERIFY(!registryBefore.isEmpty());
        const int defaultSongs = songCount(DbPaths::songsDbPathIn(m_root));
        QVERIFY(defaultSongs > 0);

        {
            ProfileService svc;
            svc.activate({});
            QSignalSpy restart(&svc, &ProfileService::restartRequested);
            QVERIFY(svc.resetProfile(QStringLiteral("default")));
            QCOMPARE(restart.size(), 1);
            QCOMPARE(restart.first().at(0).toString(), QStringLiteral("default"));
            // Nothing is removed while this process still has it open.
            QCOMPARE(songCount(DbPaths::songsDbPathIn(m_root)), defaultSongs);
            QVERIFY(QFile::exists(QDir(m_root).filePath(QStringLiteral(".reset-pending"))));
        }

        // The relaunch: activate() resets before the migrations rebuild it.
        {
            ProfileService svc;
            svc.activate({ QStringLiteral("crater"), QStringLiteral("--profile=default") });
            crater::runAllMigrations();
        }
        QCOMPARE(songCount(DbPaths::songsDbPathIn(m_root)), 0);
        QVERIFY(builtinThemeCount(DbPaths::appDbPathIn(m_root)) > 0);
        QVERIFY(!QFile::exists(QDir(m_root).filePath(QStringLiteral("media/logo.png"))));
        QVERIFY(!QFile::exists(QDir(m_root).filePath(QStringLiteral(".reset-pending"))));

        // What must survive a Default reset.
        QCOMPARE(readFile(QDir(m_root).filePath(QStringLiteral("crater.log"))), QByteArray("keep this log\n"));
        QVERIFY(QFile::exists(QDir(m_root).filePath(QStringLiteral("profiles.json"))));
        QVERIFY(QFile::exists(DbPaths::biblesDbPath()));
        QCOMPARE(songCount(DbPaths::songsDbPathIn(other)), 1);
        QVERIFY(QFile::exists(QDir(other).filePath(QStringLiteral("profile.json"))));
        const auto global = crater::profile::openGlobalSettings();
        QVERIFY(!global->contains(QStringLiteral("Settings/showCcli")));
        QCOMPARE(global->value(QStringLiteral("Settings/themeMode")).toString(), QStringLiteral("light"));
    }

    void aRecordedResetRunsOnce()
    {
        addSong(DbPaths::songsDbPathIn(m_root), QStringLiteral("Added after the reset"));
        ProfileService svc;
        svc.activate({});
        crater::runAllMigrations();
        QCOMPARE(songCount(DbPaths::songsDbPathIn(m_root)), 1);
    }
};

int main(int argc, char** argv)
{
    QGuiApplication app(argc, argv);
    TestProfileReset tc;
    return QTest::qExec(&tc, argc, argv);
}

#include "test_profile_reset.moc"
