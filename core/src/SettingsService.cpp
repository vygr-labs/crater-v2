#include "crater/SettingsService.h"

#include <QSettings>

namespace crater {

struct SettingsService::Impl
{
    // Mirrors OutputService's QSettings instance — same organisation +
    // application names, so all of Crater's persisted state lives in one
    // registry hive on Windows / one config plist on macOS.
    QSettings settings{QStringLiteral("Voyager Labs"), QStringLiteral("Crater")};

    // Cached state — read once at construction, mutated through setters
    // that also write through to QSettings. QSettings access is durable
    // but slow; the in-memory mirror serves rapid Q_PROPERTY reads from
    // QML bindings that fire on every paint.
    QString themeMode        = QStringLiteral("dark");
    QString fontSize         = QStringLiteral("medium");
    bool    showCcli         = true;
    bool    reduceMotion     = false;
    bool    showLogoByDef    = false;
    // 1080p is the safest default — covers a clear majority of projectors
    // and TVs in the worship space. 4K and 720p are picker options in the
    // dialog but the persisted default never silently grows past 1080p.
    QString outputResolution = QStringLiteral("1920×1080");
    // Per-output theme overrides. 0 = no override (fall back to kind default).
    int     themeIdForPrimary = 0;
    int     themeIdForNdi     = 0;
    int     themeIdForStage   = 0;
    // Render-pipeline mode — see header. "single" is the lower-cost default
    // (NDI mirrors projection); "dual" enables independent NDI scene + theme.
    QString outputMode       = QStringLiteral("single");
    bool    showVerseNums    = true;
    bool    showStrongs      = true;
    bool    showSongAuthor   = true;
    bool    showSongCcli     = true;

