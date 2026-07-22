#pragma once

#include <QObject>
#include <QString>
#include <QtQmlIntegration>

namespace crater {

// A user-created song collection. `songCount` is derived (COUNT over the
// membership join) at query time — collections themselves store only id/name/
// timestamps. Membership lives in the collection_songs join table.
struct Collection
{
    Q_GADGET
    QML_VALUE_TYPE(songCollection)
    Q_PROPERTY(qint64  id        MEMBER id)
    Q_PROPERTY(QString name      MEMBER name)
    Q_PROPERTY(int     songCount MEMBER songCount)

public:
    qint64  id = 0;
    QString name;
    int     songCount = 0;
};

}  // namespace crater
