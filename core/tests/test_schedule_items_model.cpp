// ScheduleItemsModel turns a whole new schedule list into row moves, inserts
// and removes. These pin that the rows always end up matching the list, that
// a drag reports one move instead of a reset (which is what scrolled the
// schedule back to the top), and that duplicate or missing ids still work.
//
// Run via CTest: `ctest --test-dir <build-dir> -R schedule_items_model --output-on-failure`

#include <QAbstractItemModelTester>
#include <QRandomGenerator>
#include <QSignalSpy>
#include <QTest>
#include <QVariantList>
#include <QVariantMap>

#include "crater/ScheduleItemsModel.h"

using crater::ScheduleItemsModel;

namespace {

QVariantMap item(const QString& id, const QString& title = {})
{
    QVariantMap m{ { QStringLiteral("title"), title.isEmpty() ? id : title } };
    if (!id.isEmpty()) m.insert(QStringLiteral("id"), id);
    return m;
}

QVariantList items(const QStringList& ids)
{
    QVariantList out;
    for (const QString& id : ids) out.append(item(id));
    return out;
}

QVariantList rows(const ScheduleItemsModel& model)
{
    QVariantList out;
    for (int i = 0; i < model.rowCount(); ++i)
        out.append(model.data(model.index(i), ScheduleItemsModel::EntryRole));
    return out;
}

}  // namespace

class TestScheduleItemsModel : public QObject
{
    Q_OBJECT

private slots:
    void dragDownIsOneMove()
    {
        ScheduleItemsModel model;
        model.sync(items({ "a", "b", "c", "d", "e", "f" }));
        QSignalSpy moved(&model, &QAbstractItemModel::rowsMoved);
        QSignalSpy reset(&model, &QAbstractItemModel::modelReset);
        QSignalSpy inserted(&model, &QAbstractItemModel::rowsInserted);
        QSignalSpy removed(&model, &QAbstractItemModel::rowsRemoved);

        const QVariantList next = items({ "a", "c", "d", "e", "b", "f" });
        model.sync(next);

        QCOMPARE(rows(model), next);
        QCOMPARE(moved.count(), 1);
        QCOMPARE(reset.count() + inserted.count() + removed.count(), 0);
    }

    void dragUpIsOneMove()
    {
        ScheduleItemsModel model;
        model.sync(items({ "a", "b", "c", "d", "e", "f" }));
        QSignalSpy moved(&model, &QAbstractItemModel::rowsMoved);

        const QVariantList next = items({ "a", "e", "b", "c", "d", "f" });
        model.sync(next);

        QCOMPARE(rows(model), next);
        QCOMPARE(moved.count(), 1);
    }

    void editIsDataChangedOnly()
    {
        ScheduleItemsModel model;
        model.sync(items({ "a", "b", "c" }));
        QSignalSpy changed(&model, &QAbstractItemModel::dataChanged);
        QSignalSpy moved(&model, &QAbstractItemModel::rowsMoved);

        QVariantList next = items({ "a", "b", "c" });
        next[1] = item(QStringLiteral("b"), QStringLiteral("renamed"));
        model.sync(next);

        QCOMPARE(rows(model), next);
        QCOMPARE(changed.count(), 1);
        QCOMPARE(changed.first().at(0).toModelIndex().row(), 1);
        QCOMPARE(moved.count(), 0);
    }

    void appendAndRemove()
    {
        ScheduleItemsModel model;
        model.sync(items({ "a", "b", "c" }));
        QSignalSpy inserted(&model, &QAbstractItemModel::rowsInserted);
        QSignalSpy removed(&model, &QAbstractItemModel::rowsRemoved);

        model.sync(items({ "a", "c", "d" }));
        QCOMPARE(rows(model), items({ "a", "c", "d" }));
        QCOMPARE(inserted.count(), 1);
        QCOMPARE(removed.count(), 1);
    }

    // A list with nothing in common is a load, not an edit: one reset, so
    // the view opens at the top with every row at once.
    void unrelatedListResets()
    {
        ScheduleItemsModel model;
        model.sync(items({ "a", "b", "c" }));
        QSignalSpy reset(&model, &QAbstractItemModel::modelReset);
        QSignalSpy removed(&model, &QAbstractItemModel::rowsRemoved);
        QSignalSpy inserted(&model, &QAbstractItemModel::rowsInserted);

        model.sync(items({ "x", "y" }));
        QCOMPARE(rows(model), items({ "x", "y" }));
        QCOMPARE(reset.count(), 1);
        QCOMPARE(removed.count() + inserted.count(), 0);
    }

    void duplicateAndMissingIds()
    {
        ScheduleItemsModel model;
        QAbstractItemModelTester tester(&model);
        QVariantList start{ item("s"), item(""), item("s"), item("") };
        start[1] = item(QString(), QStringLiteral("no id one"));
        start[3] = item(QString(), QStringLiteral("no id two"));
        model.sync(start);
        QCOMPARE(rows(model), start);

        const QVariantList next{ start[2], start[3], start[0], start[1] };
        model.sync(next);
        QCOMPARE(rows(model), next);
    }

    // Any sequence of edits has to leave the rows equal to the list, with
    // QAbstractItemModelTester checking every signal along the way.
    void randomEditsAlwaysMatch()
    {
        ScheduleItemsModel model;
        QAbstractItemModelTester tester(&model);
        QRandomGenerator rng(12345);
        QStringList ids;
        int next = 0;
        for (int round = 0; round < 400; ++round) {
            switch (rng.bounded(5)) {
            case 0: ids.insert(rng.bounded(int(ids.size()) + 1), QString::number(next++)); break;
            case 1: if (!ids.isEmpty()) ids.removeAt(rng.bounded(int(ids.size()))); break;
            case 2:
            case 3:
                if (ids.size() > 1) ids.move(rng.bounded(int(ids.size())), rng.bounded(int(ids.size())));
                break;
            case 4:
                for (int k = int(ids.size()) - 1; k > 0; --k) ids.swapItemsAt(k, rng.bounded(k + 1));
                break;
            }
            model.sync(items(ids));
            QCOMPARE(rows(model), items(ids));
        }
    }
};

QTEST_GUILESS_MAIN(TestScheduleItemsModel)
#include "test_schedule_items_model.moc"
