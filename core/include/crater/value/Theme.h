#pragma once

#include <QObject>
#include <QString>
#include <QVariantMap>
#include <QtQmlIntegration>

namespace crater {

// A theme — declarative token data applied to projection rendering.
// `tokens` is parsed from the DB's tokens_json column into a QVariantMap so
// QML can read `theme.tokens.background.color` directly.
struct Theme
{
    Q_GADGET
    QML_VALUE_TYPE(theme)
    Q_PROPERTY(qint64       id         MEMBER id)
    Q_PROPERTY(QString      kind       MEMBER kind)        // "song" | "scripture" | "presentation"
    Q_PROPERTY(QString      name       MEMBER name)
    Q_PROPERTY(QVariantMap  tokens     MEMBER tokens)
    Q_PROPERTY(bool         isBuiltin  MEMBER isBuiltin)

public:
    qint64      id        = 0;
    QString     kind;
    QString     name;
    QVariantMap tokens;
    bool        isBuiltin = false;
};

}  // namespace crater
