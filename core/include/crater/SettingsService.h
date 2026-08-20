#pragma once

#include <QObject>
#include <QString>
#include <QVariantMap>

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
    // Which of the two single-display arrangements the audience output
    // uses. Only consulted when there is exactly one screen.
    //
    // false (default): the former behaviour — demote to a small
    // windowed preview in the corner, floating above the console.
    // true: render fullscreen, at the size the audience would actually
    // see, but pinned beneath every other window. It cannot cover the
    // console because it is never allowed in front of it, and it shows
    // through wherever the console is not — snap the console to half
    // the screen and the other half becomes a true-size preview.
    //
    // Ignored with two displays attached: a fullscreen audience output
    // on its own screen must stay on TOP, or a notification toast lands
    // in front of the congregation. See ProjectionWindow.qml.
    Q_PROPERTY(bool    projectionBehindConsole READ projectionBehindConsole WRITE setProjectionBehindConsole NOTIFY projectionBehindConsoleChanged)
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
    // NDI broadcast pixel format — "bgra" (default, full 32-bit + alpha),
    // "bgrx" (32-bit, alpha ignored/opaque), or "uyvy" (4:2:2, ~half the
    // bandwidth, CPU pack per frame). And render resolution sent — "native"
    // (the 1920×1080 render) or "720p" (downscaled 1280×720). NdiService
    // reads both from QSettings at broadcast start (same lifecycle as
    // useHeadlessNdi), so a change applies on the next (re)start.
    Q_PROPERTY(QString ndiPixelFormat     READ ndiPixelFormat     WRITE setNdiPixelFormat     NOTIFY ndiPixelFormatChanged)
    Q_PROPERTY(QString ndiResolution      READ ndiResolution      WRITE setNdiResolution      NOTIFY ndiResolutionChanged)
    // Suppress picture / video items on the NDI broadcast only.
    // When true, an image or video that is live still fills the
    // audience screen, but the NDI scene renders it as a blank
    // frame. Lyrics, scripture and theme output are unaffected.
    //
    // Motivation: a stream carrying licensed footage or a slide of
    // faces often must not leave the room, while the room itself
    // still needs to see it. Suppressing at the NDI scene rather
    // than at the send boundary (where `blank` lives) keeps text
    // flowing to receivers instead of cutting the whole feed.
    //
    // Live, not deferred to the next broadcast start: the headless
    // renderer hosts its own ProjectionScene, so the QML binding
    // re-renders on the very next tick.
    Q_PROPERTY(bool    ndiHideMedia       READ ndiHideMedia       WRITE setNdiHideMedia       NOTIFY ndiHideMediaChanged)
    // Translation code (e.g. "KJV") preselected when Scripture opens. Stored
    // in the same uppercase form BibleService::translations() reports and the
    // scripture sidebar displays; AppState lowercases it to seed
    // activeLibraryGroup.scripture at startup.
    Q_PROPERTY(QString defaultScriptureVersion READ defaultScriptureVersion WRITE setDefaultScriptureVersion NOTIFY defaultScriptureVersionChanged)
    Q_PROPERTY(bool    showVerseNumbers   READ showVerseNumbers   WRITE setShowVerseNumbers   NOTIFY showVerseNumbersChanged)
    // Progressive verse highlight. When on, a multi-verse passage is projected
    // one page per verse — each page shows the whole passage with the current
    // verse at full brightness and the rest dimmed — so the operator walks the
    // highlight with the normal slide nav. Read by ScriptureTab at selection
    // time (it bakes the per-verse pages), so a change applies to the next
    // projected passage. Default off (it changes multi-verse nav granularity).
    Q_PROPERTY(bool    highlightCurrentVerse READ highlightCurrentVerse WRITE setHighlightCurrentVerse NOTIFY highlightCurrentVerseChanged)
    // Render a reference line (book chapter:verse) at the bottom of scripture
    // slides. A render-time overlay in ProjectionContentLayer honors this
    // regardless of whether the active theme authored its own reference node,
    // so the global toggle is always meaningful. Default off.
    Q_PROPERTY(bool    showScriptureFooter READ showScriptureFooter WRITE setShowScriptureFooter NOTIFY showScriptureFooterChanged)
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
    // Global default fit mode for projected image / video media items:
    // "contain" (default — letterbox, whole frame visible), "cover" (fill the
    // canvas, overflow cropped), or "stretch" (fill exactly, aspect ignored).
    // Applies to any media item whose own fit_mode is "default" (MediaItem's
    // per-item override wins otherwise). The render layer resolves the effective
    // fit; this is only the fallback. Default "contain" reproduces the prior
    // always-letterbox behavior so existing installs look unchanged.
    Q_PROPERTY(QString mediaDefaultFit    READ mediaDefaultFit    WRITE setMediaDefaultFit    NOTIFY mediaDefaultFitChanged)
    // Per-result-type primary action for the global search palette (Ctrl+K).
    // Maps a result type ("scripture" | "songs" | "strongs" | "media" |
    // "themes") to what its Enter/click fires: "preview" (stage into the
    // Preview pane, nothing projected), "reveal" (jump to the item in its
    // library tab), or "golive" (project immediately). Persisted as one JSON
    // object under Settings/globalSearchActions; the getter fills defaults for
    // any type the operator hasn't overridden, so QML always sees a complete
    // map. Defaults deliberately differ by type — projectable content
    // (scripture/songs/media) stages to Preview so nothing hits the screen by
    // accident, while lookup/manage types (strongs/themes) reveal in-tab. The
    // property is read-only from QML; writes go through setGlobalSearchAction()
    // so each change is validated and only touches one type.
    Q_PROPERTY(QVariantMap globalSearchActions READ globalSearchActions NOTIFY globalSearchActionsChanged)

    // ── Library search presentation ──────────────────────────────────────
    // How the library tabs present FTS search results. All default ON so the
    // out-of-box experience is unchanged; operators who find the highlight or
    // the lyric excerpt distracting can quiet each surface independently.
    //
    // showMatchedLyricSnippet — Songs only: swap the author subtitle for the
    // matched-lyric excerpt on a lyrics hit (and let the row grow to fit it).
    // highlight{Song,Scripture,Strongs}Matches — bold/accent the matched terms
    // in that tab's results. Per-tab because operators reasonably want the
    // colour in one library but not another.
    Q_PROPERTY(bool    showMatchedLyricSnippet   READ showMatchedLyricSnippet   WRITE setShowMatchedLyricSnippet   NOTIFY showMatchedLyricSnippetChanged)
    Q_PROPERTY(bool    highlightSongMatches      READ highlightSongMatches      WRITE setHighlightSongMatches      NOTIFY highlightSongMatchesChanged)
    Q_PROPERTY(bool    highlightScriptureMatches READ highlightScriptureMatches WRITE setHighlightScriptureMatches NOTIFY highlightScriptureMatchesChanged)
    Q_PROPERTY(bool    highlightStrongsMatches   READ highlightStrongsMatches   WRITE setHighlightStrongsMatches   NOTIFY highlightStrongsMatchesChanged)

    // UI language — the operator-console interface locale. "en" (default) is the
    // built-in English source; any other value is a Qt locale code (e.g. "es",
    // "pt_BR", "zh_CN") whose crater_<code>.qm catalog is loaded and installed.
    // Persisted here so the choice survives restarts and is read once at startup
    // — before QML loads — so the first paint is already in the chosen language.
    // The live-swap mechanism (QTranslator + QQmlEngine::retranslate) lives in
    // the app-layer TranslationService, which owns the engine; this service is
    // just the persisted source of truth it reads and writes.
    Q_PROPERTY(QString language           READ language           WRITE setLanguage           NOTIFY languageChanged)

    // ── Narration (docs/narration.md) ────────────────────────────────────
    // Absolute path to the whisper.cpp model the operator downloaded. Empty
    // until they choose one; NarrationService refuses to arm without it.
    // Models are never fetched by Crater — nothing in this subsystem touches
    // the network, which is what makes the offline requirement a security
    // property rather than a convenience (§7, §8).
    Q_PROPERTY(QString narrationModelPath READ narrationModelPath WRITE setNarrationModelPath NOTIFY narrationModelPathChanged)
    // "suggest" | "stage" | "auto" — the operator's trust level, crossed with
    // a detection's confidence tier by the gate in §5. Default "stage": a
    // detection reaches the Preview pane and never the audience screen unless
    // the operator explicitly opts into Auto.
    Q_PROPERTY(QString narrationMode      READ narrationMode      WRITE setNarrationMode      NOTIFY narrationModeChanged)
    // Cancel window before an Auto-mode detection is projected, in ms.
    // Clamped to 500..10000 on write.
    Q_PROPERTY(int     narrationGraceMs   READ narrationGraceMs   WRITE setNarrationGraceMs   NOTIFY narrationGraceMsChanged)
    // QAudioDevice::id() of the microphone to listen on. Empty means "whatever
    // the system calls default", which is the right default but a poor rule:
    // the machine driving a service usually has several inputs (a webcam, the
    // laptop lid array, the desk mic actually pointed at the preacher) and
    // Windows' idea of default is rarely the one on the pulpit.
    //
    // Stored as the opaque device id rather than the display name because
    // names are neither unique nor stable across reconnects. A saved id that
    // no longer resolves falls back to the default rather than refusing to
    // arm — the microphone the operator picked last month being unplugged is
    // not a reason to have no sound on Sunday.
    Q_PROPERTY(QString narrationInputDeviceId READ narrationInputDeviceId WRITE setNarrationInputDeviceId NOTIFY narrationInputDeviceIdChanged)
    // Note what is NOT here: any form of auto-arm. §8 forbids the microphone
    // opening on app start, schedule load, or go-live, and the way to keep
    // that true is to never give it a key it could be enabled from.

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
    bool    projectionBehindConsole() const;
    bool    useHeadlessNdi() const;
    bool    ndiOnDemand() const;
    QString ndiPixelFormat() const;
    QString ndiResolution() const;
    bool    ndiHideMedia() const;
    QString defaultScriptureVersion() const;
    bool    showVerseNumbers() const;
    bool    highlightCurrentVerse() const;
    bool    showScriptureFooter() const;
    bool    showStrongsTab() const;
    bool    showSongAuthor() const;
    bool    showSongCcli() const;
    bool    autoAdvance() const;
    int     autoAdvanceDelaySeconds() const;
    bool    autoAdvanceLoop() const;
    QString mediaDefaultFit() const;
    bool    showMatchedLyricSnippet() const;
    bool    highlightSongMatches() const;
    bool    highlightScriptureMatches() const;
    bool    highlightStrongsMatches() const;
    QString narrationModelPath() const;
    QString narrationMode() const;
    int     narrationGraceMs() const;
    QString narrationInputDeviceId() const;
    QString language() const;
    // True once the operator has explicitly chosen a UI language (the key
    // exists in QSettings). False on a fresh install — TranslationService uses
    // this to decide whether to adopt the OS language on first run.
    bool    hasExplicitLanguage() const;
    QVariantMap globalSearchActions() const;

    void setThemeMode(const QString& mode);
    void setFontSize(const QString& size);
    void setShowCcli(bool v);
    void setReduceMotion(bool v);
    void setShowLogoByDefault(bool v);
    void setOutputResolution(const QString& v);
    void setOutputMode(const QString& mode);
    void setProjectionInAltTab(bool v);
    void setProjectionBehindConsole(bool v);
    void setUseHeadlessNdi(bool v);
    void setNdiOnDemand(bool v);
    void setNdiPixelFormat(const QString& v);
    void setNdiResolution(const QString& v);
    void setNdiHideMedia(bool v);
    void setDefaultScriptureVersion(const QString& code);
    void setShowVerseNumbers(bool v);
    void setHighlightCurrentVerse(bool v);
    void setShowScriptureFooter(bool v);
    void setShowStrongsTab(bool v);
    void setShowSongAuthor(bool v);
    void setShowSongCcli(bool v);
    void setAutoAdvance(bool v);
    void setAutoAdvanceDelaySeconds(int v);
    void setAutoAdvanceLoop(bool v);
    void setMediaDefaultFit(const QString& v);
    void setShowMatchedLyricSnippet(bool v);
    void setHighlightSongMatches(bool v);
    void setHighlightScriptureMatches(bool v);
    void setHighlightStrongsMatches(bool v);
    void setNarrationModelPath(const QString& path);
    // Ignores anything outside {suggest, stage, auto} rather than falling back
    // to a default — see the implementation for why a safety control shouldn't
    // silently reinterpret a bad write.
    void setNarrationMode(const QString& mode);
    void setNarrationGraceMs(int ms);
    void setNarrationInputDeviceId(const QString& id);
    void setLanguage(const QString& code);

    // Set the global-search primary action for one result type. `type` and
    // `action` are validated against the known sets; unknown values are ignored
    // so a stray QML write can't persist a garbage mapping. Emits
    // globalSearchActionsChanged only when the mapping actually changes.
    Q_INVOKABLE void setGlobalSearchAction(const QString& type, const QString& action);

