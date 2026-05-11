#pragma once

#include <QObject>
#include <QString>
#include <QtQmlIntegration>

namespace crater {

// Bible book metadata for a specific translation.
struct Book
{
    Q_GADGET
    QML_VALUE_TYPE(bibleBook)
    Q_PROPERTY(QString name         MEMBER name)
    Q_PROPERTY(QString abbrev       MEMBER abbrev)
    Q_PROPERTY(QString testament    MEMBER testament)   // "OT" | "NT"
    Q_PROPERTY(int     bookNumber   MEMBER bookNumber)  // 1..66
    Q_PROPERTY(int     chapterCount MEMBER chapterCount)

public:
    QString name;
    QString abbrev;
    QString testament;
    int     bookNumber   = 0;
    int     chapterCount = 0;
};

}  // namespace crater
