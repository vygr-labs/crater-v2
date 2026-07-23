#pragma once

#include <QObject>

#include <memory>

namespace crater {

// Operator preferences — every toggle/select the user can flip in the
// Settings dialog lives here. Mirrors OutputService's persistence pattern:
// one QSettings instance owned by the service, keys namespaced under
// "Settings/", every Q_PROPERTY writes through on its setter.
//
// Why a single grab-bag service rather than scattering each setting onto
// its "natural" service: the Settings dialog reads/writes a uniform surface
// and having one source of truth means there is one place to look when an
// operator asks "did my toggle stick?" Consumers (QML views) bind to
// SettingsService.* directly; they don't need to know what underlying
// service the toggle conceptually belongs to.
//
// Per-output state (theme assignments, transition style/duration) used to
// live here as parallel triples (themeIdForPrimary/Ndi/Stage etc) but moved
// to OutputService's per-output registry — see OutputBinding. The split
// follows §4 of the architecture doc: settings that vary with an output
// instance belong to the service that owns outputs.
//
// fontScale is a derived read-only property — fontSize is the canonical
// "small"/"medium"/"large" string, fontScale is the real-number multiplier
// Theme.uiScale binds to. Keeping the mapping inside the service rather
// than in QML keeps the design-token side (Theme) ignorant of UX string
// vocabulary.
class SettingsService : public QObject
{
    Q_OBJECT

private:
    Q_PROPERTY(QString themeMode          READ themeMode          WRITE setThemeMode          NOTIFY themeModeChanged)
    Q_PROPERTY(QString fontSize           READ fontSize           WRITE setFontSize           NOTIFY fontSizeChanged)
    Q_PROPERTY(qreal   fontScale          READ fontScale                                      NOTIFY fontSizeChanged)
    Q_PROPERTY(bool    showCcli           READ showCcli           WRITE setShowCcli           NOTIFY showCcliChanged)
    Q_PROPERTY(bool    reduceMotion       READ reduceMotion       WRITE setReduceMotion       NOTIFY reduceMotionChanged)
    Q_PROPERTY(bool    showLogoByDefault  READ showLogoByDefault  WRITE setShowLogoByDefault  NOTIFY showLogoByDefaultChanged)
    // Operator's preferred render resolution for the projection output. Today
    // this is persisted but not enforced — the projection window always uses
    // the destination display's native geometry. A future pass will letterbox
    // / scale content when this differs from the native res so themes
    // designed for 1080p look right on a 4K projector and vice versa.
    Q_PROPERTY(QString outputResolution   READ outputResolution   WRITE setOutputResolution   NOTIFY outputResolutionChanged)
    // Render-pipeline mode. "single" (default): NDI grabs frames from the
    // projection window's scene graph, so NDI inherits the projection's
    // theme and the projection window must stay alive (parked offscreen)
    // while broadcasting solo. "dual": a dedicated NdiCanvas window
    // renders its own scene with its own theme assignment honored
    // separately, and the projection window can fully Window.Hidden when
    // the operator closes it. Dual mode costs one extra scene-graph
    // evaluation per frame; single mode is free. ThemesTab gates the
    // "Set for NDI" menu item on this, and AppState.resolveItemTheme only
    // consults the NDI binding's theme slots when dual is active.
    Q_PROPERTY(QString outputMode         READ outputMode         WRITE setOutputMode         NOTIFY outputModeChanged)
    // Whether the projection window claims a taskbar button + Alt-Tab slot.
    // true (default): Qt.Window, so the operator can surface a backgrounded
    // projector by clicking it. false: Qt.Tool (WS_EX_TOOLWINDOW on Windows),
    // which hides it from BOTH the taskbar and the Alt-Tab switcher — for a
    // fixed projector the operator never tabs to. See ProjectionWindow.qml
    // flags; note it also removes the single-screen "click to surface" route.
    Q_PROPERTY(bool    projectionInAltTab READ projectionInAltTab WRITE setProjectionInAltTab NOTIFY projectionInAltTabChanged)
    // NDI render-pipeline backend. true (default): headless QQuickRenderControl
    // path — NDI scene renders into a GPU texture we own, with async readback
    // delivering frames to the sender; runs at 60 Hz adaptive (drops to 30 Hz
    // under sustained paint-cost pressure). false: legacy grabToImage path
    // that depends on a real QQuickWindow being exposed (NdiCanvas as a hidden
    // Item inside the operator console). Toggle is in the NDI section of
    // Settings; intended as a user-facing fallback if QRhi struggles on a
    // particular GPU. See qt/docs/render-pipeline-decouple.md.
    Q_PROPERTY(bool    useHeadlessNdi     READ useHeadlessNdi     WRITE setUseHeadlessNdi     NOTIFY useHeadlessNdiChanged)
    // On-demand NDI rendering. When true, the headless renderer renders +
    // reads back a frame ONLY when the scene graph is dirty (content / text /
    // transition change); between changes it re-sends the last frame at a low
    // keepalive rate and caps the cadence at 30 Hz. A large CPU win for the
    // mostly-static broadcasts NDI typically carries (e.g. a lower-third on its
    // own dual-output theme) on weak hardware. Default off — opt-in, applied on
    // the next broadcast (re)start (same as useHeadlessNdi). No effect on the
    // legacy grabToImage path.
    Q_PROPERTY(bool    ndiOnDemand        READ ndiOnDemand        WRITE setNdiOnDemand        NOTIFY ndiOnDemandChanged)
    // Translation code (e.g. "KJV") preselected when Scripture opens. Stored
    // in the same uppercase form BibleService::translations() reports and the
    // scripture sidebar displays; AppState lowercases it to seed
    // activeLibraryGroup.scripture at startup.
    Q_PROPERTY(QString defaultScriptureVersion READ defaultScriptureVersion WRITE setDefaultScriptureVersion NOTIFY defaultScriptureVersionChanged)
    Q_PROPERTY(bool    showVerseNumbers   READ showVerseNumbers   WRITE setShowVerseNumbers   NOTIFY showVerseNumbersChanged)
    Q_PROPERTY(bool    showStrongsTab     READ showStrongsTab     WRITE setShowStrongsTab     NOTIFY showStrongsTabChanged)
    Q_PROPERTY(bool    showSongAuthor     READ showSongAuthor     WRITE setShowSongAuthor     NOTIFY showSongAuthorChanged)
    Q_PROPERTY(bool    showSongCcli       READ showSongCcli       WRITE setShowSongCcli       NOTIFY showSongCcliChanged)
    // Auto-advance — when true, a live song steps to its next slide on a
    // timer. LivePanel owns the actual QML Timer (it holds the live slide
    // list + index + clear state); these are just the persisted operator
    // knobs. Delay is whole seconds; loop wraps past the last slide back to
    // the first instead of stopping. Unlike the song *default theme* (which
    // is ThemeService's kv-backed per-kind default), these have no other
    // home, so they live here.
    Q_PROPERTY(bool    autoAdvance             READ autoAdvance             WRITE setAutoAdvance             NOTIFY autoAdvanceChanged)
    Q_PROPERTY(int     autoAdvanceDelaySeconds READ autoAdvanceDelaySeconds WRITE setAutoAdvanceDelaySeconds NOTIFY autoAdvanceDelaySecondsChanged)
    Q_PROPERTY(bool    autoAdvanceLoop         READ autoAdvanceLoop         WRITE setAutoAdvanceLoop         NOTIFY autoAdvanceLoopChanged)

public:
    explicit SettingsService(QObject* parent = nullptr);
    ~SettingsService() override;

