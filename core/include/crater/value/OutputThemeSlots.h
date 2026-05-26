#pragma once

#include <QObject>
#include <QtQmlIntegration>

namespace crater {

// Per-kind theme assignment for a single output. Each output (Primary HDMI,
// NDI broadcast, stage monitor, plus any v1.1 dynamically-registered output)
// can pin a distinct theme for each content kind. 0 in any slot means
// "no override — fall through to ThemeService::defaultFor(kind)".
//
// Lives alongside OutputBinding because it's the inner value of every
// output's theme assignment. Kept as a separate Q_GADGET so QML can
// navigate `OutputService.output("ndi").themes.song` and the resolver in
// AppState.resolveItemTheme can index by kind string without unpacking.
struct OutputThemeSlots
{
    Q_GADGET
    QML_VALUE_TYPE(outputThemeSlots)
    Q_PROPERTY(int song         MEMBER song)
    Q_PROPERTY(int scripture    MEMBER scripture)
    Q_PROPERTY(int presentation MEMBER presentation)

public:
    int song         = 0;
    int scripture    = 0;
    int presentation = 0;

    bool operator==(const OutputThemeSlots&) const = default;
};

}  // namespace crater
