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
//
// `enabled`, `screenIndex`, `screenName` and `contentMode` are the
// multi-display axis. Before them the registry could describe how an
// output should *look* but not where it should *go*, so every window in
// the app had to share the single global selectedScreenIndex — which is
// why only one projection window could ever exist. Each output now
// carries its own display assignment and its own on/off switch, and
// Main.qml Repeats a window per enabled entry.
//
//   enabled     — does a window exist for this output at all. NDI ignores
//                 it (its lifecycle is NdiService.sending); "primary" also
//                 ignores it, because the audience window's visibility is
//                 the operator's live/blank gesture (AppState.projectorVisible),
//                 not a settings toggle. Every other output honors it.
//   screenIndex — index into OutputService.screens. "primary" is special:
//                 it reads and writes through selectedScreenIndex so the
//                 pre-existing Projection settings picker keeps working
//                 against one source of truth. See screenIndexFor().
//   screenName  — the display's name at the time it was chosen. Same
//                 replug-survival trick the global selection already used:
//                 a projector that comes back on a different port lands at
//                 a different index, and the name is what identifies it
//                 across the unplug.
//   contentMode — what this output renders:
//                   "mirror" — the audience render (ProjectionScene). What
//                              every output did implicitly before.
//                   "stage"  — the presenter view (StageScene): the live
//                              text large, the preacher's speaker notes,
//                              what is coming next, and a clock. This is
//                              the confidence monitor, and it deliberately
//                              does NOT show what the congregation sees.
//                 Seeded from role (a "stage" output starts in stage mode)
//                 but independent of it afterwards: an overflow room is
//                 role "projection" in "mirror" mode, and a church that
//                 wants a second lyrics-only confidence screen can flip a
//                 projection output to "stage" without re-registering it.
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
    Q_PROPERTY(bool             enabled             MEMBER enabled)
    Q_PROPERTY(int              screenIndex         MEMBER screenIndex)
    Q_PROPERTY(QString          screenName          MEMBER screenName)
    Q_PROPERTY(QString          contentMode         MEMBER contentMode)

public:
    QString          id;
    QString          displayName;
    QString          role                 = QStringLiteral("projection");
    OutputThemeSlots themes;
    QString          transitionStyle      = QStringLiteral("crossfade");
    int              transitionDurationMs = 280;
    bool             enabled              = false;
    int              screenIndex          = -1;
    QString          screenName;
    QString          contentMode          = QStringLiteral("mirror");

    bool operator==(const OutputBinding&) const = default;
};

}  // namespace crater
