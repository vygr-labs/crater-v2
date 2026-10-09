#include "crater/SettingsService.h"

#include "profile/ProfileSettings.h"

#include <QJsonDocument>
#include <QJsonObject>
#include <QSettings>
#include <QStringList>

namespace crater {

namespace {

// Global-search palette validation + defaults, kept in one place so the ctor
// read, the getter's default fill, and setGlobalSearchAction() agree on what a
// legal (type, action) pair is.
const QStringList& gsTypes()
{
    static const QStringList t{ QStringLiteral("scripture"), QStringLiteral("songs"),
                                QStringLiteral("strongs"),   QStringLiteral("media"),
                                QStringLiteral("themes") };
    return t;
}

bool gsIsAction(const QString& a)
{
    return a == QLatin1String("preview")
        || a == QLatin1String("reveal")
        || a == QLatin1String("golive");
}

// Defaults deliberately differ by type — see the header note. Projectable
// content stages to Preview (safe: nothing hits the projector by accident);
// lookup/manage types reveal in their tab.
QVariantMap gsDefaults()
{
    QVariantMap m;
    m.insert(QStringLiteral("scripture"), QStringLiteral("preview"));
    m.insert(QStringLiteral("songs"),     QStringLiteral("preview"));
    m.insert(QStringLiteral("media"),     QStringLiteral("preview"));
    m.insert(QStringLiteral("strongs"),   QStringLiteral("reveal"));
    m.insert(QStringLiteral("themes"),    QStringLiteral("reveal"));
    return m;
}

}  // namespace

struct SettingsService::Impl
{
    // Mirrors OutputService's QSettings instance — same organisation +
    // application names, so all of Crater's persisted state lives in one
    // registry hive on Windows / one config plist on macOS.
    QSettings settings{QStringLiteral("Voyager Labs"), QStringLiteral("Crater")};

    // Content preferences follow the active profile (ARCHITECTURE.md §12.2).
    // For the Default profile this opens the same registry hive as
    // `settings` above, so an existing install reads exactly what it always
    // did; any other profile keeps them in its own settings.ini. get/put
    // route each key to the right store so no setter has to know.
    std::unique_ptr<QSettings> profileStore = profile::openProfileSettings();

    QSettings& storeFor(const char* key)
    {
        return profile::isPerProfileSettingKey(QString::fromLatin1(key)) ? *profileStore : settings;
    }
    QVariant get(const char* key, const QVariant& fallback = {})
    {
        return storeFor(key).value(QString::fromLatin1(key), fallback);
    }
    void put(const char* key, const QVariant& v)
    {
        storeFor(key).setValue(QString::fromLatin1(key), v);
    }

