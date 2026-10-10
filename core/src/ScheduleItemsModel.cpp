#include "crater/ScheduleItemsModel.h"

#include <QHash>
#include <QSet>
#include <QVariantMap>

namespace crater {

namespace {

// One key per row. Items normally carry a unique `id`, but older schedules
// may have none and the same library item can appear twice, so the key adds
// which occurrence of that id this is. Two copies of a song then keep their
// order instead of trading places.
QStringList keysFor(const QVariantList& items)
{
    QStringList keys;
    keys.reserve(items.size());
    QHash<QString, int> seen;
    for (const QVariant& v : items) {
        const QString id = v.toMap().value(QStringLiteral("id")).toString();
        const int n = seen.value(id, 0);
        seen.insert(id, n + 1);
        keys.append(id + QLatin1Char('#') + QString::number(n));
    }
    return keys;
}

}  // namespace

int ScheduleItemsModel::rowCount(const QModelIndex& parent) const
{
    return parent.isValid() ? 0 : int(m_items.size());
}

QVariant ScheduleItemsModel::data(const QModelIndex& index, int role) const
{
    if (!index.isValid() || index.row() >= m_items.size() || role != EntryRole)
        return {};
    return m_items.at(index.row());
}

QHash<int, QByteArray> ScheduleItemsModel::roleNames() const
{
    return { { EntryRole, QByteArrayLiteral("entry") } };
}

void ScheduleItemsModel::sync(const QVariantList& items)
{
    const QStringList keys = keysFor(items);

    // Rows that are gone, bottom up so the indices above stay valid.
    const QSet<QString> wanted(keys.cbegin(), keys.cend());
    for (int i = int(m_keys.size()) - 1; i >= 0; --i) {
        if (wanted.contains(m_keys.at(i))) continue;
        beginRemoveRows({}, i, i);
        m_keys.removeAt(i);
        m_items.removeAt(i);
        endRemoveRows();
    }

    // Walk the new order. Each row is already in place, further down (move
    // it up), or new (insert it).
    for (int i = 0; i < keys.size(); ++i) {
        if (i < m_keys.size() && m_keys.at(i) == keys.at(i)) {
            if (m_items.at(i) != items.at(i)) {
                m_items[i] = items.at(i);
                const QModelIndex at = index(i);
                emit dataChanged(at, at, { EntryRole });
            }
            continue;
        }
        // A row dragged down shows up here as the next row being wanted
        // first. Move that one row down to where it belongs, rather than
        // moving every row it passed up by one, so the view sees a single
        // move.
        if (i + 1 < m_keys.size() && m_keys.at(i + 1) == keys.at(i)) {
            const int to = qMin(int(keys.indexOf(m_keys.at(i))), int(m_keys.size()) - 1);
            if (to > i) {
                beginMoveRows({}, i, i, {}, to + 1);
                m_keys.move(i, to);
                m_items.move(i, to);
                endMoveRows();
                --i;   // look at row i again, its key has changed
                continue;
            }
        }
        const int from = int(m_keys.indexOf(keys.at(i), i + 1));
        if (from > i) {
            beginMoveRows({}, from, from, {}, i);
            m_keys.move(from, i);
            m_items.move(from, i);
            endMoveRows();
            if (m_items.at(i) != items.at(i)) {
                m_items[i] = items.at(i);
                const QModelIndex at = index(i);
                emit dataChanged(at, at, { EntryRole });
            }
        } else {
            beginInsertRows({}, i, i);
            m_keys.insert(i, keys.at(i));
            m_items.insert(i, items.at(i));
            endInsertRows();
        }
    }
}

}  // namespace crater
