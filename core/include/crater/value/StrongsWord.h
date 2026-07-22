#pragma once

#include <QObject>
#include <QString>
#include <QtQmlIntegration>

namespace crater {

// A single token within a Strong's-tagged verse. `ref` carries the Strong's
// number the word glosses ("H430" / "G2424"), empty when the word has no tag.
// The interlinear reader renders `text` inline and, when `hasStrongs`, a
// tappable superscript badge coloured by `language`.
struct StrongsWord
{
    Q_GADGET
    QML_VALUE_TYPE(strongsWord)
    Q_PROPERTY(QString text       MEMBER text)
    Q_PROPERTY(QString ref        MEMBER ref)        // "H430" | "G2424" | ""
    Q_PROPERTY(QString language   MEMBER language)   // "hebrew" | "greek" | ""
    Q_PROPERTY(bool    hasStrongs MEMBER hasStrongs)

public:
    QString text;
    QString ref;
    QString language;
    bool    hasStrongs = false;
};

}  // namespace crater
