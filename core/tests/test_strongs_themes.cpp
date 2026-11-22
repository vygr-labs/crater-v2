// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2024-2026 Eyetu Kingsley. Part of Crater, see LICENSE and NOTICE.

// Strong's themes: the 'strongs' theme kind V015 adds, the Lexicon theme it
// seeds, and how the Strong's default is chosen on a fresh install and on
// an upgrade (scripts/gen-strongs-themes.py has the reasoning).

#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QObject>
#include <QStandardPaths>
#include <QTest>

#include "crater/Bootstrap.h"
#include "crater/ThemeService.h"

#include "db/Connection.h"
#include "db/DbPaths.h"
#include "db/Statement.h"

namespace {

const QString kLexicon = QStringLiteral("Lexicon");

QVariantMap tokensFrom(const QString& json)
{
    return QJsonDocument::fromJson(json.toUtf8()).toVariant().toMap();
}

// One text node per Strong's slot.
QVariantMap strongsTokens()
{
    return tokensFrom(QStringLiteral(R"({
        "version": 3, "canvas": {"width": 1920, "height": 1080},
        "layouts": [{"id": "content", "name": "Content", "default": true, "nodes": [
            {"id": "w", "kind": "text", "style": {"x": 5, "y": 5, "width": 90, "height": 10, "color": "#ffffff"},
             "data": {"linkage": "strongsWord"}},
            {"id": "p", "kind": "text", "style": {"x": 5, "y": 16, "width": 90, "height": 5, "color": "#ffffff"},
             "data": {"linkage": "strongsPartOfSpeech"}},
            {"id": "t", "kind": "text", "style": {"x": 5, "y": 25, "width": 90, "height": 60, "color": "#ffffff"},
             "data": {"linkage": "strongsText"}},
            {"id": "n", "kind": "text", "style": {"x": 70, "y": 90, "width": 25, "height": 5, "color": "#ffffff"},
             "data": {"linkage": "strongsPage"}}
        ]}]})"));
}

QVariantMap scriptureTokens(const QString& color)
{
    return tokensFrom(QStringLiteral(R"({
        "version": 3, "canvas": {"width": 1920, "height": 1080},
        "layouts": [{"id": "content", "name": "Content", "default": true, "nodes": [
            {"id": "r", "kind": "text", "style": {"x": 5, "y": 5, "width": 90, "height": 10, "color": "%1"},
             "data": {"linkage": "scriptureRef"}},
            {"id": "v", "kind": "text", "style": {"x": 5, "y": 25, "width": 90, "height": 60, "color": "%1"},
             "data": {"linkage": "scriptureText"}}
        ]}]})").arg(color));
}

}  // namespace

class TestStrongsThemes : public QObject
{
    Q_OBJECT

private:
    QString m_dataDir;

    void freshDataDir()
    {
        QDir(m_dataDir).removeRecursively();
        QDir().mkpath(m_dataDir);
    }

    static qint64 scalar(const QString& sql)
    {
        crater::db::Connection conn(crater::db::DbPaths::appDbPath());
        auto q = conn.prepare(sql);
        return q.step() ? q.columnInt64(0) : -1;
    }

