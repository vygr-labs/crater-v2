#pragma once

#include "crater/value/Screen.h"
#include "crater/value/OutputBinding.h"
#include "crater/value/OutputThemeSlots.h"

#include <QList>
#include <QObject>
#include <QString>

namespace crater {

class ThemeService;

// Display routing AND the per-output binding registry.
//
// Originally OutputService just enumerated monitors and dispatched the
// "open projection window" request. As of the registry refactor, it also
// owns the per-output state that used to live as parallel triples in
// SettingsService — per-output theme assignments (per kind) and per-output
// transition style/duration. Reason for the move: every one of those
// settings *varies with output*, and §4 of the architecture doc says
// "one service = one concern" — the concern here is outputs, so the
// settings that depend on an output id belong here.
//
// The registry has built-in seeds for "primary", "ndi", "stage" so legacy
// consumers find what they expect. New outputs (v1.1 multi-output) call
// registerOutput() with a role + display name and get back a stable id
// they then pass to ProjectionScene as outputKind.
//
// Why we don't own the QQuickWindow here: ARCHITECTURE.md §1 forbids
// crater-core from linking Qt6::Quick. Instead, OutputService emits
// projectionWindowRequested and the executable's QML layer creates the
// window. Clean separation.
class OutputService : public QObject
{
    Q_OBJECT

public:
    // How the projection window occupies its target screen.
    //   Fullscreen — frameless, on-top, fills the selected screen (production).
    //   Windowed   — OS-framed, movable preview window (single-monitor / dev).
    // Default is computed from available screens (Windowed if no external
    // display is attached, Fullscreen otherwise) and persisted on first user
    // override. See ProjectionWindow.qml + Main.qml for visibility wiring.
    enum ProjectionMode {
        Fullscreen = 0,
        Windowed   = 1,
    };
    Q_ENUM(ProjectionMode)

private:
    Q_PROPERTY(QList<crater::Screen>        screens              READ screens              NOTIFY screensChanged)
    Q_PROPERTY(int                          selectedScreenIndex  READ selectedScreenIndex  WRITE setSelectedScreenIndex NOTIFY selectedScreenIndexChanged)
    Q_PROPERTY(bool                         projectionOpen       READ projectionOpen       NOTIFY projectionOpenChanged)
    Q_PROPERTY(ProjectionMode               projectionMode       READ projectionMode       WRITE setProjectionMode      NOTIFY projectionModeChanged)
    // The output registry. Bound from QML for tab/badge UI; mutated through
    // the typed setters below so persistence + change emission go through
    // one path. outputsChanged() is intentionally coarse — every mutation
    // (theme slot, transition style/duration, registration, removal) emits
    // it. Per-output revision counters would be finer-grained but the
    // consumers (Themes tab, ProjectionScene) re-evaluate cheaply on a
    // single signal.
    Q_PROPERTY(QList<crater::OutputBinding> outputs              READ outputs              NOTIFY outputsChanged)

public:
    explicit OutputService(QObject* parent = nullptr);
    ~OutputService() override;

    // Wire ThemeService for the one-shot legacy-key migration. Called from
    // main.cpp after both services exist; the migration runs on the next
    // event-loop tick (so the call site doesn't constrain construction
    // order). Safe to call before or after; if ThemeService is null the
    // migration falls back to assuming "song" kind for legacy theme ids,
    // which is the most-common kind and the worst-case is the operator
    // reassigns once.
    void attachThemeService(ThemeService* svc);

    QList<crater::Screen>         screens() const;
    int                           selectedScreenIndex() const;
    bool                          projectionOpen() const;
    ProjectionMode                projectionMode() const;
    QList<crater::OutputBinding>  outputs() const;

    void setSelectedScreenIndex(int index);
    void setProjectionMode(ProjectionMode mode);

    // Asks the QML layer to open / close the projection window on the
    // currently selected screen.
    Q_INVOKABLE void openProjection();
    Q_INVOKABLE void closeProjection();

    // Called from the QML side after the window has actually been
    // instantiated / destroyed, so we keep projectionOpen in sync.
    Q_INVOKABLE void notifyProjectionOpened();
    Q_INVOKABLE void notifyProjectionClosed();

    // ── Output registry surface ─────────────────────────────────────────
    // Lookup is by stable id ("primary" | "ndi" | "stage" | dynamically-
    // registered slugs). An unknown id yields a default-constructed binding
    // with an empty id — callers can spot the miss by checking id.isEmpty().
    Q_INVOKABLE crater::OutputBinding output(const QString& id) const;

