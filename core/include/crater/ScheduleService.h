#pragma once

#include "crater/value/SavedSchedule.h"

#include <QList>
#include <QObject>
#include <QString>
#include <QTimer>
#include <QVariantList>
#include <QVariantMap>

#include <memory>

namespace crater {

// Schedule service — manages the in-flight "current" schedule plus a library
// of saved presets. Backed by app.sqlite (current_schedule + schedules tables).
//
// Schedule items are stored as JSON arrays (`items_json` column) because they
// are heterogeneous — song, scripture, image, and video items have different
// payloads. The plan's "Canonical ScheduleItem JSON shape" section defines
// the contract. We expose items to QML as QVariantList of QVariantMaps; QML
// reads `item.title`, `item.kind`, `item.pages[0].content`, etc.
//
// Auto-save: a QTimer fires every 5s; if the schedule is dirty, current_schedule
// is updated and a backup is written to AppData/schedules/.history/<ts>.json
// on the first auto-save of a session (last 10 retained).
class ScheduleService : public QObject
{
    Q_OBJECT

    Q_PROPERTY(QVariantList            currentItems    READ currentItems    NOTIFY currentItemsChanged)
    Q_PROPERTY(QList<crater::SavedSchedule> savedSchedules READ savedSchedules NOTIFY savedSchedulesChanged)

public:
    explicit ScheduleService(QObject* parent = nullptr);
    ~ScheduleService() override;

    QVariantList currentItems() const;
    QList<crater::SavedSchedule> savedSchedules();

    // Mutation methods. All emit currentItemsChanged + mark dirty.
    Q_INVOKABLE void addItem(QVariantMap item);
    Q_INVOKABLE void removeAt(int index);
    Q_INVOKABLE void moveItem(int from, int to);
    Q_INVOKABLE void clearAll();

    // Snapshot current items into a new `schedules` row. Returns new schedule id.
    Q_INVOKABLE qint64 saveAs(QString name);

    // Load a saved schedule's items into current_schedule.
    Q_INVOKABLE void load(qint64 scheduleId);

    Q_INVOKABLE void deleteSaved(qint64 scheduleId);

signals:
    void currentItemsChanged();
    void savedSchedulesChanged();

private slots:
    void onAutoSaveTick();

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;

    void markDirty();
    void saveCurrentNow();
    void backupHistoryOnce();
};

}  // namespace crater
