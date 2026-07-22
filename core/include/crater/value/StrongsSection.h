#pragma once

#include <QObject>
#include <QString>
#include <QtQmlIntegration>

namespace crater {

// One projectable slide derived from a Strong's definition. `content` is plain
// text (HTML stripped) sized to a single slide; `label` is the operator-side
// card header (e.g. "H430 · 1/3"). The tab maps these onto the canonical
// projection item's `pages: [{ label, content }]` shape.
struct StrongsSection
{
    Q_GADGET
    QML_VALUE_TYPE(strongsSection)
    Q_PROPERTY(QString label   MEMBER label)
    Q_PROPERTY(QString content MEMBER content)

public:
    QString label;
    QString content;
};

}  // namespace crater