signals:
    void themeModeChanged();
    void fontSizeChanged();
    void showCcliChanged();
    void reduceMotionChanged();
    void showLogoByDefaultChanged();
    void outputResolutionChanged();
    void outputModeChanged();
    void projectionInAltTabChanged();
    void projectionBehindConsoleChanged();
    void useHeadlessNdiChanged();
    void ndiOnDemandChanged();
    void ndiPixelFormatChanged();
    void ndiResolutionChanged();
    void ndiHideMediaChanged();
    void defaultScriptureVersionChanged();
    void showVerseNumbersChanged();
    void highlightCurrentVerseChanged();
    void showScriptureFooterChanged();
    void showStrongsTabChanged();
    void showSongAuthorChanged();
    void showSongCcliChanged();
    void autoAdvanceChanged();
    void autoAdvanceDelaySecondsChanged();
    void autoAdvanceLoopChanged();
    void mediaDefaultFitChanged();
    void showMatchedLyricSnippetChanged();
    void highlightSongMatchesChanged();
    void highlightScriptureMatchesChanged();
    void highlightStrongsMatchesChanged();
    void languageChanged();
    void globalSearchActionsChanged();
    void narrationModelPathChanged();
    void narrationModeChanged();
    void narrationGraceMsChanged();
    void narrationInputDeviceIdChanged();

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

}  // namespace crater
