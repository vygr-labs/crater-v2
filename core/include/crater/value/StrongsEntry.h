#pragma once

#include <QObject>
#include <QString>
#include <QtQmlIntegration>

namespace crater {

// One Strong's dictionary (lexicon) entry. `html` is the raw definition markup
// as shipped (used for the operator-console rich-text view); the parsed fields
// (lemma / transliteration / pronunciation / partOfSpeech / definition) are
// extracted from it at query time for compact list rows and slide titles.
struct StrongsEntry
{
    Q_GADGET
    QML_VALUE_TYPE(strongsEntry)
    Q_PROPERTY(QString word            MEMBER word)
    Q_PROPERTY(QString language        MEMBER language)         // "hebrew" | "greek"
    Q_PROPERTY(QString lemma           MEMBER lemma)            // original-language spelling
    Q_PROPERTY(QString transliteration MEMBER transliteration)
    Q_PROPERTY(QString pronunciation   MEMBER pronunciation)
    Q_PROPERTY(QString partOfSpeech    MEMBER partOfSpeech)
    Q_PROPERTY(QString definition      MEMBER definition)       // plain-text short definition
    Q_PROPERTY(QString html            MEMBER html)             // full definition markup
    Q_PROPERTY(int     relativeOrder   MEMBER relativeOrder)
    Q_PROPERTY(bool    isHebrew        READ isHebrew CONSTANT)
    Q_PROPERTY(QString title           READ title    CONSTANT)
    Q_PROPERTY(bool    valid           READ valid    CONSTANT)

public:
    QString word;
    QString language;
    QString lemma;
    QString transliteration;
    QString pronunciation;
    QString partOfSpeech;
    QString definition;
    QString html;
    int     relativeOrder = 0;

    bool isHebrew() const { return language == QStringLiteral("hebrew"); }

    // Empty word is the "no entry" sentinel (mirrors Verse.text.isEmpty()).
    bool valid() const { return !word.isEmpty(); }

    // "H430 · אלהים ('ĕlôhîym)" — display/slide-reference form. Degrades
    // gracefully to just the number when the parsed fields are absent.
    QString title() const
    {
        QString t = word;
        if (!lemma.isEmpty()) t += QStringLiteral(" · ") + lemma;
        if (!transliteration.isEmpty())
            t += QStringLiteral(" (") + transliteration + QStringLiteral(")");
        return t;
    }
};

}  // namespace crater