    // Per-kind theme pin. kind ∈ {"song","scripture","presentation"};
    // unknown kinds read/write as 0 (no override). themeId = 0 clears the
    // pin so the resolver falls through to ThemeService::defaultFor(kind).
    Q_INVOKABLE int  themeIdFor(const QString& outputId, const QString& kind) const;
    Q_INVOKABLE void setThemeIdFor(const QString& outputId, const QString& kind, int themeId);

    // Per-output transition tuning. Setters apply the same normalization
    // (style whitelist, duration clamp 0..1500) that previously lived in
    // SettingsService.
    Q_INVOKABLE QString transitionStyle(const QString& outputId) const;
    Q_INVOKABLE void    setTransitionStyle(const QString& outputId, const QString& style);
    Q_INVOKABLE int     transitionDurationMs(const QString& outputId) const;
    Q_INVOKABLE void    setTransitionDurationMs(const QString& outputId, int ms);

    // ── Multi-display: per-output placement and mode ────────────────────
    // Every output that renders a window carries its own display
    // assignment, its own on/off switch and its own content mode. Before
    // these, the registry could say how an output should look but not
    // where it should go, so a second projection window had nowhere to be.
    //
    // "primary" is deliberately aliased onto the pre-existing global
    // selection rather than given a parallel copy: screenIndexFor("primary")
    // reads selectedScreenIndex and setScreenIndexFor("primary", i) routes
    // to setSelectedScreenIndex(i). The Projection settings screen picker,
    // the hot-plug re-resolve and the replug-by-name recovery all keep
    // working untouched, and there is still exactly one answer to "which
    // display is the audience on".
    Q_INVOKABLE bool    outputEnabled(const QString& outputId) const;
    Q_INVOKABLE void    setOutputEnabled(const QString& outputId, bool enabled);

    // Index into screens(). Returns -1 when the output has no display
    // assigned yet (fresh registration) so QML can show "Not assigned"
    // rather than silently pointing a new output at screen 0, which on a
    // single-monitor desk is the operator's own console.
    Q_INVOKABLE int     screenIndexFor(const QString& outputId) const;
    Q_INVOKABLE void    setScreenIndexFor(const QString& outputId, int index);

    // "mirror" (audience render) | "stage" (presenter view). Anything else
    // normalizes to "mirror" — an unknown mode must not leave a physical
    // display rendering nothing.
    Q_INVOKABLE QString contentMode(const QString& outputId) const;
    Q_INVOKABLE void    setContentMode(const QString& outputId, const QString& mode);

    // Operator-facing rename. Empty names are ignored rather than stored,
    // so an accidental clear can't produce an unlabelled row.
    Q_INVOKABLE void    setDisplayName(const QString& outputId, const QString& name);

    // True when some OTHER enabled window-bearing output already occupies
    // this screen. The settings UI warns on it instead of refusing: two
    // outputs on one display is legitimate while an operator is re-patching
    // mid-service, it just isn't what they usually mean.
    Q_INVOKABLE bool    screenIsContested(const QString& outputId, int index) const;

    // Dynamic registration / removal. role ∈ {"projection","ndi","stage",
    // ...}; built-ins (primary/ndi/stage) cannot be unregistered. Returns
    // the assigned id ("<role>-<n>" auto-numbered); the id is also added
    // to outputs() and persisted.
    Q_INVOKABLE QString registerOutput(const QString& role, const QString& displayName);
    Q_INVOKABLE void    unregisterOutput(const QString& id);

signals:
    void screensChanged();
    void selectedScreenIndexChanged();
    void projectionOpenChanged();
    void projectionModeChanged();
    void outputsChanged();

    // QML connects to this and instantiates ProjectionWindow.qml on the
    // indicated screen index (matches `screens` list).
    void projectionWindowRequested(int screenIndex);
    void projectionWindowDismissed();

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;

    void           rebuildScreens();
    ProjectionMode computeDefaultMode() const;

    // Registry helpers.
    // Re-resolves every non-primary output's screenIndex against the display
    // list currently in m_impl->screens. Returns true when any placement
    // moved, so callers know whether to emit outputsChanged(). Runs both at
    // load (the stored index may be stale from a previous session) and on
    // every hot-plug.
    bool resolveOutputScreens();
    void seedBuiltinsIfMissing();
    void loadOutputsFromSettings();
    void persistOutput(const OutputBinding& b);
    void runLegacyMigration();
};

}  // namespace crater
