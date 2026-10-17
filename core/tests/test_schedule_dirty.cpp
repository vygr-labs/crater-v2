// The unsaved dot on the schedule (issue #70).
//
// QML shows the dot from ScheduleService.isDirty and only re-reads it when
// isDirtyChanged fires. The auto-save tick used to clear the flag without the
// signal, so QML kept showing the dot, and every later "clean" assignment
// was then a no-op that never reached it. These tests mirror the property
// the way QML does, from the signal alone, and walk the issue's steps.
//
// Run via CTest: `ctest --test-dir <build-dir> -R schedule_dirty --output-on-failure`

#include <QDir>
#include <QGuiApplication>
#include <QMetaObject>
#include <QObject>
#include <QStandardPaths>
#include <QString>
#include <QTest>
#include <QVariantMap>

#include "crater/Bootstrap.h"
#include "crater/ScheduleService.h"

using crater::ScheduleService;

namespace {

QVariantMap songRow(const QString& title)
{
    return QVariantMap{ { QStringLiteral("kind"),  QStringLiteral("song") },
                        { QStringLiteral("title"), title } };
}

// What QML sees: the value as of the last isDirtyChanged.
struct DotMirror
{
    bool shown = false;
    explicit DotMirror(ScheduleService& s)
        : shown(s.isDirty())
    {
        QObject::connect(&s, &ScheduleService::isDirtyChanged, &s,
                         [this, &s] { shown = s.isDirty(); });
    }
};

void autoSaveTick(ScheduleService& s)
{
    QVERIFY(QMetaObject::invokeMethod(&s, "onAutoSaveTick", Qt::DirectConnection));
}

}  // namespace

class TestScheduleDirty : public QObject
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

    void dotFollowsTheIssueSteps()
    {
        ScheduleService schedule;
        DotMirror dot(schedule);

        // 1. Save a schedule, add one more item, wait for an auto-save.
        schedule.addItem(songRow(QStringLiteral("Amazing Grace")));
        const qint64 id = schedule.saveAs(QStringLiteral("Sunday"));
        QVERIFY(id > 0);
        QCOMPARE(dot.shown, false);
        schedule.addItem(songRow(QStringLiteral("It Is Well")));
        QCOMPARE(dot.shown, true);
        autoSaveTick(schedule);
        // Auto-save writes the working copy, not "Sunday", so the edit is
        // still unsaved and the dot stays.
        QCOMPARE(schedule.isDirty(), true);
        QCOMPARE(dot.shown, schedule.isDirty());

        // 2. New empty schedule: nothing to save, no dot.
        schedule.clearAll();
        QCOMPARE(schedule.isDirty(), false);
        QCOMPARE(dot.shown, false);

        // 3. Open the saved schedule: just opened, no dot.
        schedule.addItem(songRow(QStringLiteral("Holy, Holy, Holy")));
        autoSaveTick(schedule);
        schedule.load(id);
        QCOMPARE(schedule.isDirty(), false);
        QCOMPARE(dot.shown, false);
    }

    void saveClearsTheDotAfterAnAutoSave()
    {
        ScheduleService schedule;
        DotMirror dot(schedule);
        schedule.clearAll();
        schedule.addItem(songRow(QStringLiteral("A")));
        const qint64 id = schedule.saveAs(QStringLiteral("Evening"));
        QVERIFY(id > 0);

        schedule.addItem(songRow(QStringLiteral("B")));
        autoSaveTick(schedule);
        QCOMPARE(dot.shown, true);
        QVERIFY(schedule.saveCurrent());
        QCOMPARE(schedule.isDirty(), false);
        QCOMPARE(dot.shown, false);
    }

    void autoSaveStillWritesTheWorkingCopy()
    {
        qint64 id = 0;
        {
            ScheduleService schedule;
            schedule.clearAll();
            schedule.addItem(songRow(QStringLiteral("Kept")));
            id = schedule.saveAs(QStringLiteral("Morning"));
            schedule.addItem(songRow(QStringLiteral("Added after save")));
            autoSaveTick(schedule);
        }
        // A fresh service reads the working copy the tick wrote.
        ScheduleService reopened;
        QCOMPARE(reopened.loadedScheduleId(), id);
        QCOMPARE(reopened.currentItems().size(), 2);
    }
};

int main(int argc, char** argv)
{
    QGuiApplication app(argc, argv);
    TestScheduleDirty tc;
    return QTest::qExec(&tc, argc, argv);
}

#include "test_schedule_dirty.moc"