    // Cached state — read once at construction, mutated through setters
    // that also write through to QSettings. QSettings access is durable
    // but slow; the in-memory mirror serves rapid Q_PROPERTY reads from
    // QML bindings that fire on every paint.
    QString themeMode        = QStringLiteral("dark");
    QString fontSize         = QStringLiteral("medium");
    QString uiDensity        = QStringLiteral("compact");
    QString previewCardMode  = QStringLiteral("full");
    QString liveCardMode     = QStringLiteral("full");
    bool    showCcli         = true;
    bool    reduceMotion     = false;
    bool    showLogoByDef    = false;
    // On by default: operators build a fresh schedule per service, and a
    // stale one reappearing on launch was the reported annoyance.
    bool    clearScheduleOnClose = true;
    // 1080p is the safest default — covers a clear majority of projectors
    // and TVs in the worship space. 4K and 720p are picker options in the
    // dialog but the persisted default never silently grows past 1080p.
    QString outputResolution = QStringLiteral("1920×1080");
    // Render-pipeline mode — see header. "single" is the lower-cost default
    // (NDI mirrors projection); "dual" enables independent NDI scene + theme.
    QString outputMode       = QStringLiteral("single");
    // Projection window taskbar / Alt-Tab presence — see header. Default true
    // preserves the standard behavior (own taskbar button + switcher slot).
    bool    projectionInAltTab = true;
    bool    projectionBehindConsole = false;
    bool    autoScrollPreview = true;
    bool    autoScrollLive = true;
    bool    autoScrollLibrary = true;
    // Live dock over dialogs — see header for why this defaults on.
    bool    liveControlsOverDialogs = true;
    // Headless NDI renderer toggle — see header. Default true so the QRhi
    // path is the standard production behavior; flipping false drops back to
    // the legacy grabToImage path as a fallback.
    bool    useHeadlessNdi   = true;
    // Off by default — opt-in low-CPU path for static broadcasts. See header.
    bool    ndiOnDemand      = false;
    // NDI broadcast format + resolution. Defaults reproduce the pre-existing
    // fixed path exactly (BGRA, native 1080p render).
    QString ndiPixelFormat   = QStringLiteral("bgra");
    QString ndiResolution    = QStringLiteral("native");
    bool    ndiHideMedia     = false;
    // KJV is the translation that ships with every install, so it's the safe
    // default. Stored uppercase to match BibleService::translations() codes.
    QString defaultScriptureVersion = QStringLiteral("KJV");
    bool    showVerseNums    = true;
    bool    highlightVerse   = false;
    bool    showScriptureFooter = false;
    bool    showStrongs      = true;
    QString scriptureInputMode = QStringLiteral("crater");
    bool    preloadTranslations = false;
    QStringList translationOrder;     // empty: the library's own order
    QStringList hiddenTranslations;   // empty: show everything
    bool    showSongAuthor   = false;
    bool    showSongCcli     = false;
    // Auto-advance defaults: off, 20 s between slides, no looping.
    bool    autoAdvance      = false;
    int     autoAdvanceDelay = 20;
    bool    autoAdvanceLoop  = false;
    // "contain" (letterbox) is the safe default — it never crops content the
    // operator might not know is being clipped. Cover/stretch are opt-in.
    QString mediaDefaultFit  = QStringLiteral("contain");
    double  mediaVolume      = 1.0;
    // Library search presentation — all default ON (unchanged out-of-box).
    bool    showMatchedLyricSnippet   = true;
    bool    highlightSongMatches      = true;
    bool    highlightScriptureMatches = true;
    bool    highlightStrongsMatches   = true;
    // ── Narration (docs/narration.md) ────────────────────────────────────
    // Empty model path by default and NO auto-arm key of any kind. §8 makes
    // "the microphone opens on an explicit operator action and on nothing
    // else" a property of the design rather than a default, so there is
    // deliberately no setting here that could turn it into a preference.
    QString narrationModelPath;
    // "stage" is the default trust level per the §5 matrix: detections reach
    // the Preview pane, never the audience screen, without the operator
    // opting into Auto.
    QString narrationMode    = QStringLiteral("stage");
    // Empty = the system default input. See the header for why the id is
    // stored rather than the device name.
    QString narrationInputDeviceId;
    // Cancel window before an Auto-mode detection is projected. 1.5 s is long
    // enough for an operator watching the console to catch a wrong call and
    // short enough that a correct one still feels automatic.
    int     narrationGraceMs = 1500;
    // UI language — "en" is the built-in English source; any other value is a
    // Qt locale code with a bundled crater_<code>.qm catalog. See header.
    QString language         = QStringLiteral("en");
    // Per-type global-search actions. Seeded with gsDefaults() then overlaid
    // with any persisted overrides at construction, so it's always complete.
    QVariantMap globalSearchActions;

