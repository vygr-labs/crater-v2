#pragma once

#include "crater/value/OutputThemeSlots.h"

#include <QObject>
#include <QString>
#include <QtQmlIntegration>

namespace crater {

// One row in the OutputService output registry. Identified by stable string
// id; everything else is operator-mutable.
//
// `id` is the slug used everywhere a consumer needs to refer to "which
// output" — QML scenes pass it as a property, the resolver indexes by it,
// QSettings groups under it. Built-ins are "primary", "ndi", "stage";
// future dynamically-registered outputs get auto-generated slugs like
// "projection-2". Never localized — display strings live in displayName.
//
// `role` is a soft classification ("projection" | "ndi" | "stage") that
// some consumers use to decide gating (e.g. NDI scene only renders when
// outputMode==="dual"). Free-form so v1.1 multi-output can add new roles
// without growing this enum-equivalent.
//
// `themes`, `transitionStyle`, `transitionDurationMs` are the per-output
// settings that used to live as parallel triples in SettingsService
// (themeIdForPrimary / themeIdForNdi / themeIdForStage etc). Pulled into
// this struct so adding a fourth output costs one registry entry, not
// three new Q_PROPERTYs in the service header.
struct OutputBinding
{
    Q_GADGET
    QML_VALUE_TYPE(outputBinding)
    Q_PROPERTY(QString          id                  MEMBER id)
    Q_PROPERTY(QString          displayName         MEMBER displayName)
    Q_PROPERTY(QString          role                MEMBER role)
    Q_PROPERTY(OutputThemeSlots themes              MEMBER themes)
    Q_PROPERTY(QString          transitionStyle     MEMBER transitionStyle)
    Q_PROPERTY(int              transitionDurationMs MEMBER transitionDurationMs)

public:
    QString          id;
    QString          displayName;
    QString          role                 = QStringLiteral("projection");
    OutputThemeSlots themes;
    QString          transitionStyle      = QStringLiteral("crossfade");
    int              transitionDurationMs = 280;

    bool operator==(const OutputBinding&) const = default;
};

}  // namespace crater
