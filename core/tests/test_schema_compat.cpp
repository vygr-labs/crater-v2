// Opening data from a newer Crater.
//
// A migration marked "-- @readable-by-older-versions" only adds things an
// older build ignores. Each DB records the oldest schema version that can
// read it and the Crater version that migrated it, so an older build opens
// data it can safely use, and for the rest says which version to install
// instead of failing with nothing on screen.
//
// Runs the real app migrations, where V013 is marked and V012 is not, so a
// fully migrated app DB is readable from v12.

#include <QDir>
#include <QFile>
#include <QObject>
#include <QStandardPaths>
#include <QString>
#include <QTest>

#include "crater/Bootstrap.h"
#include "crater/Version.h"

#include "db/Connection.h"
#include "db/DbPaths.h"
#include "db/Migrator.h"
#include "db/Statement.h"

#include <algorithm>

using crater::db::Connection;
using crater::db::Migrator;
using crater::db::NewerSchemaError;

class TestSchemaCompat : public QObject
{
    Q_OBJECT

private:
    QString m_dir;
    QString m_path;

    static qint64 highestAppVersion()
    {
        qint64 highest = 0;
        for (const QString& f : QDir(QStringLiteral(":/migrations/app")).entryList({QStringLiteral("V*.sql")}))
            highest = std::max(highest, f.mid(1, f.indexOf(u'_') - 1).toLongLong());
        return highest;
    }

    static QString value(Connection& c, const QString& key)
    {
        auto s = c.prepare(u"SELECT value FROM crater_schema WHERE key = ?");
        s.bind(1, key);
        return s.step() ? s.columnText(0) : QString();
    }

    static void setValue(Connection& c, const QString& key, const QString& v)
    {
        c.prepare(u"INSERT OR REPLACE INTO crater_schema (key, value) VALUES (?, ?)")
            .bind(1, key).bind(2, v).step();
    }

    // A fully migrated app DB, then pretend a newer Crater moved it on.
    void newerDb(qint64 version, const QString& oldestReader, const QString& writtenBy)
    {
        QFile::remove(m_path);
        Connection c(m_path);
        Migrator::run(c, u"app");
        if (oldestReader.isNull()) {
            c.exec(u"DROP TABLE crater_schema");
        } else {
            setValue(c, QStringLiteral("oldest_reader_version"), oldestReader);
            setValue(c, QStringLiteral("written_by"), writtenBy);
        }
        c.setUserVersion(version);
    }

private slots:
    void initTestCase()
    {
        QStandardPaths::setTestModeEnabled(true);
        m_dir = QDir(QStandardPaths::writableLocation(QStandardPaths::AppDataLocation))
                    .filePath(QStringLiteral("schema-compat"));
        QDir(m_dir).removeRecursively();
        QVERIFY(QDir().mkpath(m_dir));
        m_path = QDir(m_dir).filePath(QStringLiteral("app.sqlite"));
        QVERIFY(highestAppVersion() >= 13);
    }

    void cleanupTestCase() { QDir(m_dir).removeRecursively(); }

    void migratingRecordsWhoCanReadIt()
    {
        QFile::remove(m_path);
        Connection c(m_path);
        Migrator::run(c, u"app");
        QCOMPARE(c.userVersion(), highestAppVersion());
        // V013 is readable by older versions, so a v12 build can read it.
        QCOMPARE(value(c, QStringLiteral("oldest_reader_version")), QStringLiteral("12"));
        QCOMPARE(value(c, QStringLiteral("written_by")), crater::versionString());
    }

    void dataFromBeforeTheRecordGetsOne()
    {
        Connection c(m_path);
        c.exec(u"DROP TABLE crater_schema");
        Migrator::run(c, u"app");
        QCOMPARE(value(c, QStringLiteral("oldest_reader_version")), QStringLiteral("12"));
        QCOMPARE(value(c, QStringLiteral("written_by")), crater::versionString());
    }

    void newerReadableDataOpensUnchanged()
    {
        const qint64 newer = highestAppVersion() + 1;
        newerDb(newer, QString::number(highestAppVersion()), QStringLiteral("9.9.9"));
        Connection c(m_path);
        Migrator::run(c, u"app");   // must not throw
        QCOMPARE(c.userVersion(), newer);
        QCOMPARE(value(c, QStringLiteral("written_by")), QStringLiteral("9.9.9"));
        QCOMPARE(value(c, QStringLiteral("oldest_reader_version")), QString::number(highestAppVersion()));
    }

    void newerUnreadableDataNamesTheVersion()
    {
        const qint64 newer = highestAppVersion() + 1;
        newerDb(newer, QString::number(newer), QStringLiteral("9.9.9"));
        Connection c(m_path);
        try {
            Migrator::run(c, u"app");
            QFAIL("expected NewerSchemaError");
        } catch (const NewerSchemaError& e) {
            QCOMPARE(e.writtenBy(), QStringLiteral("9.9.9"));
        }
        QCOMPARE(c.userVersion(), newer);
    }

    void newerDataWithNoRecordIsRefused()
    {
        const qint64 newer = highestAppVersion() + 1;
        newerDb(newer, QString(), QString());
        Connection c(m_path);
        try {
            Migrator::run(c, u"app");
            QFAIL("expected NewerSchemaError");
        } catch (const NewerSchemaError& e) {
            QVERIFY(e.writtenBy().isEmpty());
        }
    }

    void startupReportsNewerData()
    {
        // runAllMigrations works on the test-mode data folder.
        const QString app = crater::db::DbPaths::appDbPath();
        QFile::remove(app);
        {
            Connection c(app);
            Migrator::run(c, u"app");
            setValue(c, QStringLiteral("oldest_reader_version"), QStringLiteral("999"));
            setValue(c, QStringLiteral("written_by"), QStringLiteral("9.9.9"));
            c.setUserVersion(999);
        }
        try {
            crater::runAllMigrations();
            QFAIL("expected NewerDataError");
        } catch (const crater::NewerDataError& e) {
            QCOMPARE(e.writtenBy(), QStringLiteral("9.9.9"));
        }
        QFile::remove(app);
    }
};

QTEST_GUILESS_MAIN(TestSchemaCompat)
#include "test_schema_compat.moc"