    // "Settings/" prefix groups every key under this service so the
    // QSettings tree stays self-documenting: anything outside this prefix
    // belongs to another service (e.g. "Output/" + "Outputs/" for
    // OutputService).
    static constexpr const char* kThemeMode      = "Settings/themeMode";
    static constexpr const char* kFontSize       = "Settings/fontSize";
    static constexpr const char* kUiDensity      = "Settings/uiDensity";
    static constexpr const char* kPreviewCards   = "Settings/previewCardMode";
    static constexpr const char* kLiveCards      = "Settings/liveCardMode";
    static constexpr const char* kShowCcli       = "Settings/showCcli";
    static constexpr const char* kReduceMotion   = "Settings/reduceMotion";
    static constexpr const char* kShowLogo       = "Settings/showLogoByDefault";
    static constexpr const char* kClearScheduleOnClose = "Settings/clearScheduleOnClose";
    static constexpr const char* kOutputResolution = "Settings/outputResolution";
    static constexpr const char* kOutputMode       = "Settings/outputMode";
    static constexpr const char* kProjectionInAltTab = "Settings/projectionInAltTab";
    static constexpr const char* kProjectionBehindConsole = "Settings/projectionBehindConsole";
    static constexpr const char* kAutoScrollPreview = "Settings/autoScrollPreview";
    static constexpr const char* kAutoScrollLive = "Settings/autoScrollLive";
    static constexpr const char* kAutoScrollLibrary = "Settings/autoScrollLibrary";
    static constexpr const char* kLiveControlsOverDialogs = "Settings/liveControlsOverDialogs";
    static constexpr const char* kUseHeadlessNdi   = "Settings/useHeadlessNdi";
    static constexpr const char* kNdiOnDemand      = "Settings/ndiOnDemand";
    static constexpr const char* kNdiPixelFormat   = "Settings/ndiPixelFormat";
    static constexpr const char* kNdiResolution    = "Settings/ndiResolution";
    static constexpr const char* kNdiHideMedia     = "Settings/ndiHideMedia";
    static constexpr const char* kDefaultScriptureVersion = "Settings/defaultScriptureVersion";
    static constexpr const char* kShowVerseNums  = "Settings/showVerseNumbers";
    static constexpr const char* kHighlightVerse = "Settings/highlightCurrentVerse";
    static constexpr const char* kShowScriptureFooter = "Settings/showScriptureFooter";
    static constexpr const char* kShowStrongs    = "Settings/showStrongsTab";
    static constexpr const char* kScriptureInputMode = "Settings/scriptureInputMode";
    static constexpr const char* kPreloadTranslations = "Settings/preloadTranslations";
    static constexpr const char* kTranslationOrder    = "Settings/translationOrder";
    static constexpr const char* kHiddenTranslations  = "Settings/hiddenTranslations";
    static constexpr const char* kShowSongAuth   = "Settings/showSongAuthor";
    static constexpr const char* kShowSongCcli   = "Settings/showSongCcli";
    static constexpr const char* kAutoAdvance      = "Settings/autoAdvance";
    static constexpr const char* kAutoAdvanceDelay = "Settings/autoAdvanceDelaySeconds";
    static constexpr const char* kAutoAdvanceLoop  = "Settings/autoAdvanceLoop";
    static constexpr const char* kMediaDefaultFit = "Settings/mediaDefaultFit";
    static constexpr const char* kMediaVolume     = "Settings/mediaVolume";
    static constexpr const char* kShowMatchedLyricSnippet   = "Settings/showMatchedLyricSnippet";
    static constexpr const char* kHighlightSongMatches      = "Settings/highlightSongMatches";
    static constexpr const char* kHighlightScriptureMatches = "Settings/highlightScriptureMatches";
    static constexpr const char* kHighlightStrongsMatches   = "Settings/highlightStrongsMatches";
    static constexpr const char* kLanguage         = "Settings/language";
    static constexpr const char* kGlobalSearchActions = "Settings/globalSearchActions";
    static constexpr const char* kNarrationModelPath = "Settings/narrationModelPath";
    static constexpr const char* kNarrationMode      = "Settings/narrationMode";
    static constexpr const char* kNarrationGraceMs   = "Settings/narrationGraceMs";
    static constexpr const char* kNarrationInputDeviceId = "Settings/narrationInputDeviceId";
};

SettingsService::SettingsService(QObject* parent)
    : QObject(parent)
    , m_impl(std::make_unique<Impl>())
{
    m_impl->themeMode      = m_impl->get(Impl::kThemeMode, m_impl->themeMode).toString();
    m_impl->fontSize       = m_impl->get(Impl::kFontSize, m_impl->fontSize).toString();
    m_impl->uiDensity      = m_impl->get(Impl::kUiDensity, m_impl->uiDensity).toString();
    m_impl->previewCardMode = m_impl->get(Impl::kPreviewCards, m_impl->previewCardMode).toString();
    m_impl->liveCardMode   = m_impl->get(Impl::kLiveCards, m_impl->liveCardMode).toString();
    m_impl->showCcli       = m_impl->get(Impl::kShowCcli, m_impl->showCcli).toBool();
    m_impl->reduceMotion   = m_impl->get(Impl::kReduceMotion, m_impl->reduceMotion).toBool();
    m_impl->showLogoByDef    = m_impl->get(Impl::kShowLogo, m_impl->showLogoByDef).toBool();
    m_impl->clearScheduleOnClose = m_impl->get(Impl::kClearScheduleOnClose, m_impl->clearScheduleOnClose).toBool();
    m_impl->outputResolution = m_impl->get(Impl::kOutputResolution, m_impl->outputResolution).toString();
    m_impl->outputMode        = m_impl->get(Impl::kOutputMode, m_impl->outputMode).toString();
    m_impl->projectionInAltTab = m_impl->get(Impl::kProjectionInAltTab, m_impl->projectionInAltTab).toBool();
    m_impl->projectionBehindConsole = m_impl->get(Impl::kProjectionBehindConsole, m_impl->projectionBehindConsole).toBool();
    m_impl->autoScrollPreview = m_impl->get(Impl::kAutoScrollPreview, m_impl->autoScrollPreview).toBool();
    m_impl->autoScrollLive = m_impl->get(Impl::kAutoScrollLive, m_impl->autoScrollLive).toBool();
    m_impl->autoScrollLibrary = m_impl->get(Impl::kAutoScrollLibrary, m_impl->autoScrollLibrary).toBool();
    m_impl->liveControlsOverDialogs = m_impl->get(Impl::kLiveControlsOverDialogs, m_impl->liveControlsOverDialogs).toBool();
    m_impl->useHeadlessNdi    = m_impl->get(Impl::kUseHeadlessNdi, m_impl->useHeadlessNdi).toBool();
    m_impl->ndiOnDemand       = m_impl->get(Impl::kNdiOnDemand, m_impl->ndiOnDemand).toBool();
    m_impl->ndiPixelFormat    = m_impl->get(Impl::kNdiPixelFormat, m_impl->ndiPixelFormat).toString();
    m_impl->ndiResolution     = m_impl->get(Impl::kNdiResolution, m_impl->ndiResolution).toString();
    m_impl->ndiHideMedia      = m_impl->get(Impl::kNdiHideMedia, m_impl->ndiHideMedia).toBool();
    m_impl->defaultScriptureVersion = m_impl->get(Impl::kDefaultScriptureVersion, m_impl->defaultScriptureVersion).toString();
    m_impl->showVerseNums    = m_impl->get(Impl::kShowVerseNums, m_impl->showVerseNums).toBool();
    m_impl->highlightVerse   = m_impl->get(Impl::kHighlightVerse, m_impl->highlightVerse).toBool();
    m_impl->showScriptureFooter = m_impl->get(Impl::kShowScriptureFooter, m_impl->showScriptureFooter).toBool();
    m_impl->showStrongs    = m_impl->get(Impl::kShowStrongs, m_impl->showStrongs).toBool();
    m_impl->scriptureInputMode = m_impl->get(Impl::kScriptureInputMode, m_impl->scriptureInputMode).toString();
    if (m_impl->scriptureInputMode != QStringLiteral("controlled"))
        m_impl->scriptureInputMode = QStringLiteral("crater");
    m_impl->preloadTranslations = m_impl->get(Impl::kPreloadTranslations, m_impl->preloadTranslations).toBool();
    m_impl->translationOrder    = m_impl->get(Impl::kTranslationOrder, QStringList()).toStringList();
    m_impl->hiddenTranslations  = m_impl->get(Impl::kHiddenTranslations, QStringList()).toStringList();
    m_impl->showSongAuthor = m_impl->get(Impl::kShowSongAuth, m_impl->showSongAuthor).toBool();
    m_impl->showSongCcli   = m_impl->get(Impl::kShowSongCcli, m_impl->showSongCcli).toBool();
    m_impl->autoAdvance      = m_impl->get(Impl::kAutoAdvance, m_impl->autoAdvance).toBool();
    m_impl->autoAdvanceDelay = m_impl->get(Impl::kAutoAdvanceDelay, m_impl->autoAdvanceDelay).toInt();
    m_impl->autoAdvanceLoop  = m_impl->get(Impl::kAutoAdvanceLoop, m_impl->autoAdvanceLoop).toBool();
    m_impl->mediaDefaultFit = m_impl->get(Impl::kMediaDefaultFit, m_impl->mediaDefaultFit).toString();
    m_impl->mediaVolume     = qBound(0.0, m_impl->get(Impl::kMediaVolume, m_impl->mediaVolume).toDouble(), 1.0);
    m_impl->showMatchedLyricSnippet   = m_impl->get(Impl::kShowMatchedLyricSnippet, m_impl->showMatchedLyricSnippet).toBool();
    m_impl->highlightSongMatches      = m_impl->get(Impl::kHighlightSongMatches, m_impl->highlightSongMatches).toBool();
    m_impl->highlightScriptureMatches = m_impl->get(Impl::kHighlightScriptureMatches, m_impl->highlightScriptureMatches).toBool();
    m_impl->highlightStrongsMatches   = m_impl->get(Impl::kHighlightStrongsMatches, m_impl->highlightStrongsMatches).toBool();
    m_impl->language         = m_impl->get(Impl::kLanguage, m_impl->language).toString();
    m_impl->narrationModelPath = m_impl->get(Impl::kNarrationModelPath, m_impl->narrationModelPath).toString();
    m_impl->narrationMode      = m_impl->get(Impl::kNarrationMode, m_impl->narrationMode).toString();
    m_impl->narrationGraceMs   = m_impl->get(Impl::kNarrationGraceMs, m_impl->narrationGraceMs).toInt();
    m_impl->narrationInputDeviceId = m_impl->get(Impl::kNarrationInputDeviceId, m_impl->narrationInputDeviceId).toString();

    // Global-search actions: start from the per-type defaults, then overlay any
    // persisted overrides. Each override is validated so a hand-edited or
    // stale registry value can't seed an unknown type/action into the map.
    m_impl->globalSearchActions = gsDefaults();
    {
        const QString raw = m_impl->get(Impl::kGlobalSearchActions).toString();
        if (!raw.isEmpty()) {
            const QJsonObject obj = QJsonDocument::fromJson(raw.toUtf8()).object();
            for (auto it = obj.constBegin(); it != obj.constEnd(); ++it) {
                const QString action = it.value().toString();
                if (gsTypes().contains(it.key()) && gsIsAction(action))
                    m_impl->globalSearchActions.insert(it.key(), action);
            }
        }
    }
}

SettingsService::~SettingsService() = default;

QString SettingsService::themeMode() const         { return m_impl->themeMode; }
QString SettingsService::fontSize() const          { return m_impl->fontSize; }
bool    SettingsService::showCcli() const          { return m_impl->showCcli; }
bool    SettingsService::reduceMotion() const      { return m_impl->reduceMotion; }
bool    SettingsService::showLogoByDefault() const { return m_impl->showLogoByDef; }
bool    SettingsService::clearScheduleOnClose() const { return m_impl->clearScheduleOnClose; }
QString SettingsService::outputResolution() const  { return m_impl->outputResolution; }
QString SettingsService::outputMode() const        { return m_impl->outputMode; }
bool    SettingsService::projectionInAltTab() const { return m_impl->projectionInAltTab; }
bool    SettingsService::projectionBehindConsole() const { return m_impl->projectionBehindConsole; }
bool    SettingsService::autoScrollPreview() const { return m_impl->autoScrollPreview; }
bool    SettingsService::autoScrollLive() const { return m_impl->autoScrollLive; }
bool    SettingsService::autoScrollLibrary() const { return m_impl->autoScrollLibrary; }
bool    SettingsService::liveControlsOverDialogs() const { return m_impl->liveControlsOverDialogs; }
bool    SettingsService::useHeadlessNdi() const    { return m_impl->useHeadlessNdi; }
bool    SettingsService::ndiOnDemand() const       { return m_impl->ndiOnDemand; }
QString SettingsService::ndiPixelFormat() const    { return m_impl->ndiPixelFormat; }
QString SettingsService::ndiResolution() const     { return m_impl->ndiResolution; }
bool    SettingsService::ndiHideMedia() const      { return m_impl->ndiHideMedia; }
QString SettingsService::defaultScriptureVersion() const { return m_impl->defaultScriptureVersion; }
bool    SettingsService::showVerseNumbers() const  { return m_impl->showVerseNums; }
bool    SettingsService::highlightCurrentVerse() const { return m_impl->highlightVerse; }
bool    SettingsService::showScriptureFooter() const { return m_impl->showScriptureFooter; }
bool    SettingsService::showStrongsTab() const    { return m_impl->showStrongs; }
QString SettingsService::scriptureInputMode() const { return m_impl->scriptureInputMode; }
bool    SettingsService::preloadTranslations() const { return m_impl->preloadTranslations; }
QStringList SettingsService::translationOrder() const   { return m_impl->translationOrder; }
QStringList SettingsService::hiddenTranslations() const { return m_impl->hiddenTranslations; }
bool    SettingsService::showSongAuthor() const    { return m_impl->showSongAuthor; }
bool    SettingsService::showSongCcli() const      { return m_impl->showSongCcli; }
bool    SettingsService::autoAdvance() const             { return m_impl->autoAdvance; }
int     SettingsService::autoAdvanceDelaySeconds() const { return m_impl->autoAdvanceDelay; }
bool    SettingsService::autoAdvanceLoop() const         { return m_impl->autoAdvanceLoop; }
QString SettingsService::mediaDefaultFit() const   { return m_impl->mediaDefaultFit; }
double  SettingsService::mediaVolume() const       { return m_impl->mediaVolume; }
bool    SettingsService::showMatchedLyricSnippet() const   { return m_impl->showMatchedLyricSnippet; }
bool    SettingsService::highlightSongMatches() const      { return m_impl->highlightSongMatches; }
bool    SettingsService::highlightScriptureMatches() const { return m_impl->highlightScriptureMatches; }
bool    SettingsService::highlightStrongsMatches() const   { return m_impl->highlightStrongsMatches; }
QString SettingsService::narrationModelPath() const      { return m_impl->narrationModelPath; }
QString SettingsService::narrationMode() const           { return m_impl->narrationMode; }
int     SettingsService::narrationGraceMs() const        { return m_impl->narrationGraceMs; }
QString SettingsService::narrationInputDeviceId() const  { return m_impl->narrationInputDeviceId; }
QString SettingsService::language() const                { return m_impl->language; }
bool    SettingsService::hasExplicitLanguage() const     { return m_impl->settings.contains(QString::fromLatin1(Impl::kLanguage)); }
QVariantMap SettingsService::globalSearchActions() const { return m_impl->globalSearchActions; }

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

QString SettingsService::uiDensity() const { return m_impl->uiDensity; }

qreal SettingsService::densityScale() const
{
    // Compact trims padding, row heights and bar heights by a fifth. Text
    // size stays with fontSize, so density never makes anything harder to
    // read, only closer together.
    return m_impl->uiDensity == QStringLiteral("comfortable") ? 1.0 : 0.8;
}

void SettingsService::setUiDensity(const QString& density)
{
    if (m_impl->uiDensity == density) return;
    m_impl->uiDensity = density;
    m_impl->put(Impl::kUiDensity, density);
    emit uiDensityChanged();
}

QString SettingsService::previewCardMode() const { return m_impl->previewCardMode; }
QString SettingsService::liveCardMode() const    { return m_impl->liveCardMode; }

void SettingsService::setPreviewCardMode(const QString& mode)
{
    if (m_impl->previewCardMode == mode) return;
    m_impl->previewCardMode = mode;
    m_impl->put(Impl::kPreviewCards, mode);
    emit previewCardModeChanged();
}

void SettingsService::setLiveCardMode(const QString& mode)
{
    if (m_impl->liveCardMode == mode) return;
    m_impl->liveCardMode = mode;
    m_impl->put(Impl::kLiveCards, mode);
    emit liveCardModeChanged();
}

void SettingsService::setThemeMode(const QString& mode)
{
    if (m_impl->themeMode == mode) return;
    m_impl->themeMode = mode;
    m_impl->put(Impl::kThemeMode, mode);
    emit themeModeChanged();
}

void SettingsService::setFontSize(const QString& size)
{
    if (m_impl->fontSize == size) return;
    m_impl->fontSize = size;
    m_impl->put(Impl::kFontSize, size);
    emit fontSizeChanged();
}

void SettingsService::setShowCcli(bool v)
{
    if (m_impl->showCcli == v) return;
    m_impl->showCcli = v;
    m_impl->put(Impl::kShowCcli, v);
    emit showCcliChanged();
}

void SettingsService::setReduceMotion(bool v)
{
    if (m_impl->reduceMotion == v) return;
    m_impl->reduceMotion = v;
    m_impl->put(Impl::kReduceMotion, v);
    emit reduceMotionChanged();
}

void SettingsService::setShowLogoByDefault(bool v)
{
    if (m_impl->showLogoByDef == v) return;
    m_impl->showLogoByDef = v;
    m_impl->put(Impl::kShowLogo, v);
    emit showLogoByDefaultChanged();
}

void SettingsService::setClearScheduleOnClose(bool v)
{
    if (m_impl->clearScheduleOnClose == v) return;
    m_impl->clearScheduleOnClose = v;
    m_impl->put(Impl::kClearScheduleOnClose, v);
    emit clearScheduleOnCloseChanged();
}

void SettingsService::setOutputResolution(const QString& v)
{
    if (m_impl->outputResolution == v) return;
    m_impl->outputResolution = v;
    m_impl->put(Impl::kOutputResolution, v);
    emit outputResolutionChanged();
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
    m_impl->put(Impl::kOutputMode, normalized);
    emit outputModeChanged();
}

void SettingsService::setProjectionInAltTab(bool v)
{
    if (m_impl->projectionInAltTab == v) return;
    m_impl->projectionInAltTab = v;
    m_impl->put(Impl::kProjectionInAltTab, v);
    emit projectionInAltTabChanged();
}

void SettingsService::setProjectionBehindConsole(bool v)
{
    if (m_impl->projectionBehindConsole == v) return;
    m_impl->projectionBehindConsole = v;
    m_impl->put(Impl::kProjectionBehindConsole, v);
    emit projectionBehindConsoleChanged();
}

void SettingsService::setAutoScrollPreview(bool v)
{
    if (m_impl->autoScrollPreview == v) return;
    m_impl->autoScrollPreview = v;
    m_impl->put(Impl::kAutoScrollPreview, v);
    emit autoScrollPreviewChanged();
}

void SettingsService::setAutoScrollLive(bool v)
{
    if (m_impl->autoScrollLive == v) return;
    m_impl->autoScrollLive = v;
    m_impl->put(Impl::kAutoScrollLive, v);
    emit autoScrollLiveChanged();
}

void SettingsService::setAutoScrollLibrary(bool v)
{
    if (m_impl->autoScrollLibrary == v) return;
    m_impl->autoScrollLibrary = v;
    m_impl->put(Impl::kAutoScrollLibrary, v);
    emit autoScrollLibraryChanged();
}

void SettingsService::setLiveControlsOverDialogs(bool v)
{
    if (m_impl->liveControlsOverDialogs == v) return;
    m_impl->liveControlsOverDialogs = v;
    m_impl->put(Impl::kLiveControlsOverDialogs, v);
    emit liveControlsOverDialogsChanged();
}

void SettingsService::setUseHeadlessNdi(bool v)
{
    if (m_impl->useHeadlessNdi == v) return;
    m_impl->useHeadlessNdi = v;
    m_impl->put(Impl::kUseHeadlessNdi, v);
    emit useHeadlessNdiChanged();
}

void SettingsService::setNdiOnDemand(bool v)
{
    if (m_impl->ndiOnDemand == v) return;
    m_impl->ndiOnDemand = v;
    m_impl->put(Impl::kNdiOnDemand, v);
    emit ndiOnDemandChanged();
}

void SettingsService::setNdiPixelFormat(const QString& v)
{
    // Guard against arbitrary writes from QML — anything outside the three
    // known formats collapses to "bgra" so a stray value can't feed an
    // unhandled FourCC into the sender.
    const QString n = v.toLower();
    const QString normalized =
        (n == QStringLiteral("bgrx") || n == QStringLiteral("uyvy")) ? n
                                                                     : QStringLiteral("bgra");
    if (m_impl->ndiPixelFormat == normalized) return;
    m_impl->ndiPixelFormat = normalized;
    m_impl->put(Impl::kNdiPixelFormat, normalized);
    emit ndiPixelFormatChanged();
}

void SettingsService::setNdiResolution(const QString& v)
{
    const QString n = v.toLower();
    const QString normalized =
        (n == QStringLiteral("720p")) ? n : QStringLiteral("native");
    if (m_impl->ndiResolution == normalized) return;
    m_impl->ndiResolution = normalized;
    m_impl->put(Impl::kNdiResolution, normalized);
    emit ndiResolutionChanged();
}

void SettingsService::setNdiHideMedia(bool v)
{
    if (m_impl->ndiHideMedia == v) return;
    m_impl->ndiHideMedia = v;
    m_impl->put(Impl::kNdiHideMedia, v);
    emit ndiHideMediaChanged();
}

void SettingsService::setDefaultScriptureVersion(const QString& code)
{
    if (m_impl->defaultScriptureVersion == code) return;
    m_impl->defaultScriptureVersion = code;
    m_impl->put(Impl::kDefaultScriptureVersion, code);
    emit defaultScriptureVersionChanged();
}

void SettingsService::setShowVerseNumbers(bool v)
{
    if (m_impl->showVerseNums == v) return;
    m_impl->showVerseNums = v;
    m_impl->put(Impl::kShowVerseNums, v);
    emit showVerseNumbersChanged();
}

void SettingsService::setHighlightCurrentVerse(bool v)
{
    if (m_impl->highlightVerse == v) return;
    m_impl->highlightVerse = v;
    m_impl->put(Impl::kHighlightVerse, v);
    emit highlightCurrentVerseChanged();
}

void SettingsService::setShowScriptureFooter(bool v)
{
    if (m_impl->showScriptureFooter == v) return;
    m_impl->showScriptureFooter = v;
    m_impl->put(Impl::kShowScriptureFooter, v);
    emit showScriptureFooterChanged();
}

void SettingsService::setShowStrongsTab(bool v)
{
    if (m_impl->showStrongs == v) return;
    m_impl->showStrongs = v;
    m_impl->put(Impl::kShowStrongs, v);
    emit showStrongsTabChanged();
}

void SettingsService::setScriptureInputMode(const QString& mode)
{
    // Only the two real modes are accepted. Anything else is ignored rather
    // than normalised so a stray QML write can't flip the operator's choice.
    if (mode != QStringLiteral("crater") && mode != QStringLiteral("controlled")) return;
    if (m_impl->scriptureInputMode == mode) return;
    m_impl->scriptureInputMode = mode;
    m_impl->put(Impl::kScriptureInputMode, mode);
    emit scriptureInputModeChanged();
}

void SettingsService::setTranslationOrder(const QStringList& codes)
{
    if (m_impl->translationOrder == codes) return;
    m_impl->translationOrder = codes;
    m_impl->put(Impl::kTranslationOrder, codes);
    emit translationOrderChanged();
}

void SettingsService::setHiddenTranslations(const QStringList& codes)
{
    if (m_impl->hiddenTranslations == codes) return;
    m_impl->hiddenTranslations = codes;
    m_impl->put(Impl::kHiddenTranslations, codes);
    emit hiddenTranslationsChanged();
}

void SettingsService::setPreloadTranslations(bool v)
{
    if (m_impl->preloadTranslations == v) return;
    m_impl->preloadTranslations = v;
    m_impl->put(Impl::kPreloadTranslations, v);
    emit preloadTranslationsChanged();
}

void SettingsService::setShowSongAuthor(bool v)
{
    if (m_impl->showSongAuthor == v) return;
    m_impl->showSongAuthor = v;
    m_impl->put(Impl::kShowSongAuth, v);
    emit showSongAuthorChanged();
}

void SettingsService::setShowSongCcli(bool v)
{
    if (m_impl->showSongCcli == v) return;
    m_impl->showSongCcli = v;
    m_impl->put(Impl::kShowSongCcli, v);
    emit showSongCcliChanged();
}

void SettingsService::setAutoAdvance(bool v)
{
    if (m_impl->autoAdvance == v) return;
    m_impl->autoAdvance = v;
    m_impl->put(Impl::kAutoAdvance, v);
    emit autoAdvanceChanged();
}

void SettingsService::setAutoAdvanceDelaySeconds(int v)
{
    // Clamp to a sane broadcast range: a stray 0 would spin the timer with
    // no gap, and an absurd value would strand the operator on one slide.
    const int clamped = qBound(1, v, 600);
    if (m_impl->autoAdvanceDelay == clamped) return;
    m_impl->autoAdvanceDelay = clamped;
    m_impl->put(Impl::kAutoAdvanceDelay, clamped);
    emit autoAdvanceDelaySecondsChanged();
}

void SettingsService::setNarrationModelPath(const QString& path)
{
    if (m_impl->narrationModelPath == path) return;
    m_impl->narrationModelPath = path;
    m_impl->put(Impl::kNarrationModelPath, path);
    emit narrationModelPathChanged();
}

void SettingsService::setNarrationInputDeviceId(const QString& id)
{
    if (m_impl->narrationInputDeviceId == id) return;
    m_impl->narrationInputDeviceId = id;
    m_impl->put(Impl::kNarrationInputDeviceId, id);
    emit narrationInputDeviceIdChanged();
}

void SettingsService::setNarrationMode(const QString& mode)
{
    // Validated rather than stored blind. The mode is a safety control (it is
    // what decides whether a detection can reach the projector), so an unknown
    // value must not be persisted and must not be interpreted — an accidental
    // "Auto " with a trailing space should stay on the previous mode, not fall
    // through to some default.
    if (mode != QLatin1String("suggest")
        && mode != QLatin1String("stage")
        && mode != QLatin1String("auto"))
        return;
    if (m_impl->narrationMode == mode) return;
    m_impl->narrationMode = mode;
    m_impl->put(Impl::kNarrationMode, mode);
    emit narrationModeChanged();
}

void SettingsService::setNarrationGraceMs(int ms)
{
    // Floor of 500 ms: below that there is no realistic chance for a human to
    // read the pending reference and cancel, which is the entire purpose of
    // the grace period. Ceiling of 10 s keeps Auto feeling automatic.
    const int clamped = qBound(500, ms, 10000);
    if (m_impl->narrationGraceMs == clamped) return;
    m_impl->narrationGraceMs = clamped;
    m_impl->put(Impl::kNarrationGraceMs, clamped);
    emit narrationGraceMsChanged();
}

void SettingsService::setAutoAdvanceLoop(bool v)
{
    if (m_impl->autoAdvanceLoop == v) return;
    m_impl->autoAdvanceLoop = v;
    m_impl->put(Impl::kAutoAdvanceLoop, v);
    emit autoAdvanceLoopChanged();
}

void SettingsService::setMediaDefaultFit(const QString& v)
{
    // Guard against arbitrary writes from QML — only the three real fit tokens
    // are accepted; anything else collapses to "contain" so a stray value can
    // never leave media un-renderable. "default" is intentionally rejected here
    // (this IS the default; a media item pointing at it would loop forever).
    const QString normalized =
        (v == QStringLiteral("cover") || v == QStringLiteral("stretch"))
            ? v : QStringLiteral("contain");
    if (m_impl->mediaDefaultFit == normalized) return;
    m_impl->mediaDefaultFit = normalized;
    m_impl->put(Impl::kMediaDefaultFit, normalized);
    emit mediaDefaultFitChanged();
}

void SettingsService::setMediaVolume(double v)
{
    // Clamp rather than reject: a slider dragged past either end must still
    // land on a valid gain. The fuzzy compare stops a drag that re-emits the
    // same position from rewriting QSettings on every pixel.
    const double clamped = qBound(0.0, v, 1.0);
    if (qFuzzyCompare(1.0 + m_impl->mediaVolume, 1.0 + clamped)) return;
    m_impl->mediaVolume = clamped;
    m_impl->put(Impl::kMediaVolume, clamped);
    emit mediaVolumeChanged();
}

void SettingsService::setShowMatchedLyricSnippet(bool v)
{
    if (m_impl->showMatchedLyricSnippet == v) return;
    m_impl->showMatchedLyricSnippet = v;
    m_impl->put(Impl::kShowMatchedLyricSnippet, v);
    emit showMatchedLyricSnippetChanged();
}

void SettingsService::setHighlightSongMatches(bool v)
{
    if (m_impl->highlightSongMatches == v) return;
    m_impl->highlightSongMatches = v;
    m_impl->put(Impl::kHighlightSongMatches, v);
    emit highlightSongMatchesChanged();
}

void SettingsService::setHighlightScriptureMatches(bool v)
{
    if (m_impl->highlightScriptureMatches == v) return;
    m_impl->highlightScriptureMatches = v;
    m_impl->put(Impl::kHighlightScriptureMatches, v);
    emit highlightScriptureMatchesChanged();
}

void SettingsService::setHighlightStrongsMatches(bool v)
{
    if (m_impl->highlightStrongsMatches == v) return;
    m_impl->highlightStrongsMatches = v;
    m_impl->put(Impl::kHighlightStrongsMatches, v);
    emit highlightStrongsMatchesChanged();
}

void SettingsService::setLanguage(const QString& code)
{
    // Normalize empties to the English source sentinel so "" and "en" don't
    // thrash the persisted value or the change signal. TranslationService is
    // the consumer — it reacts to setLanguage() by swapping the QTranslator and
    // retranslating; this setter only owns persistence + the notify.
    const QString normalized = code.isEmpty() ? QStringLiteral("en") : code;
    if (m_impl->language == normalized) return;
    m_impl->language = normalized;
    m_impl->put(Impl::kLanguage, normalized);
    emit languageChanged();
}

void SettingsService::setGlobalSearchAction(const QString& type, const QString& action)
{
    // Validate both halves — an unknown type or action is dropped rather than
    // persisted, so the map QML reads can only ever hold legal pairs.
    if (!gsTypes().contains(type) || !gsIsAction(action)) return;
    if (m_impl->globalSearchActions.value(type).toString() == action) return;
    m_impl->globalSearchActions.insert(type, action);
    // Persist the whole map as one compact JSON object under a single key.
    const QJsonObject obj = QJsonObject::fromVariantMap(m_impl->globalSearchActions);
    m_impl->put(Impl::kGlobalSearchActions, QString::fromUtf8(QJsonDocument(obj).toJson(QJsonDocument::Compact)));
    emit globalSearchActionsChanged();
}

}  // namespace crater
