#pragma once

#include <QAbstractListModel>
#include <QStringList>
#include <QVariantList>

namespace crater {

// The working schedule as a list model, for the schedule ListView.
//
// ScheduleService exposes the schedule as a QVariantList, and handing QML a
// fresh list after every edit makes the ListView throw away and rebuild all
// of its rows, which resets the scroll position and hover. sync() instead
// diffs the new list against the rows it holds by item id and reports the
// edit as row moves, inserts, removes and data changes, so the view keeps
// its rows and animates a reorder.
//
// The one role, `entry`, is the item's QVariantMap.
class ScheduleItemsModel : public QAbstractListModel
{
    Q_OBJECT

public:
    enum Roles { EntryRole = Qt::UserRole + 1 };

    using QAbstractListModel::QAbstractListModel;

    int rowCount(const QModelIndex& parent = {}) const override;
    QVariant data(const QModelIndex& index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    void sync(const QVariantList& items);

private:
    QVariantList m_items;
    QStringList  m_keys;
};

}  // namespace crater
