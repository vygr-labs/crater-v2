// Built-in song themes seeded by V013.
//
// Same decision as V012, for songs: Plum & Rose becomes the song default
// on a fresh install and must NOT on an upgrade, where an operator who
// never picked a default is implicitly on Classic Dark and would see their
// projection change. Both paths are driven here through the real Migrator.

#include <QDir>
#include <QGuiApplication>
#include <QObject>
#include <QStandardPaths>
#include <QTest>

#include "crater/Bootstrap.h"
#include "crater/ThemeService.h"

#include "db/Connection.h"
#include "db/DbPaths.h"
#include "db/Statement.h"

class TestSongThemes : public QObject
{
    Q_OBJECT

private:
    QString m_dataDir;

    void freshDataDir()
    {
        QDir(m_dataDir).removeRecursively();
        QDir().mkpath(m_dataDir);
    }

    static qint64 builtinId(const QString& name)
    {
        crater::db::Connection conn(crater::db::DbPaths::appDbPath());
        auto q = conn.prepare(u"SELECT id FROM themes WHERE kind = 'song' AND is_builtin = 1 AND name = ?");
        q.bind(1, name);
        return q.step() ? q.columnInt64(0) : 0;
    }

private slots:
    void initTestCase()
    {
        QStandardPaths::setTestModeEnabled(true);
        m_dataDir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
        QVERIFY(!m_dataDir.isEmpty());
    }

    void cleanupTestCase()
    {
        QDir(m_dataDir).removeRecursively();
    }

    void freshInstallDefaultsToPlumRose()
    {
        freshDataDir();
        crater::runAllMigrations();
        crater::ThemeService themes;
        const crater::Theme song = themes.defaultFor(QStringLiteral("song"));
        QCOMPARE(song.name, QStringLiteral("Plum & Rose"));
        QCOMPARE(song.kind, QStringLiteral("song"));
    }

    void seededThemesAreValid()
    {
        freshDataDir();
        crater::runAllMigrations();
        crater::ThemeService themes;
        for (const QString name : {QStringLiteral("Plum & Rose"), QStringLiteral("Graphite & Cyan")}) {
            const crater::Theme t = themes.theme(builtinId(name));
            QVERIFY2(t.id != 0, qPrintable(name));
            QVERIFY(t.isBuiltin);
            QCOMPARE(t.kind, QStringLiteral("song"));
            QCOMPARE(themes.validateTokens(t.tokens), QStringList());
            // The lyric renders, and the theme owns the credits line so the
            // projector's fallback stands down.
            QStringList linkages;
            for (const QVariant& n : themes.layoutNodes(t.tokens, QString()))
                linkages << n.toMap().value(QStringLiteral("data")).toMap().value(QStringLiteral("linkage")).toString();
            QVERIFY2(linkages.contains(QStringLiteral("lyric")), qPrintable(name));
            QVERIFY2(linkages.contains(QStringLiteral("songCredits")), qPrintable(name));
        }
    }

    void upgradeKeepsTheCurrentDefault()
    {
        // An install that last ran V012 a while ago: Classic Dark is old and
        // no default was ever chosen.
        freshDataDir();
        crater::runAllMigrations();
        {
            crater::db::Connection conn(crater::db::DbPaths::appDbPath());
            conn.exec(u"DELETE FROM kv WHERE key = 'default_song_theme_id'");
            conn.exec(u"DELETE FROM themes WHERE kind = 'song' AND name IN ('Plum & Rose', 'Graphite & Cyan')");
            conn.exec(u"UPDATE themes SET created_at = created_at - 86400000");
            conn.setUserVersion(12);
        }
        crater::runAllMigrations();

        QVERIFY(builtinId(QStringLiteral("Plum & Rose")) != 0);
        QVERIFY(builtinId(QStringLiteral("Graphite & Cyan")) != 0);
        crater::ThemeService themes;
        QCOMPARE(themes.defaultFor(QStringLiteral("song")).name, QStringLiteral("Classic Dark"));
    }

    void upgradeNeverOverridesAChosenDefault()
    {
        freshDataDir();
        crater::runAllMigrations();
        const qint64 cyan = builtinId(QStringLiteral("Graphite & Cyan"));
        {
            crater::ThemeService themes;
            themes.setDefaultFor(QStringLiteral("song"), cyan);
        }
        {
            crater::db::Connection conn(crater::db::DbPaths::appDbPath());
            conn.setUserVersion(12);
        }
        crater::runAllMigrations();
        crater::ThemeService themes;
        QCOMPARE(themes.defaultFor(QStringLiteral("song")).id, cyan);
    }
};

// ThemeService touches QFontDatabase, which needs a QGuiApplication.
int main(int argc, char* argv[])
{
    QGuiApplication app(argc, argv);
    TestSongThemes tc;
    return QTest::qExec(&tc, argc, argv);
}

#include "test_song_themes.moc"
