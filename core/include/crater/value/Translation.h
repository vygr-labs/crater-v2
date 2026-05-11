#pragma once

#include <QObject>
#include <QString>
#include <QtQmlIntegration>

namespace crater {

// Bible translation metadata. Value type — passed by value into QML.
struct Translation
{
    Q_GADGET
    QML_VALUE_TYPE(bibleTranslation)
    Q_PROPERTY(QString code         MEMBER code)
    Q_PROPERTY(QString name         MEMBER name)
    Q_PROPERTY(int     year         MEMBER year)
    Q_PROPERTY(QString description  MEMBER description)

public:
    QString code;
    QString name;
    int     year = 0;
    QString description;
};

}  // namespace crater
