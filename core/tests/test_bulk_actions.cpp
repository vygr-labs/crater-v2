// Batch service calls behind the library and schedule multi-select.
//
// Each one replaces a QML loop over a single-item call, so these pin that the
// batch does exactly what the loop did (same rows gone, FTS index still
// consistent, files cleaned up) and that it reports one change, not one per
// item, which is the reason the batch calls exist.
//
// Run via CTest: `ctest --test-dir <build-dir> -R bulk_actions --output-on-failure`

#include <QByteArray>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QObject>
#include <QSignalSpy>
#include <QStandardPaths>
#include <QString>
#include <QTemporaryDir>
#include <QTest>
#include <QVariantList>
#include <QVariantMap>

#include "crater/Bootstrap.h"
#include "crater/MediaService.h"
#include "crater/ScheduleService.h"
#include "crater/SongService.h"

using crater::MediaService;
using crater::ScheduleService;
using crater::SongService;

namespace {

QVariantList verse(const QString& line)
{
    return QVariantList{ QVariantMap{
        { QStringLiteral("label"), QStringLiteral("Verse 1") },
        { QStringLiteral("kind"),  QStringLiteral("verse") },
        { QStringLiteral("lines"), QStringList{ line } },
    } };
}

qint64 makeSong(SongService& songs, const QString& title, const QString& line)
{
    return songs.createWithSections(title, QString(), QString(), 0, verse(line), QString());
}

bool hasSong(const QList<crater::Song>& list, qint64 id)
{
    for (const auto& s : list) if (s.id == id) return true;
    return false;
}

QVariantMap row(const QString& title)
{
    return QVariantMap{ { QStringLiteral("kind"),  QStringLiteral("song") },
                        { QStringLiteral("title"), title } };
}

QStringList titles(const ScheduleService& schedule)
{
    QStringList out;
    for (const QVariant& v : schedule.currentItems())
        out << v.toMap().value(QStringLiteral("title")).toString();
    return out;
}

}  // namespace

