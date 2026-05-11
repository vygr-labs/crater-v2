#pragma once

#include <QObject>
#include <QRect>
#include <QString>
#include <QtQmlIntegration>

namespace crater {

// Value-type snapshot of a QScreen. We intentionally don't hold a QScreen* —
// QScreens are Qt-managed singletons whose lifetime would muddy our value-
// semantics for QML.
struct Screen
{
    Q_GADGET
    QML_VALUE_TYPE(screen)
    Q_PROPERTY(QString name             MEMBER name)
    Q_PROPERTY(QRect   geometry         MEMBER geometry)
    Q_PROPERTY(bool    isPrimary        MEMBER isPrimary)
    Q_PROPERTY(double  devicePixelRatio MEMBER devicePixelRatio)

public:
    QString name;
    QRect   geometry;
    bool    isPrimary        = false;
    double  devicePixelRatio = 1.0;
};

}  // namespace crater
