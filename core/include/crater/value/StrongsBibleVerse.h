#pragma once

#include <QObject>
#include <QString>
#include <QtQmlIntegration>

namespace crater {

// A KJV+Strong's Bible verse row. `text` is the raw markup as shipped —
// it carries inline <WH####>/<WG####> Strong's tags plus KJV formatting
// markers (<FI>..<Fi> translator-added, <RF>..<Rf> footnotes, <CM>). Feed
// it through StrongsService::tokenize() to render the interlinear view.
// `book` is the 1..66 canonical number; `bookName` is resolved for display.
struct StrongsBibleVerse
{
    Q_GADGET
    QML_VALUE_TYPE(strongsBibleVerse)
    Q_PROPERTY(int     book      MEMBER book)
    Q_PROPERTY(QString bookName  MEMBER bookName)
    Q_PROPERTY(int     chapter   MEMBER chapter)
    Q_PROPERTY(int     verse     MEMBER verse)
    Q_PROPERTY(QString text      MEMBER text)
    Q_PROPERTY(QString reference READ reference CONSTANT)
    Q_PROPERTY(bool    valid     READ valid     CONSTANT)

public:
    int     book = 0;
    QString bookName;
    int     chapter = 0;
    int     verse = 0;
    QString text;

    bool valid() const { return verse != 0; }

    QString reference() const
    {
        return QStringLiteral("%1 %2:%3").arg(bookName).arg(chapter).arg(verse);
    }
};

}  // namespace crater