    QString themeMode() const;
    QString fontSize() const;
    qreal   fontScale() const;
    bool    showCcli() const;
    bool    reduceMotion() const;
    bool    showLogoByDefault() const;
    QString outputResolution() const;
    QString outputMode() const;
    bool    projectionInAltTab() const;
    bool    useHeadlessNdi() const;
    bool    ndiOnDemand() const;
    QString defaultScriptureVersion() const;
    bool    showVerseNumbers() const;
    bool    showStrongsTab() const;
    bool    showSongAuthor() const;
    bool    showSongCcli() const;
    bool    autoAdvance() const;
    int     autoAdvanceDelaySeconds() const;
    bool    autoAdvanceLoop() const;

    void setThemeMode(const QString& mode);
    void setFontSize(const QString& size);
    void setShowCcli(bool v);
    void setReduceMotion(bool v);
    void setShowLogoByDefault(bool v);
    void setOutputResolution(const QString& v);
    void setOutputMode(const QString& mode);
    void setProjectionInAltTab(bool v);
    void setUseHeadlessNdi(bool v);
    void setNdiOnDemand(bool v);
    void setDefaultScriptureVersion(const QString& code);
    void setShowVerseNumbers(bool v);
    void setShowStrongsTab(bool v);
    void setShowSongAuthor(bool v);
    void setShowSongCcli(bool v);
    void setAutoAdvance(bool v);
    void setAutoAdvanceDelaySeconds(int v);
    void setAutoAdvanceLoop(bool v);

signals:
    void themeModeChanged();
    void fontSizeChanged();
    void showCcliChanged();
    void reduceMotionChanged();
    void showLogoByDefaultChanged();
    void outputResolutionChanged();
    void outputModeChanged();
    void projectionInAltTabChanged();
    void useHeadlessNdiChanged();
    void ndiOnDemandChanged();
    void defaultScriptureVersionChanged();
    void showVerseNumbersChanged();
    void showStrongsTabChanged();
    void showSongAuthorChanged();
    void showSongCcliChanged();
    void autoAdvanceChanged();
    void autoAdvanceDelaySecondsChanged();
    void autoAdvanceLoopChanged();

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

}  // namespace crater
