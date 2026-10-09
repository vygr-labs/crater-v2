// Built-in scripture themes seeded by V012.
//
// The migration has one decision that is easy to get wrong silently: it
// makes Plum & Rose the scripture default on a fresh install and must NOT
// do so on an upgrade, where an operator who never picked a default is
// implicitly on Classic Dark and would see their projection change. Both
// paths are driven here through the real Migrator.

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

class TestScriptureThemes : public QObject
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
        auto q = conn.prepare(u"SELECT id FROM themes WHERE kind = 'scripture' AND is_builtin = 1 AND name = ?");
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
        QCOMPARE(themes.defaultFor(QStringLiteral("scripture")).name, QStringLiteral("Plum & Rose"));
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
            QCOMPARE(themes.validateTokens(t.tokens), QStringList());
            // Reference and verse both render, which is the point of the design.
            QStringList linkages;
            for (const QVariant& n : themes.layoutNodes(t.tokens, QString()))
                linkages << n.toMap().value(QStringLiteral("data")).toMap().value(QStringLiteral("linkage")).toString();
            QVERIFY2(linkages.contains(QStringLiteral("scriptureRef")), qPrintable(name));
            QVERIFY2(linkages.contains(QStringLiteral("scriptureText")), qPrintable(name));
        }
    }

    void verseNumberColorMustBeDslHex()
    {
        freshDataDir();
        crater::runAllMigrations();
        crater::ThemeService themes;
        const crater::Theme t = themes.theme(builtinId(QStringLiteral("Plum & Rose")));
        auto withColor = [&](const QString& c) {
            QVariantMap tokens = t.tokens;
            QVariantList layouts = tokens.value(QStringLiteral("layouts")).toList();
            QVariantMap layout = layouts.first().toMap();
            QVariantList nodes = layout.value(QStringLiteral("nodes")).toList();
            for (QVariant& n : nodes) {
                QVariantMap node = n.toMap();
                if (node.value(QStringLiteral("id")) != QStringLiteral("verse")) continue;
                QVariantMap data = node.value(QStringLiteral("data")).toMap();
                data.insert(QStringLiteral("verseNumberColor"), c);
                node.insert(QStringLiteral("data"), data);
                n = node;
            }
            layout.insert(QStringLiteral("nodes"), nodes);
            layouts[0] = layout;
            tokens.insert(QStringLiteral("layouts"), layouts);
            return themes.validateTokens(tokens);
        };
        QCOMPARE(withColor(QStringLiteral("#f29cac")), QStringList());
        QCOMPARE(withColor(QStringLiteral("#fff")), QStringList());
        // The DSL has no alpha, so the projector would silently show gold.
        QCOMPARE(withColor(QStringLiteral("#80f29cac")).size(), 1);
        QCOMPARE(withColor(QStringLiteral("rose")).size(), 1);
    }

    void upgradeKeepsTheCurrentDefault()
    {
        // An install that last ran V011 a while ago: Classic Dark is old and
        // no default was ever chosen.
        freshDataDir();
        crater::runAllMigrations();
        {
            crater::db::Connection conn(crater::db::DbPaths::appDbPath());
            conn.exec(u"DELETE FROM kv WHERE key = 'default_scripture_theme_id'");
            conn.exec(u"DELETE FROM themes WHERE name IN ('Plum & Rose', 'Graphite & Cyan')");
            conn.exec(u"UPDATE themes SET created_at = created_at - 86400000");
            conn.setUserVersion(11);
        }
        crater::runAllMigrations();

        QVERIFY(builtinId(QStringLiteral("Plum & Rose")) != 0);
        QVERIFY(builtinId(QStringLiteral("Graphite & Cyan")) != 0);
        crater::ThemeService themes;
        QCOMPARE(themes.defaultFor(QStringLiteral("scripture")).name, QStringLiteral("Classic Dark"));
    }

    void upgradeNeverOverridesAChosenDefault()
    {
        freshDataDir();
        crater::runAllMigrations();
        const qint64 cyan = builtinId(QStringLiteral("Graphite & Cyan"));
        {
            crater::ThemeService themes;
            themes.setDefaultFor(QStringLiteral("scripture"), cyan);
        }
        {
            crater::db::Connection conn(crater::db::DbPaths::appDbPath());
            conn.setUserVersion(11);
        }
        crater::runAllMigrations();
        crater::ThemeService themes;
        QCOMPARE(themes.defaultFor(QStringLiteral("scripture")).id, cyan);
    }
};

// ThemeService touches QFontDatabase, which needs a QGuiApplication.
int main(int argc, char* argv[])
{
    QGuiApplication app(argc, argv);
    TestScriptureThemes tc;
    return QTest::qExec(&tc, argc, argv);
}

#include "test_scripture_themes.moc"
