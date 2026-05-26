#pragma once

#include <QObject>
#include <QString>
#include <QStringList>
#include <QtQmlIntegration>

namespace crater {

// Result of a .craterheme v2 bundle import (ARCHITECTURE.md §10.4).
//
// Best-effort import: catastrophic failures leave themeId == 0 and
// populate errorMessage; per-asset failures leave themeId > 0 and
// accumulate human-readable lines in mediaWarnings / fontWarnings so
// the UI can surface them in a non-blocking banner. A successful
// import with no warnings has themeId > 0 and both warning lists empty.
struct ThemeImportReport
{
    Q_GADGET
    QML_VALUE_TYPE(themeImportReport)

    Q_PROPERTY(qint64      themeId        MEMBER themeId)
    Q_PROPERTY(QString     errorMessage   MEMBER errorMessage)
    Q_PROPERTY(QStringList mediaWarnings  MEMBER mediaWarnings)
    Q_PROPERTY(QStringList fontWarnings   MEMBER fontWarnings)

public:
    qint64      themeId = 0;
    QString     errorMessage;
    QStringList mediaWarnings;
    QStringList fontWarnings;

    bool hasWarnings() const noexcept
    {
        return !mediaWarnings.isEmpty() || !fontWarnings.isEmpty();
    }
};

}  // namespace crater
