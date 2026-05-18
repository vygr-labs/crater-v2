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
// its "natural" service (e.g. CCLI display on SongService, verse numbers
// on BibleService): the Settings dialog reads/writes a uniform surface and
// having one source of truth means there is one place to look when an
// operator asks "did my toggle stick?" Consumers (QML views) bind to
// SettingsService.* directly; they don't need to know what underlying
// service the toggle conceptually belongs to.
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
    // Per-output theme overrides — each output can pin a specific theme that
    // wins over per-kind defaults. 0 means "no override; use per-kind default".
    // Only themeIdForPrimary drives rendering today (Primary HDMI is the
    // sole live output); NDI / Stage slots persist for the v1.1 multi-output
    // pipeline. AppState.resolveItemTheme consults Primary's slot.
    Q_PROPERTY(int     themeIdForPrimary  READ themeIdForPrimary  WRITE setThemeIdForPrimary  NOTIFY themeIdForPrimaryChanged)
    Q_PROPERTY(int     themeIdForNdi      READ themeIdForNdi      WRITE setThemeIdForNdi      NOTIFY themeIdForNdiChanged)
    Q_PROPERTY(int     themeIdForStage    READ themeIdForStage    WRITE setThemeIdForStage    NOTIFY themeIdForStageChanged)
    // Render-pipeline mode. "single" (default): NDI grabs frames from the
    // projection window's scene graph, so NDI inherits the projection's
    // theme and the projection window must stay alive (parked offscreen)
    // while broadcasting solo. "dual": a dedicated NdiCanvas window
    // renders its own scene with `themeIdForNdi` honored separately, and
    // the projection window can fully Window.Hidden when the operator
    // closes it. Dual mode costs one extra scene-graph evaluation per
    // frame; single mode is free. ThemesTab gates the "Set for NDI" menu
    // item on this, and AppState.resolveItemTheme only consults the NDI
    // slot when dual is active.
    Q_PROPERTY(QString outputMode         READ outputMode         WRITE setOutputMode         NOTIFY outputModeChanged)
    Q_PROPERTY(bool    showVerseNumbers   READ showVerseNumbers   WRITE setShowVerseNumbers   NOTIFY showVerseNumbersChanged)
    Q_PROPERTY(bool    showStrongsTab     READ showStrongsTab     WRITE setShowStrongsTab     NOTIFY showStrongsTabChanged)
    Q_PROPERTY(bool    showSongAuthor     READ showSongAuthor     WRITE setShowSongAuthor     NOTIFY showSongAuthorChanged)
    Q_PROPERTY(bool    showSongCcli       READ showSongCcli       WRITE setShowSongCcli       NOTIFY showSongCcliChanged)

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
    int     themeIdForPrimary() const;
    int     themeIdForNdi() const;
    int     themeIdForStage() const;
    QString outputMode() const;
    bool    showVerseNumbers() const;
    bool    showStrongsTab() const;
    bool    showSongAuthor() const;
    bool    showSongCcli() const;

    void setThemeMode(const QString& mode);
    void setFontSize(const QString& size);
    void setShowCcli(bool v);
    void setReduceMotion(bool v);
    void setShowLogoByDefault(bool v);
    void setOutputResolution(const QString& v);
    void setThemeIdForPrimary(int id);
    void setThemeIdForNdi(int id);
    void setThemeIdForStage(int id);
    void setOutputMode(const QString& mode);
    void setShowVerseNumbers(bool v);
    void setShowStrongsTab(bool v);
    void setShowSongAuthor(bool v);
    void setShowSongCcli(bool v);

signals:
    void themeModeChanged();
    void fontSizeChanged();
    void showCcliChanged();
    void reduceMotionChanged();
    void showLogoByDefaultChanged();
    void outputResolutionChanged();
    void themeIdForPrimaryChanged();
    void themeIdForNdiChanged();
    void themeIdForStageChanged();
    void outputModeChanged();
    void showVerseNumbersChanged();
    void showStrongsTabChanged();
    void showSongAuthorChanged();
    void showSongCcliChanged();

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

}  // namespace crater