class TestBulkActions : public QObject
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

    // ── Songs ───────────────────────────────────────────────────────────

    void destroyManyRemovesOnlyTheGivenSongsInOneSignal()
    {
        SongService songs;
        const qint64 a = makeSong(songs, QStringLiteral("Alpha"),   QStringLiteral("zebracorn meadow"));
        const qint64 b = makeSong(songs, QStringLiteral("Bravo"),   QStringLiteral("zebracorn river"));
        const qint64 c = makeSong(songs, QStringLiteral("Charlie"), QStringLiteral("zebracorn mountain"));
        QVERIFY(a > 0 && b > 0 && c > 0);

        QSignalSpy spy(&songs, &SongService::allSongsChanged);
        // A missing id and a junk entry are skipped, not counted.
        const int removed = songs.destroyMany(QVariantList{ a, c, qint64(999999), QStringLiteral("x") });
        QCOMPARE(removed, 2);
        QCOMPARE(spy.count(), 1);

        const auto all = songs.allSongs();
        QVERIFY(!hasSong(all, a));
        QVERIFY( hasSong(all, b));
        QVERIFY(!hasSong(all, c));

        // Search agrees: the lyric word all three shared finds only the
        // survivor.
        const auto hits = songs.search(QStringLiteral("zebracorn"));
        QCOMPARE(hits.size(), 1);
        QCOMPARE(hits.first().id, b);
    }

    void destroyManyWithNothingToDoStaysQuiet()
    {
        SongService songs;
        QSignalSpy spy(&songs, &SongService::allSongsChanged);
        QCOMPARE(songs.destroyMany({}), 0);
        QCOMPARE(songs.destroyMany(QVariantList{ qint64(424242) }), 0);
        QCOMPARE(spy.count(), 0);
    }

    void setThemeForSongsSetsAndClears()
    {
        SongService songs;
        const qint64 a = makeSong(songs, QStringLiteral("Delta"), QStringLiteral("one"));
        const qint64 b = makeSong(songs, QStringLiteral("Echo"),  QStringLiteral("two"));
        const qint64 c = makeSong(songs, QStringLiteral("Fox"),   QStringLiteral("three"));

        QSignalSpy spy(&songs, &SongService::allSongsChanged);
        QCOMPARE(songs.setThemeForSongs(QVariantList{ a, b }, 7), 2);
        QCOMPARE(spy.count(), 1);
        QCOMPARE(songs.fetchSong(a).themeId, qint64(7));
        QCOMPARE(songs.fetchSong(b).themeId, qint64(7));
        QCOMPARE(songs.fetchSong(c).themeId, qint64(0));

        // 0 clears back to "use the default" and keeps the lyrics intact.
        QCOMPARE(songs.setThemeForSongs(QVariantList{ a }, 0), 1);
        QCOMPARE(songs.fetchSong(a).themeId, qint64(0));
        QCOMPARE(songs.fetchSong(a).sections.size(), 1);
    }

    // ── Media ───────────────────────────────────────────────────────────

    void removeManyDeletesRowsAndFilesInOneSignal()
    {
        QTemporaryDir tmp;
        MediaService media;
        QList<qint64> ids;
        QStringList paths;
        for (const char* tag : { "one", "two", "three" }) {
            const QString src = tmp.filePath(QStringLiteral("%1.png").arg(QLatin1String(tag)));
            QFile f(src);
            QVERIFY(f.open(QIODevice::WriteOnly));
            f.write(QByteArray("\x89PNG\r\n\x1a\n", 8) + QByteArray(tag));
            f.close();
            const qint64 id = media.importPathSync(src);
            QVERIFY2(id > 0, qPrintable(media.lastImportError()));
            ids << id;
            paths << media.byId(id).path;
            QVERIFY(QFile::exists(paths.last()));
        }

        QSignalSpy spy(&media, &MediaService::allMediaChanged);
        QCOMPARE(media.removeMany(QVariantList{ ids[0], ids[2], qint64(987654) }), 2);
        QCOMPARE(spy.count(), 1);

        QCOMPARE(media.byId(ids[0]).id, qint64(0));
        QCOMPARE(media.byId(ids[1]).id, ids[1]);
        QCOMPARE(media.byId(ids[2]).id, qint64(0));
        QVERIFY(!QFile::exists(paths[0]));
        QVERIFY( QFile::exists(paths[1]));
        QVERIFY(!QFile::exists(paths[2]));
    }

    // ── Schedule ────────────────────────────────────────────────────────

    void removeManyDropsTheGivenRowsInOneSignal()
    {
        ScheduleService schedule;
        schedule.clearAll();
        for (const char* t : { "A", "B", "C", "D", "E" }) schedule.addItem(row(QLatin1String(t)));

        QSignalSpy spy(&schedule, &ScheduleService::currentItemsChanged);
        // Any order, with a duplicate and an out-of-range index.
        QCOMPARE(schedule.removeMany(QVariantList{ 3, 0, 3, 42 }), 2);
        QCOMPARE(spy.count(), 1);
        QCOMPARE(titles(schedule), (QStringList{ "B", "C", "E" }));
        QVERIFY(schedule.isDirty());
    }

    void reorderAppliesAPermutationAndRefusesAnythingElse()
    {
        ScheduleService schedule;
        schedule.clearAll();
        for (const char* t : { "A", "B", "C", "D" }) schedule.addItem(row(QLatin1String(t)));

        QSignalSpy spy(&schedule, &ScheduleService::currentItemsChanged);
        // order[k] = old index of the row that lands at k.
        QVERIFY(schedule.reorder(QVariantList{ 2, 0, 1, 3 }));
        QCOMPARE(spy.count(), 1);
        QCOMPARE(titles(schedule), (QStringList{ "C", "A", "B", "D" }));

        // Wrong length, a repeat, an out-of-range index: refused untouched.
        QVERIFY(!schedule.reorder(QVariantList{ 0, 1, 2 }));
        QVERIFY(!schedule.reorder(QVariantList{ 0, 0, 1, 2 }));
        QVERIFY(!schedule.reorder(QVariantList{ 0, 1, 2, 9 }));
        QCOMPARE(titles(schedule), (QStringList{ "C", "A", "B", "D" }));

        // The identity permutation is a no-op, not a change.
        QVERIFY(schedule.reorder(QVariantList{ 0, 1, 2, 3 }));
        QCOMPARE(spy.count(), 1);
    }
};

int main(int argc, char* argv[])
{
    QGuiApplication app(argc, argv);
    TestBulkActions tc;
    return QTest::qExec(&tc, argc, argv);
}

#include "test_bulk_actions.moc"
