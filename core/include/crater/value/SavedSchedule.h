#pragma once

#include <QObject>
#include <QString>
#include <QtQmlIntegration>

namespace crater {

// Lightweight metadata about a saved schedule — used by the schedule dropdown
// popover. The full items_json is fetched only on load(id).
struct SavedSchedule
{
    Q_GADGET
    QML_VALUE_TYPE(savedSchedule)
    Q_PROPERTY(qint64  id          MEMBER id)
    Q_PROPERTY(QString name        MEMBER name)
    Q_PROPERTY(int     itemCount   MEMBER itemCount)
    Q_PROPERTY(qint64  modifiedAt  MEMBER modifiedAt)  // unix epoch ms

public:
    qint64  id         = 0;
    QString name;
    int     itemCount  = 0;
    qint64  modifiedAt = 0;
};

}  // namespace crater