    // "Settings/" prefix groups every key under this service so the
    // QSettings tree stays self-documenting: anything outside this prefix
    // belongs to another service (e.g. "Output/" for OutputService).
    static constexpr const char* kThemeMode      = "Settings/themeMode";
    static constexpr const char* kFontSize       = "Settings/fontSize";
    static constexpr const char* kShowCcli       = "Settings/showCcli";
    static constexpr const char* kReduceMotion   = "Settings/reduceMotion";
    static constexpr const char* kShowLogo       = "Settings/showLogoByDefault";
    static constexpr const char* kOutputResolution = "Settings/outputResolution";
    static constexpr const char* kThemeForPrimary  = "Settings/themeIdForPrimary";
    static constexpr const char* kThemeForNdi      = "Settings/themeIdForNdi";
    static constexpr const char* kThemeForStage    = "Settings/themeIdForStage";
    static constexpr const char* kOutputMode       = "Settings/outputMode";
    static constexpr const char* kShowVerseNums  = "Settings/showVerseNumbers";
    static constexpr const char* kShowStrongs    = "Settings/showStrongsTab";
    static constexpr const char* kShowSongAuth   = "Settings/showSongAuthor";
    static constexpr const char* kShowSongCcli   = "Settings/showSongCcli";
};

SettingsService::SettingsService(QObject* parent)
    : QObject(parent)
    , m_impl(std::make_unique<Impl>())
{
    auto& s = m_impl->settings;
    m_impl->themeMode      = s.value(QString::fromLatin1(Impl::kThemeMode),     m_impl->themeMode).toString();
    m_impl->fontSize       = s.value(QString::fromLatin1(Impl::kFontSize),      m_impl->fontSize).toString();
    m_impl->showCcli       = s.value(QString::fromLatin1(Impl::kShowCcli),      m_impl->showCcli).toBool();
    m_impl->reduceMotion   = s.value(QString::fromLatin1(Impl::kReduceMotion),  m_impl->reduceMotion).toBool();
    m_impl->showLogoByDef    = s.value(QString::fromLatin1(Impl::kShowLogo),         m_impl->showLogoByDef).toBool();
    m_impl->outputResolution = s.value(QString::fromLatin1(Impl::kOutputResolution), m_impl->outputResolution).toString();
    m_impl->themeIdForPrimary = s.value(QString::fromLatin1(Impl::kThemeForPrimary), m_impl->themeIdForPrimary).toInt();
    m_impl->themeIdForNdi     = s.value(QString::fromLatin1(Impl::kThemeForNdi),     m_impl->themeIdForNdi).toInt();
    m_impl->themeIdForStage   = s.value(QString::fromLatin1(Impl::kThemeForStage),   m_impl->themeIdForStage).toInt();
    m_impl->outputMode        = s.value(QString::fromLatin1(Impl::kOutputMode),      m_impl->outputMode).toString();
    m_impl->showVerseNums    = s.value(QString::fromLatin1(Impl::kShowVerseNums),    m_impl->showVerseNums).toBool();
    m_impl->showStrongs    = s.value(QString::fromLatin1(Impl::kShowStrongs),   m_impl->showStrongs).toBool();
    m_impl->showSongAuthor = s.value(QString::fromLatin1(Impl::kShowSongAuth),  m_impl->showSongAuthor).toBool();
    m_impl->showSongCcli   = s.value(QString::fromLatin1(Impl::kShowSongCcli),  m_impl->showSongCcli).toBool();
}

SettingsService::~SettingsService() = default;

QString SettingsService::themeMode() const         { return m_impl->themeMode; }
QString SettingsService::fontSize() const          { return m_impl->fontSize; }
bool    SettingsService::showCcli() const          { return m_impl->showCcli; }
bool    SettingsService::reduceMotion() const      { return m_impl->reduceMotion; }
bool    SettingsService::showLogoByDefault() const { return m_impl->showLogoByDef; }
QString SettingsService::outputResolution() const  { return m_impl->outputResolution; }
int     SettingsService::themeIdForPrimary() const { return m_impl->themeIdForPrimary; }
int     SettingsService::themeIdForNdi() const     { return m_impl->themeIdForNdi; }
int     SettingsService::themeIdForStage() const   { return m_impl->themeIdForStage; }
QString SettingsService::outputMode() const        { return m_impl->outputMode; }
bool    SettingsService::showVerseNumbers() const  { return m_impl->showVerseNums; }
bool    SettingsService::showStrongsTab() const    { return m_impl->showStrongs; }
bool    SettingsService::showSongAuthor() const    { return m_impl->showSongAuthor; }
bool    SettingsService::showSongCcli() const      { return m_impl->showSongCcli; }

qreal SettingsService::fontScale() const
{
    // S / M / L map to scale factors applied to Theme.font.* + Theme.icon.*
    // through Theme.uiScale. M is the design baseline. S compresses for
    // dense schedules on smaller laptops; L gives operators reading
    // headroom on the projector-driving machine without trashing layout.
    const auto& f = m_impl->fontSize;
    if (f == QStringLiteral("small"))  return 0.90;
    if (f == QStringLiteral("large"))  return 1.15;
    return 1.00;  // "medium" + any unrecognized value
}

void SettingsService::setThemeMode(const QString& mode)
{
    if (m_impl->themeMode == mode) return;
    m_impl->themeMode = mode;
    m_impl->settings.setValue(QString::fromLatin1(Impl::kThemeMode), mode);
    emit themeModeChanged();
}

void SettingsService::setFontSize(const QString& size)
{
    if (m_impl->fontSize == size) return;
    m_impl->fontSize = size;
    m_impl->settings.setValue(QString::fromLatin1(Impl::kFontSize), size);
    emit fontSizeChanged();
}

void SettingsService::setShowCcli(bool v)
{
    if (m_impl->showCcli == v) return;
    m_impl->showCcli = v;
    m_impl->settings.setValue(QString::fromLatin1(Impl::kShowCcli), v);
    emit showCcliChanged();
}

void SettingsService::setReduceMotion(bool v)
{
    if (m_impl->reduceMotion == v) return;
    m_impl->reduceMotion = v;
    m_impl->settings.setValue(QString::fromLatin1(Impl::kReduceMotion), v);
    emit reduceMotionChanged();
}

void SettingsService::setShowLogoByDefault(bool v)
{
    if (m_impl->showLogoByDef == v) return;
    m_impl->showLogoByDef = v;
    m_impl->settings.setValue(QString::fromLatin1(Impl::kShowLogo), v);
    emit showLogoByDefaultChanged();
}

void SettingsService::setOutputResolution(const QString& v)
{
    if (m_impl->outputResolution == v) return;
    m_impl->outputResolution = v;
    m_impl->settings.setValue(QString::fromLatin1(Impl::kOutputResolution), v);
    emit outputResolutionChanged();
}

void SettingsService::setThemeIdForPrimary(int id)
{
    if (m_impl->themeIdForPrimary == id) return;
    m_impl->themeIdForPrimary = id;
    m_impl->settings.setValue(QString::fromLatin1(Impl::kThemeForPrimary), id);
    emit themeIdForPrimaryChanged();
}

void SettingsService::setThemeIdForNdi(int id)
{
    if (m_impl->themeIdForNdi == id) return;
    m_impl->themeIdForNdi = id;
    m_impl->settings.setValue(QString::fromLatin1(Impl::kThemeForNdi), id);
    emit themeIdForNdiChanged();
}

void SettingsService::setThemeIdForStage(int id)
{
    if (m_impl->themeIdForStage == id) return;
    m_impl->themeIdForStage = id;
    m_impl->settings.setValue(QString::fromLatin1(Impl::kThemeForStage), id);
    emit themeIdForStageChanged();
}

void SettingsService::setOutputMode(const QString& mode)
{
    // Guard against arbitrary string writes from QML. Anything outside the
    // two known states collapses to "single" so a future renamed sentinel
    // never silently flips on the dual-render pipeline.
    const QString normalized =
        (mode == QStringLiteral("dual")) ? QStringLiteral("dual")
                                         : QStringLiteral("single");
    if (m_impl->outputMode == normalized) return;
    m_impl->outputMode = normalized;
    m_impl->settings.setValue(QString::fromLatin1(Impl::kOutputMode), normalized);
    emit outputModeChanged();
}

void SettingsService::setShowVerseNumbers(bool v)
{
    if (m_impl->showVerseNums == v) return;
    m_impl->showVerseNums = v;
    m_impl->settings.setValue(QString::fromLatin1(Impl::kShowVerseNums), v);
    emit showVerseNumbersChanged();
}

void SettingsService::setShowStrongsTab(bool v)
{
    if (m_impl->showStrongs == v) return;
    m_impl->showStrongs = v;
    m_impl->settings.setValue(QString::fromLatin1(Impl::kShowStrongs), v);
    emit showStrongsTabChanged();
}

void SettingsService::setShowSongAuthor(bool v)
{
    if (m_impl->showSongAuthor == v) return;
    m_impl->showSongAuthor = v;
    m_impl->settings.setValue(QString::fromLatin1(Impl::kShowSongAuth), v);
    emit showSongAuthorChanged();
}

void SettingsService::setShowSongCcli(bool v)
{
    if (m_impl->showSongCcli == v) return;
    m_impl->showSongCcli = v;
    m_impl->settings.setValue(QString::fromLatin1(Impl::kShowSongCcli), v);
    emit showSongCcliChanged();
}

}  // namespace crater
