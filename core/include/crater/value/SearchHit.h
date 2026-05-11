#pragma once

#include <QObject>
#include <QString>
#include <QtQmlIntegration>

namespace crater {

// Single FTS5 search result. `score` is bm25() — lower is better in FTS5
// (the negation makes top results rank highest in `ORDER BY bm25(...) ASC`).
struct SearchHit
{
    Q_GADGET
    QML_VALUE_TYPE(bibleSearchHit)
    Q_PROPERTY(double  score           MEMBER score)
    Q_PROPERTY(QString translationCode MEMBER translationCode)
    Q_PROPERTY(QString book            MEMBER book)
    Q_PROPERTY(int     chapter         MEMBER chapter)
    Q_PROPERTY(int     verse           MEMBER verse)
    Q_PROPERTY(QString text            MEMBER text)
    Q_PROPERTY(QString reference       READ reference CONSTANT)

public:
    double  score = 0.0;
    QString translationCode;
    QString book;
    int     chapter = 0;
    int     verse   = 0;
    QString text;

    QString reference() const
    {
        return QStringLiteral("%1 %2:%3").arg(book).arg(chapter).arg(verse);
    }
};

}  // namespace crater
