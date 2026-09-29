// A data folder restored somewhere else must keep its media (issue #14).
//
// Rows store the absolute path a managed file had at import time. Restoring
// the data folder under another user profile leaves every one of those paths
// pointing at a folder that no longer exists. These tests fake that by
// rewriting the stored paths to a foreign profile, then check that the startup
// orphan sweep keeps the files and that every reader finds them again.
//
// Run via CTest: `ctest --test-dir <build-dir> -R media_relocation --output-on-failure`

#include <QByteArray>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QObject>
#include <QStandardPaths>
#include <QString>
#include <QTemporaryDir>
#include <QTest>
#include <QVariantMap>

#include "crater/Bootstrap.h"
#include "crater/MediaService.h"
#include "crater/ProjectionService.h"
#include "crater/ScheduleService.h"

#include "db/Connection.h"
#include "db/DbPaths.h"
#include "db/Statement.h"

using crater::MediaService;
using crater::ProjectionService;
using crater::ScheduleService;
using crater::db::DbPaths;

namespace {

// Real PNG magic bytes are all MediaService's sniff looks at.
QByteArray fakeImage(const QByteArray& tag)
{
    QByteArray b("\x89PNG\r\n\x1a\n", 8);
    b += tag;
    return b;
}

// Where the same file would have lived under another Windows profile.
QString foreignPath(const QString& fileName)
{
    return QStringLiteral("C:/Users/SomeoneElse/AppData/Roaming/Voyager Labs/Crater/media/")
         + fileName;
}

}  // namespace

class TestMediaRelocation : public QObject
{
    Q_OBJECT

private:
    QString m_dataDir;

    void resetState()
    {
        QDir(m_dataDir).removeRecursively();
        QDir().mkpath(m_dataDir);
    }

    // Import a fake picture and return its managed path.
    QString importPicture(MediaService& media, const QByteArray& tag)
    {
        QTemporaryDir tmp;
        const QString src = tmp.filePath(QStringLiteral("%1.png").arg(QString::fromLatin1(tag)));
        QFile f(src);
        if (!f.open(QIODevice::WriteOnly)) return {};
        f.write(fakeImage(tag));
        f.close();
        const qint64 id = media.importPathSync(src);
        if (id <= 0) return {};
        return media.byId(id).path;
    }

    // Rewrite every stored media path as if the data folder came from
    // another profile.
    void pointRowsAtForeignProfile()
    {
        crater::db::Connection conn(DbPaths::appDbPath(),
                                    crater::db::OpenMode::ReadWrite,
                                    QStringLiteral("test"));
        auto sel = conn.prepare(u"SELECT id, path FROM media");
        QList<QPair<qint64, QString>> rows;
        while (sel.step())
            rows.append({ sel.columnInt64(0), QFileInfo(sel.columnText(1)).fileName() });
        sel.reset();
        auto upd = conn.prepare(u"UPDATE media SET path = ? WHERE id = ?");
        for (const auto& [id, name] : rows) {
            upd.reset();
            upd.bind(1, foreignPath(name));
            upd.bind(2, id);
            upd.step();
        }
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

    void relocateFindsManagedCopy()
    {
        resetState();
        const QString dir = DbPaths::mediaDir();
        QFile f(QDir(dir).filePath(QStringLiteral("here.png")));
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.close();

        QCOMPARE(DbPaths::relocate(foreignPath(QStringLiteral("here.png")), dir),
                 QDir::cleanPath(QDir(dir).filePath(QStringLiteral("here.png"))));
        // No managed copy: the stored path comes back untouched.
        QCOMPARE(DbPaths::relocate(foreignPath(QStringLiteral("gone.png")), dir),
                 foreignPath(QStringLiteral("gone.png")));
        QCOMPARE(DbPaths::relocate(QString(), dir), QString());
    }

    void sweepKeepsFilesAfterRestore()
    {
        resetState();
        crater::runAllMigrations();

        QString kept;
        {
            MediaService media;
            kept = importPicture(media, "keep");
            QVERIFY(!kept.isEmpty());
            QVERIFY(QFile::exists(kept));
        }

        pointRowsAtForeignProfile();

        // A genuinely orphaned file (no row) must still be reclaimed.
        const QString orphan = QDir(DbPaths::mediaDir()).filePath(QStringLiteral("orphan.png"));
        {
            QFile f(orphan);
            QVERIFY(f.open(QIODevice::WriteOnly));
            f.write(fakeImage("orphan"));
        }

        MediaService media;
        media.sweepOrphans();

        QVERIFY2(QFile::exists(kept), "sweep deleted a file its row still references");
        QVERIFY2(!QFile::exists(orphan), "sweep left a real orphan behind");

        const auto all = media.allMedia();
        QCOMPARE(all.size(), 1);
        QCOMPARE(QDir::cleanPath(all.first().path), QDir::cleanPath(kept));
        // The "File size" sort reads this (issue #19); it has to come from
        // the relocated file, not the stale path.
        QCOMPARE(all.first().fileSize, qint64(fakeImage("keep").size()));
    }

    void removeDeletesRelocatedFile()
    {
        resetState();
        crater::runAllMigrations();

        QString path;
        qint64 id = 0;
        {
            MediaService media;
            path = importPicture(media, "remove-me");
            QVERIFY(!path.isEmpty());
            id = media.allMedia().first().id;
        }
        pointRowsAtForeignProfile();

        MediaService media;
        media.remove(id);
        QVERIFY2(!QFile::exists(path), "remove() left the managed file behind");
    }

    void scheduleAndLogoFollowTheFolder()
    {
        resetState();
        crater::runAllMigrations();

        QString path;
        {
            MediaService media;
            path = importPicture(media, "stage");
            QVERIFY(!path.isEmpty());
        }
        const QString stale = foreignPath(QFileInfo(path).fileName());

        {
            ScheduleService schedule;
            schedule.addItem(QVariantMap{ { QStringLiteral("kind"), QStringLiteral("image") },
                                          { QStringLiteral("title"), QStringLiteral("Stage") },
                                          { QStringLiteral("mediaPath"), stale } });
            ProjectionService projection;
            projection.setLogoBg(stale, QStringLiteral("image"));
        }   // destructors persist the working schedule

        ScheduleService schedule;
        const auto items = schedule.currentItems();
        QCOMPARE(items.size(), 1);
        QCOMPARE(QDir::cleanPath(items.first().toMap().value(QStringLiteral("mediaPath")).toString()),
                 QDir::cleanPath(path));

        ProjectionService projection;
        QCOMPARE(QDir::cleanPath(projection.logoBgPath()), QDir::cleanPath(path));
    }
};

int main(int argc, char* argv[])
{
    QGuiApplication app(argc, argv);
    TestMediaRelocation tc;
    return QTest::qExec(&tc, argc, argv);
}

#include "test_media_relocation.moc"
