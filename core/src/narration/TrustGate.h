#pragma once

#include <QLatin1String>
#include <QString>

namespace crater::narration {

// What the system is allowed to do with a detection, given how good the
// evidence is and how much the operator has said they trust it.
//
// docs/narration.md §5, expressed as a pure function so it can be asserted
// cell by cell:
//
//   mode \ tier    certain   high      possible
//   suggest        queued    queued    queued
//   stage          staged    staged    queued
//   auto           live      staged    queued
//
// This lives in its own header rather than inside NarrationService.cpp
// because of what it costs to get wrong. Every other failure in this
// subsystem is a missed cue; this one puts the wrong scripture on the main
// screen mid-sermon, in front of the congregation, with the pastor having to
// work around it live. A rule that consequential should be provable on its
// own, not only reachable through a microphone and a 190 MB model.
//
// Returned as strings because that is what crosses into QML and into the
// session log unchanged — an enum would be converted at both boundaries and
// the log is meant to be readable by the person tuning the system.
namespace trust {

inline QString kQueued() { return QStringLiteral("queued"); }
inline QString kStaged() { return QStringLiteral("staged"); }
inline QString kLive()   { return QStringLiteral("live"); }

// `tier` is "certain" | "high" | "possible"; `mode` is "suggest" | "stage" |
// "auto". Unknown values fall to the most conservative outcome rather than
// the most convenient one — see the two guards below.
inline QString actionFor(const QString& tier, const QString& mode)
{
    // The safety property, and the reason the allusion path in §7.2 is
    // shippable at all: a semantic guess never reaches the projector, in any
    // mode, under any configuration. Deliberately first and deliberately
    // unconditional. Everything below this line is a preference; this is not.
    //
    // It is also the default for an unrecognised tier. A detection path added
    // later that forgets to set a tier gets treated as a guess, which is the
    // failure that costs nothing.
    if (tier != QLatin1String("certain") && tier != QLatin1String("high"))
        return kQueued();

    // An unrecognised mode lands here too, and "suggest" is the right place
    // for it to land: nothing moves without a human.
    if (mode != QLatin1String("stage") && mode != QLatin1String("auto"))
        return kQueued();

    // Auto projects only what the preacher actually said out loud. A
    // reference inferred from context is unambiguous but still inferred, and
    // inference is not enough to drive the audience screen unattended.
    if (mode == QLatin1String("auto") && tier == QLatin1String("certain"))
        return kLive();

    return kStaged();
}

}  // namespace trust
}  // namespace crater::narration
