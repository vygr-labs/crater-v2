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
// One optional field on every item — `themeId` (qint64) — names a per-item
// theme override. ProjectionService doesn't know about it; the projection
// window reads it reactively via AppState.resolveItemTheme(item), which
// falls back to ThemeService.defaultFor(kind) when the override is absent
// or stale. The resolution is live — changing the kind's default updates
// the projection without requiring a re-Go-Live.
//
// Auto-save: a QTimer fires every 5s; if the schedule is dirty, current_schedule
// is updated and a backup is written to AppData/schedules/.history/<ts>.json
// on the first auto-save of a session (last 10 retained).
//
// Loaded-schedule tracking: when the operator loads a saved schedule (or
// creates one via saveAs), the service remembers its id + name and persists
// that pointer in the `kv` table so a relaunch returns to the same identity.
// Edits flip `isDirty` so the UI can show an unsaved indicator. Calling
// `saveCurrent()` writes the working items back into the loaded row;
// `saveAs(name)` always creates a fresh row.
class ScheduleService : public QObject
{
    Q_OBJECT

    Q_PROPERTY(QVariantList currentItems READ currentItems NOTIFY currentItemsChanged)
    Q_PROPERTY(QList<crater::SavedSchedule> savedSchedules READ savedSchedules NOTIFY savedSchedulesChanged)

    // Identity of the saved schedule whose contents `currentItems` reflects.
    // Zero when the working schedule is untitled (fresh slate or after
    // closeLoaded). Persists across launches via the `kv` table.
    Q_PROPERTY(qint64  loadedScheduleId   READ loadedScheduleId   NOTIFY loadedScheduleChanged)
    Q_PROPERTY(QString loadedScheduleName READ loadedScheduleName NOTIFY loadedScheduleChanged)

    // True when there have been edits since the last load / saveCurrent /
    // saveAs. Cleared on those operations; set on add/remove/move/setItemTheme.
    Q_PROPERTY(bool    isDirty            READ isDirty            NOTIFY isDirtyChanged)

public:
    explicit ScheduleService(QObject* parent = nullptr);
    ~ScheduleService() override;

    QVariantList currentItems() const;
    QList<crater::SavedSchedule> savedSchedules();
    qint64  loadedScheduleId()   const;
    QString loadedScheduleName() const;
    bool    isDirty()            const;

    // Current-schedule mutators. All emit currentItemsChanged + mark dirty.
    Q_INVOKABLE void addItem(QVariantMap item);
    Q_INVOKABLE void removeAt(int index);
    Q_INVOKABLE void moveItem(int from, int to);
    Q_INVOKABLE void clearAll();

    // Sets (or clears, when themeId == 0) the per-item theme override. The
    // operator's choice is stored as a `themeId` field on the item itself.
    // AppState.resolveItemTheme reads it whenever the projection window
    // re-evaluates its theme binding.
    Q_INVOKABLE void setItemTheme(int index, qint64 themeId);

    // Saved-schedule operations.

    // Snapshot current items into a new `schedules` row and adopt its id as
    // the loaded schedule. Returns the new id (0 on failure).
    Q_INVOKABLE qint64 saveAs(QString name);

    // Update the currently loaded saved schedule with the working items.
    // No-op if nothing is loaded; returns true on success.
    Q_INVOKABLE bool   saveCurrent();

    // Load a saved schedule into the working schedule. Becomes the loaded id.
    Q_INVOKABLE void   load(qint64 scheduleId);

    // Rename a saved schedule. If it's the loaded one, the loaded name updates
    // and loadedScheduleChanged fires so the UI reflects the new label.
    Q_INVOKABLE void   rename(qint64 scheduleId, QString newName);

    Q_INVOKABLE void   deleteSaved(qint64 scheduleId);

    // Drop the "I'm editing X" pointer without touching the working items.
    // Useful when the operator wants to use the current items as the starting
    // point for a brand-new schedule.
    Q_INVOKABLE void   closeLoaded();

signals:
    void currentItemsChanged();
    void savedSchedulesChanged();
    void loadedScheduleChanged();
    void isDirtyChanged();

private slots:
    void onAutoSaveTick();

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;

    void setDirty(bool v);
    void setLoaded(qint64 id, const QString& name);
    void persistLoadedKv();
    void markDirty();
    void saveCurrentNow();
    void backupHistoryOnce();
};

}  // namespace crater
