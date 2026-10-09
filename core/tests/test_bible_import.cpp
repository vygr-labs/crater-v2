// Bundled Bible import, first run and upgrade.
//
// The first run copies every translation in the bundled bibles.sqlite into
// the shared library. A later release can ship a different set, so an
// install that already ran the first import (.imported-v1) only takes the
// translations it doesn't have yet: what it has is left exactly as is, and
// the search index gains the new translations without duplicating the old.
//
// The bundled file is found by walking up from the executable, so each test
// writes its fixture to <test-exe-dir>/legacy/bibles.sqlite, which is checked
// before anything further up the tree.

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QObject>
#include <QStandardPaths>
#include <QString>
#include <QTest>

#include "crater/Bootstrap.h"
#include "crater/ElectronDataImporter.h"

#include "db/Connection.h"
#include "db/DbPaths.h"
#include "db/Statement.h"

using crater::db::Connection;
using crater::db::DbPaths;

class TestBibleImport : public QObject
{
    Q_OBJECT

private:
    QString m_dataDir;

    static QString legacyDir()
    {
        return QDir(QCoreApplication::applicationDirPath()).filePath(QStringLiteral("legacy"));
    }

    // A bundled file in the Electron layout with Genesis 1:1 and John 3:16
    // for each translation, the text being "<word> <code>".
    static void writeLegacy(const QList<QPair<QString, QString>>& translations)
    {
        QDir().mkpath(legacyDir());
        const QString path = QDir(legacyDir()).filePath(QStringLiteral("bibles.sqlite"));
        QFile::remove(path);
        Connection c(path);
        c.exec(u"CREATE TABLE bibles (id INTEGER PRIMARY KEY AUTOINCREMENT, version TEXT UNIQUE NOT NULL, description TEXT)");
        c.exec(u"CREATE TABLE books (id INTEGER PRIMARY KEY AUTOINCREMENT, book_name TEXT UNIQUE NOT NULL)");
        c.exec(u"CREATE TABLE scriptures (id INTEGER PRIMARY KEY AUTOINCREMENT, bible_id INTEGER NOT NULL, "
               u"book_id INTEGER NOT NULL, book_name TEXT NOT NULL, version TEXT NOT NULL, "
               u"chapter INTEGER NOT NULL, verse TEXT NOT NULL, text TEXT NOT NULL)");
        c.exec(u"INSERT INTO books (book_name) VALUES ('genesis'), ('john')");
        for (const auto& [code, word] : translations) {
            c.prepare(u"INSERT INTO bibles (version, description) VALUES (?, ?)")
                .bind(1, code).bind(2, code + QStringLiteral(" Bible")).step();
            const qint64 id = c.lastInsertRowId();
            auto verse = [&](qint64 bookId, const QString& book, int chapter, const QString& number) {
                c.prepare(u"INSERT INTO scriptures (bible_id, book_id, book_name, version, chapter, verse, text) "
                          u"VALUES (?, ?, ?, ?, ?, ?, ?)")
                    .bind(1, id).bind(2, bookId).bind(3, book).bind(4, code).bind(5, chapter)
                    .bind(6, number).bind(7, QStringLiteral("%1 %2").arg(word, code)).step();
            };
            verse(1, QStringLiteral("genesis"), 1, QStringLiteral("1"));
            verse(2, QStringLiteral("john"), 3, QStringLiteral("16"));
        }
    }

    static bool runImport()
    {
        crater::ElectronDataImporter importer;
        auto future = importer.run();
        future.waitForFinished();
        return future.result();
    }

    static qint64 scalar(QStringView sql, const QString& arg = {})
    {
        Connection c(DbPaths::biblesDbPath());
        auto s = c.prepare(sql);
        if (!arg.isNull()) s.bind(1, arg);
        return s.step() ? s.columnInt64(0) : -1;
    }

    static QString verseText(const QString& code)
    {
        Connection c(DbPaths::biblesDbPath());
        auto s = c.prepare(u"SELECT v.text FROM verses v JOIN translations t ON t.id = v.translation_id "
                           u"WHERE t.code = ? AND v.chapter = 3 AND v.verse = 16");
        s.bind(1, code);
        return s.step() ? s.columnText(0) : QString();
    }

    static qint64 searchHits(const QString& word)
    {
        return scalar(u"SELECT COUNT(*) FROM verses_fts WHERE verses_fts MATCH ?", word);
    }

    static void markAsFirstSetInstall()
    {
        QFile::remove(DbPaths::importSentinelPath());
        QFile f(DbPaths::previousImportSentinelPath());
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write("v1\n");
    }

private slots:
    void initTestCase()
    {
        QStandardPaths::setTestModeEnabled(true);
        m_dataDir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
        QVERIFY(!m_dataDir.isEmpty());
        QDir(m_dataDir).removeRecursively();
        crater::runAllMigrations();
    }

    void cleanupTestCase()
    {
        QDir(legacyDir()).removeRecursively();
        QDir(m_dataDir).removeRecursively();
    }

    void firstRunImportsEverything()
    {
        writeLegacy({{QStringLiteral("AAA"), QStringLiteral("alpha")}});
        crater::ElectronDataImporter importer;
        QVERIFY(importer.needsImport());
        QVERIFY(runImport());

        QVERIFY(QFile::exists(DbPaths::importSentinelPath()));
        QVERIFY(!crater::ElectronDataImporter().needsImport());
        QCOMPARE(scalar(u"SELECT COUNT(*) FROM verses v JOIN translations t ON t.id = v.translation_id "
                        u"WHERE t.code = 'AAA'"), 2);
        QCOMPARE(searchHits(QStringLiteral("alpha")), 2);
    }

    void upgradeAddsOnlyMissingTranslations()
    {
        markAsFirstSetInstall();
        QVERIFY(crater::ElectronDataImporter().needsImport());
        // The new bundled file changes AAA's text and adds BBB.
        writeLegacy({{QStringLiteral("AAA"), QStringLiteral("changed")},
                     {QStringLiteral("BBB"), QStringLiteral("bravo")}});
        QVERIFY(runImport());

        QVERIFY(QFile::exists(DbPaths::importSentinelPath()));
        QCOMPARE(verseText(QStringLiteral("AAA")), QStringLiteral("alpha AAA"));
        QCOMPARE(verseText(QStringLiteral("BBB")), QStringLiteral("bravo BBB"));
        QCOMPARE(searchHits(QStringLiteral("alpha")), 2);    // not indexed twice
        QCOMPARE(searchHits(QStringLiteral("bravo")), 2);
        QCOMPARE(searchHits(QStringLiteral("changed")), 0);
        QVERIFY(scalar(u"SELECT sort_order FROM translations WHERE code = ?", QStringLiteral("BBB"))
                > scalar(u"SELECT sort_order FROM translations WHERE code = ?", QStringLiteral("AAA")));
    }

    void upgradeWithNothingNewChangesNothing()
    {
        markAsFirstSetInstall();
        const qint64 verses = scalar(u"SELECT COUNT(*) FROM verses");
        QVERIFY(runImport());

        QVERIFY(QFile::exists(DbPaths::importSentinelPath()));
        QCOMPARE(scalar(u"SELECT COUNT(*) FROM verses"), verses);
        QCOMPARE(searchHits(QStringLiteral("bravo")), 2);
    }
};

QTEST_GUILESS_MAIN(TestBibleImport)
#include "test_bible_import.moc"
