#pragma once

#include <QObject>
#include <QString>
#include <QtQmlIntegration>

namespace crater {

// A font the operator has imported (typically as part of a theme bundle —
// see ARCHITECTURE.md §10). System-installed fonts are not represented
// here; QML reads them by family name through Qt's normal font subsystem.
struct UserFont
{
    Q_GADGET
    QML_VALUE_TYPE(userFont)
    Q_PROPERTY(qint64  id      MEMBER id)
    Q_PROPERTY(QString hash    MEMBER hash)
    Q_PROPERTY(QString family  MEMBER family)
    Q_PROPERTY(QString path    MEMBER path)
    Q_PROPERTY(qint64  addedAt MEMBER addedAt)

public:
    qint64  id      = 0;
    QString hash;
    QString family;
    QString path;
    qint64  addedAt = 0;
};

}  // namespace crater
