#pragma once

#include <QObject>
#include <QString>
#include <QtQmlIntegration>

namespace crater {

// A single Bible verse.
struct Verse
{
    Q_GADGET
    QML_VALUE_TYPE(bibleVerse)
    Q_PROPERTY(QString translationCode MEMBER translationCode)
    Q_PROPERTY(QString book            MEMBER book)
    Q_PROPERTY(int     chapter         MEMBER chapter)
    Q_PROPERTY(int     verse           MEMBER verse)
    Q_PROPERTY(QString text            MEMBER text)
    Q_PROPERTY(QString reference       READ reference CONSTANT)

public:
    QString translationCode;
    QString book;
    int     chapter = 0;
    int     verse   = 0;
    QString text;

    // "John 3:16 (KJV)" — display form.
    QString reference() const
    {
        return QStringLiteral("%1 %2:%3").arg(book).arg(chapter).arg(verse);
    }
};

}  // namespace crater