    // Make the current database look like one that last ran `version` a
    // day ago: what an upgrade sees.
    static void ageTo(int version)
    {
        crater::db::Connection conn(crater::db::DbPaths::appDbPath());
        conn.exec(u"UPDATE themes SET created_at = created_at - 86400000");
        conn.setUserVersion(version);
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

    void freshInstallUsesLexicon()
    {
        freshDataDir();
        crater::runAllMigrations();
        crater::ThemeService themes;
        const crater::Theme t = themes.defaultFor(QStringLiteral("strongs"));
        QCOMPARE(t.name, kLexicon);
        QCOMPARE(t.kind, QStringLiteral("strongs"));
        QVERIFY(t.isBuiltin);
        QCOMPARE(themes.validateTokens(t.tokens), QStringList());
        // Fresh: no stored Strong's default and no copied theme, and the
        // other defaults are as they were.
        QCOMPARE(scalar(QStringLiteral("SELECT count(*) FROM kv WHERE key = 'default_strongs_theme_id'")), 0);
        QCOMPARE(scalar(QStringLiteral("SELECT count(*) FROM themes WHERE kind = 'strongs' AND is_builtin = 0")), 0);
        QCOMPARE(themes.defaultFor(QStringLiteral("scripture")).name, QStringLiteral("Plum & Rose"));
    }

    void lexiconBindsEveryStrongsSlot()
    {
        freshDataDir();
        crater::runAllMigrations();
        crater::ThemeService themes;
        const crater::Theme t = themes.defaultFor(QStringLiteral("strongs"));
        QStringList linkages;
        for (const QVariant& v : themes.layoutNodes(t.tokens, QString()))
            linkages << v.toMap().value(QStringLiteral("data")).toMap().value(QStringLiteral("linkage")).toString();
        for (const char* l : { "strongsWord", "strongsPartOfSpeech", "strongsText", "strongsPage" })
            QVERIFY2(linkages.contains(QLatin1String(l)), l);
    }

    // Before V015 Strong's showed the scripture default. An upgrade keeps
    // that look: the theme is copied as a Strong's theme and made the
    // Strong's default, and scripture keeps its own.
    void upgradeCopiesTheScriptureDefault()
    {
        freshDataDir();
        crater::runAllMigrations();
        qint64 ours = 0;
        {
            crater::ThemeService themes;
            ours = themes.create(QStringLiteral("scripture"), QStringLiteral("Our Church"),
                                 scriptureTokens(QStringLiteral("#ffcc00")));
            QVERIFY(ours > 0);
            themes.setDefaultFor(QStringLiteral("scripture"), ours);
        }
        {
            crater::db::Connection conn(crater::db::DbPaths::appDbPath());
            conn.exec(u"DELETE FROM themes WHERE kind = 'strongs'");
        }
        ageTo(14);
        crater::runAllMigrations();

        crater::ThemeService themes;
        const crater::Theme s = themes.defaultFor(QStringLiteral("strongs"));
        QCOMPARE(s.name, QStringLiteral("Our Church (Strong's)"));
        QCOMPARE(s.kind, QStringLiteral("strongs"));
        QVERIFY(!s.isBuiltin);
        QCOMPARE(QJsonDocument::fromVariant(s.tokens).toJson(QJsonDocument::Compact),
                 QJsonDocument::fromVariant(themes.theme(ours).tokens).toJson(QJsonDocument::Compact));
        QCOMPARE(themes.defaultFor(QStringLiteral("scripture")).id, ours);
        QVERIFY(scalar(QStringLiteral("SELECT count(*) FROM themes WHERE kind = 'strongs' AND is_builtin = 1 AND name = 'Lexicon'")) == 1);

        // Changing the Strong's copy leaves scripture alone.
        themes.update(s.id, s.name, scriptureTokens(QStringLiteral("#00ccff")));
        QVERIFY(QJsonDocument::fromVariant(themes.theme(ours).tokens).toJson().contains("#ffcc00"));
    }

    void upgradeWithoutAStoredDefaultCopiesTheBuiltIn()
    {
        freshDataDir();
        crater::runAllMigrations();
        {
            crater::db::Connection conn(crater::db::DbPaths::appDbPath());
            conn.exec(u"DELETE FROM themes WHERE kind = 'strongs'");
            conn.exec(u"DELETE FROM kv WHERE key = 'default_scripture_theme_id'");
        }
        ageTo(14);
        crater::runAllMigrations();
        crater::ThemeService themes;
        QCOMPARE(themes.defaultFor(QStringLiteral("strongs")).name, QStringLiteral("Classic Dark (Strong's)"));
    }

    // The CHECK on themes.kind can only change by rebuilding the table. Every
    // row keeps its id, and an id freed by a deleted theme is not reused.
    void rebuildKeepsIdsAndTheSequence()
    {
        freshDataDir();
        crater::runAllMigrations();
        QList<QPair<qint64, QString>> before;
        qint64 deleted = 0;
        {
            crater::ThemeService themes;
            deleted = themes.create(QStringLiteral("song"), QStringLiteral("Temp"),
                                    scriptureTokens(QStringLiteral("#ffffff")));
            crater::db::Connection conn(crater::db::DbPaths::appDbPath());
            auto del = conn.prepare(u"DELETE FROM themes WHERE id = ?");
            del.bind(1, deleted);
            del.step();
            auto q = conn.prepare(u"SELECT id, name FROM themes ORDER BY id");
            while (q.step()) before.append({ q.columnInt64(0), q.columnText(1) });
        }
        ageTo(14);
        crater::runAllMigrations();
        {
            crater::db::Connection conn(crater::db::DbPaths::appDbPath());
            auto q = conn.prepare(u"SELECT id, name FROM themes WHERE id <= ? ORDER BY id");
            q.bind(1, before.last().first);
            QList<QPair<qint64, QString>> after;
            while (q.step()) after.append({ q.columnInt64(0), q.columnText(1) });
            QCOMPARE(after, before);
        }
        crater::ThemeService themes;
        const qint64 next = themes.create(QStringLiteral("strongs"), QStringLiteral("Mine"), strongsTokens());
        QVERIFY2(next > deleted, qPrintable(QStringLiteral("%1 vs %2").arg(next).arg(deleted)));
    }

    void strongsThemesSaveAndValidate()
    {
        freshDataDir();
        crater::runAllMigrations();
        crater::ThemeService themes;
        QCOMPARE(themes.validateTokens(strongsTokens()), QStringList());
        const qint64 id = themes.create(QStringLiteral("strongs"), QStringLiteral("Mine"), strongsTokens());
        QVERIFY(id > 0);
        QCOMPARE(themes.theme(id).kind, QStringLiteral("strongs"));
        themes.setDefaultFor(QStringLiteral("strongs"), id);
        QCOMPARE(themes.defaultFor(QStringLiteral("strongs")).id, id);
        // The scripture default is a separate choice.
        QVERIFY(themes.defaultFor(QStringLiteral("scripture")).id != id);
    }

    // A theme file of kind "strongs" imports (the Design with AI paste and
    // a .theme.json file share this path).
    void strongsThemeFileImports()
    {
        freshDataDir();
        crater::runAllMigrations();
        const QString path = QDir(m_dataDir).filePath(QStringLiteral("mine.theme.json"));
        {
            QFile f(path);
            QVERIFY(f.open(QIODevice::WriteOnly));
            QVariantMap env{ { QStringLiteral("name"), QStringLiteral("From a file") },
                             { QStringLiteral("kind"), QStringLiteral("strongs") },
                             { QStringLiteral("tokens"), strongsTokens() } };
            f.write(QJsonDocument::fromVariant(env).toJson());
        }
        crater::ThemeService themes;
        const qint64 id = themes.importThemeJsonFile(path);
        QVERIFY2(id > 0, qPrintable(themes.lastImportError()));
        QCOMPARE(themes.theme(id).kind, QStringLiteral("strongs"));
    }
};

QTEST_MAIN(TestStrongsThemes)
#include "test_strongs_themes.moc"
