// Song credits survive the editor's save paths (issue #20).
//
// Author, copyright and CCLI used to be settable only by an EasyWorship
// import: the editor had no fields, and create/update had no copyright
// parameter, so a song typed in by hand could never carry one. These tests
// pin the round trip through createWithSections() and update(), including
// clearing a value and leaving the other credits untouched.
//
// Run via CTest: `ctest --test-dir <build-dir> -R song_credits --output-on-failure`

#include <QDir>
#include <QGuiApplication>
#include <QObject>
#include <QStandardPaths>
#include <QString>
#include <QTest>
#include <QVariantList>
#include <QVariantMap>

#include "crater/Bootstrap.h"
#include "crater/SongService.h"

using crater::SongService;

namespace {

QVariantList oneVerse()
{
    return QVariantList{ QVariantMap{
        { QStringLiteral("label"), QStringLiteral("Verse 1") },
        { QStringLiteral("kind"),  QStringLiteral("verse") },
        { QStringLiteral("lines"), QStringList{ QStringLiteral("Amazing grace") } },
    } };
}

}  // namespace

class TestSongCredits : public QObject
{
    Q_OBJECT

private:
    QString m_dataDir;

private slots:
    void initTestCase()
    {
        QStandardPaths::setTestModeEnabled(true);
        m_dataDir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
        QVERIFY(!m_dataDir.isEmpty());
        QDir(m_dataDir).removeRecursively();
        QDir().mkpath(m_dataDir);
        crater::runAllMigrations();
    }

    void cleanupTestCase()
    {
        QDir(m_dataDir).removeRecursively();
    }

    void createKeepsAllThreeCredits()
    {
        SongService songs;
        const qint64 id = songs.createWithSections(
            QStringLiteral("Amazing Grace"), QStringLiteral("John Newton"),
            QStringLiteral("22025"), 0, oneVerse(),
            QStringLiteral("Public Domain"));
        QVERIFY(id > 0);

        const auto s = songs.fetchSong(id);
        QCOMPARE(s.author,    QStringLiteral("John Newton"));
        QCOMPARE(s.ccli,      QStringLiteral("22025"));
        QCOMPARE(s.copyright, QStringLiteral("Public Domain"));
    }

    void updateChangesAndClearsCredits()
    {
        SongService songs;
        const qint64 id = songs.createWithSections(
            QStringLiteral("Before"), QStringLiteral("A"), QStringLiteral("1"),
            0, oneVerse(), QStringLiteral("(c) One"));
        QVERIFY(id > 0);

        QVERIFY(songs.update(id, QStringLiteral("After"), QStringLiteral("B"),
                             QStringLiteral("2"), 0, oneVerse(), QStringLiteral("(c) Two")));
        auto s = songs.fetchSong(id);
        QCOMPARE(s.title,     QStringLiteral("After"));
        QCOMPARE(s.author,    QStringLiteral("B"));
        QCOMPARE(s.ccli,      QStringLiteral("2"));
        QCOMPARE(s.copyright, QStringLiteral("(c) Two"));

        // Clearing copyright must not disturb the neighbouring columns the
        // UPDATE binds by number.
        QVERIFY(songs.update(id, QStringLiteral("After"), QStringLiteral("B"),
                             QStringLiteral("2"), 0, oneVerse(), QString()));
        s = songs.fetchSong(id);
        QCOMPARE(s.copyright, QString());
        QCOMPARE(s.ccli,      QStringLiteral("2"));
        QCOMPARE(s.author,    QStringLiteral("B"));
        QCOMPARE(s.title,     QStringLiteral("After"));
    }
};

int main(int argc, char* argv[])
{
    QGuiApplication app(argc, argv);
    TestSongCredits tc;
    return QTest::qExec(&tc, argc, argv);
}

#include "test_song_credits.moc"
