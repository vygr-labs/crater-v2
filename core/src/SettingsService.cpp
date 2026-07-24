#include "crater/SettingsService.h"

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
    // Render-pipeline mode — see header. "single" is the lower-cost default
    // (NDI mirrors projection); "dual" enables independent NDI scene + theme.
    QString outputMode       = QStringLiteral("single");
    // Projection window taskbar / Alt-Tab presence — see header. Default true
    // preserves the standard behavior (own taskbar button + switcher slot).
    bool    projectionInAltTab = true;
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
    // KJV is the translation that ships with every install, so it's the safe
    // default. Stored uppercase to match BibleService::translations() codes.
    QString defaultScriptureVersion = QStringLiteral("KJV");
    bool    showVerseNums    = true;
    bool    highlightVerse   = false;
    bool    showScriptureFooter = false;
    bool    showStrongs      = true;
    bool    showSongAuthor   = true;
    bool    showSongCcli     = true;
    // Auto-advance defaults: off, 20 s between slides, no looping.
    bool    autoAdvance      = false;
    int     autoAdvanceDelay = 20;
    bool    autoAdvanceLoop  = false;
    // "contain" (letterbox) is the safe default — it never crops content the
    // operator might not know is being clipped. Cover/stretch are opt-in.
    QString mediaDefaultFit  = QStringLiteral("contain");
    // Library search presentation — all default ON (unchanged out-of-box).
    bool    showMatchedLyricSnippet   = true;
    bool    highlightSongMatches      = true;
    bool    highlightScriptureMatches = true;
    bool    highlightStrongsMatches   = true;
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
    static constexpr const char* kShowCcli       = "Settings/showCcli";
    static constexpr const char* kReduceMotion   = "Settings/reduceMotion";
    static constexpr const char* kShowLogo       = "Settings/showLogoByDefault";
    static constexpr const char* kOutputResolution = "Settings/outputResolution";
    static constexpr const char* kOutputMode       = "Settings/outputMode";
    static constexpr const char* kProjectionInAltTab = "Settings/projectionInAltTab";
    static constexpr const char* kUseHeadlessNdi   = "Settings/useHeadlessNdi";
    static constexpr const char* kNdiOnDemand      = "Settings/ndiOnDemand";
    static constexpr const char* kNdiPixelFormat   = "Settings/ndiPixelFormat";
    static constexpr const char* kNdiResolution    = "Settings/ndiResolution";
    static constexpr const char* kDefaultScriptureVersion = "Settings/defaultScriptureVersion";
    static constexpr const char* kShowVerseNums  = "Settings/showVerseNumbers";
    static constexpr const char* kHighlightVerse = "Settings/highlightCurrentVerse";
    static constexpr const char* kShowScriptureFooter = "Settings/showScriptureFooter";
    static constexpr const char* kShowStrongs    = "Settings/showStrongsTab";
    static constexpr const char* kShowSongAuth   = "Settings/showSongAuthor";
    static constexpr const char* kShowSongCcli   = "Settings/showSongCcli";
    static constexpr const char* kAutoAdvance      = "Settings/autoAdvance";
    static constexpr const char* kAutoAdvanceDelay = "Settings/autoAdvanceDelaySeconds";
    static constexpr const char* kAutoAdvanceLoop  = "Settings/autoAdvanceLoop";
    static constexpr const char* kMediaDefaultFit = "Settings/mediaDefaultFit";
    static constexpr const char* kShowMatchedLyricSnippet   = "Settings/showMatchedLyricSnippet";
    static constexpr const char* kHighlightSongMatches      = "Settings/highlightSongMatches";
    static constexpr const char* kHighlightScriptureMatches = "Settings/highlightScriptureMatches";
    static constexpr const char* kHighlightStrongsMatches   = "Settings/highlightStrongsMatches";
    static constexpr const char* kLanguage         = "Settings/language";
    static constexpr const char* kGlobalSearchActions = "Settings/globalSearchActions";
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
    m_impl->outputMode        = s.value(QString::fromLatin1(Impl::kOutputMode),      m_impl->outputMode).toString();
    m_impl->projectionInAltTab = s.value(QString::fromLatin1(Impl::kProjectionInAltTab), m_impl->projectionInAltTab).toBool();
    m_impl->useHeadlessNdi    = s.value(QString::fromLatin1(Impl::kUseHeadlessNdi),  m_impl->useHeadlessNdi).toBool();
    m_impl->ndiOnDemand       = s.value(QString::fromLatin1(Impl::kNdiOnDemand),     m_impl->ndiOnDemand).toBool();
    m_impl->ndiPixelFormat    = s.value(QString::fromLatin1(Impl::kNdiPixelFormat),  m_impl->ndiPixelFormat).toString();
    m_impl->ndiResolution     = s.value(QString::fromLatin1(Impl::kNdiResolution),   m_impl->ndiResolution).toString();
    m_impl->defaultScriptureVersion = s.value(QString::fromLatin1(Impl::kDefaultScriptureVersion), m_impl->defaultScriptureVersion).toString();
    m_impl->showVerseNums    = s.value(QString::fromLatin1(Impl::kShowVerseNums),    m_impl->showVerseNums).toBool();
    m_impl->highlightVerse   = s.value(QString::fromLatin1(Impl::kHighlightVerse),   m_impl->highlightVerse).toBool();
    m_impl->showScriptureFooter = s.value(QString::fromLatin1(Impl::kShowScriptureFooter), m_impl->showScriptureFooter).toBool();
    m_impl->showStrongs    = s.value(QString::fromLatin1(Impl::kShowStrongs),   m_impl->showStrongs).toBool();
    m_impl->showSongAuthor = s.value(QString::fromLatin1(Impl::kShowSongAuth),  m_impl->showSongAuthor).toBool();
    m_impl->showSongCcli   = s.value(QString::fromLatin1(Impl::kShowSongCcli),  m_impl->showSongCcli).toBool();
    m_impl->autoAdvance      = s.value(QString::fromLatin1(Impl::kAutoAdvance),      m_impl->autoAdvance).toBool();
    m_impl->autoAdvanceDelay = s.value(QString::fromLatin1(Impl::kAutoAdvanceDelay), m_impl->autoAdvanceDelay).toInt();
    m_impl->autoAdvanceLoop  = s.value(QString::fromLatin1(Impl::kAutoAdvanceLoop),  m_impl->autoAdvanceLoop).toBool();
    m_impl->mediaDefaultFit = s.value(QString::fromLatin1(Impl::kMediaDefaultFit), m_impl->mediaDefaultFit).toString();
    m_impl->showMatchedLyricSnippet   = s.value(QString::fromLatin1(Impl::kShowMatchedLyricSnippet),   m_impl->showMatchedLyricSnippet).toBool();
    m_impl->highlightSongMatches      = s.value(QString::fromLatin1(Impl::kHighlightSongMatches),      m_impl->highlightSongMatches).toBool();
    m_impl->highlightScriptureMatches = s.value(QString::fromLatin1(Impl::kHighlightScriptureMatches), m_impl->highlightScriptureMatches).toBool();
    m_impl->highlightStrongsMatches   = s.value(QString::fromLatin1(Impl::kHighlightStrongsMatches),   m_impl->highlightStrongsMatches).toBool();
    m_impl->language         = s.value(QString::fromLatin1(Impl::kLanguage),         m_impl->language).toString();

    // Global-search actions: start from the per-type defaults, then overlay any
    // persisted overrides. Each override is validated so a hand-edited or
    // stale registry value can't seed an unknown type/action into the map.
    m_impl->globalSearchActions = gsDefaults();
    {
        const QString raw = s.value(QString::fromLatin1(Impl::kGlobalSearchActions)).toString();
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
QString SettingsService::outputResolution() const  { return m_impl->outputResolution; }
QString SettingsService::outputMode() const        { return m_impl->outputMode; }
bool    SettingsService::projectionInAltTab() const { return m_impl->projectionInAltTab; }
bool    SettingsService::useHeadlessNdi() const    { return m_impl->useHeadlessNdi; }
bool    SettingsService::ndiOnDemand() const       { return m_impl->ndiOnDemand; }
QString SettingsService::ndiPixelFormat() const    { return m_impl->ndiPixelFormat; }
QString SettingsService::ndiResolution() const     { return m_impl->ndiResolution; }
QString SettingsService::defaultScriptureVersion() const { return m_impl->defaultScriptureVersion; }
bool    SettingsService::showVerseNumbers() const  { return m_impl->showVerseNums; }
bool    SettingsService::highlightCurrentVerse() const { return m_impl->highlightVerse; }
bool    SettingsService::showScriptureFooter() const { return m_impl->showScriptureFooter; }
bool    SettingsService::showStrongsTab() const    { return m_impl->showStrongs; }
bool    SettingsService::showSongAuthor() const    { return m_impl->showSongAuthor; }
bool    SettingsService::showSongCcli() const      { return m_impl->showSongCcli; }
bool    SettingsService::autoAdvance() const             { return m_impl->autoAdvance; }
int     SettingsService::autoAdvanceDelaySeconds() const { return m_impl->autoAdvanceDelay; }
bool    SettingsService::autoAdvanceLoop() const         { return m_impl->autoAdvanceLoop; }
QString SettingsService::mediaDefaultFit() const   { return m_impl->mediaDefaultFit; }
bool    SettingsService::showMatchedLyricSnippet() const   { return m_impl->showMatchedLyricSnippet; }
bool    SettingsService::highlightSongMatches() const      { return m_impl->highlightSongMatches; }
bool    SettingsService::highlightScriptureMatches() const { return m_impl->highlightScriptureMatches; }
bool    SettingsService::highlightStrongsMatches() const   { return m_impl->highlightStrongsMatches; }
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

void SettingsService::setProjectionInAltTab(bool v)
{
    if (m_impl->projectionInAltTab == v) return;
    m_impl->projectionInAltTab = v;
    m_impl->settings.setValue(QString::fromLatin1(Impl::kProjectionInAltTab), v);
    emit projectionInAltTabChanged();
}

void SettingsService::setUseHeadlessNdi(bool v)
{
    if (m_impl->useHeadlessNdi == v) return;
    m_impl->useHeadlessNdi = v;
    m_impl->settings.setValue(QString::fromLatin1(Impl::kUseHeadlessNdi), v);
    emit useHeadlessNdiChanged();
}

void SettingsService::setNdiOnDemand(bool v)
{
    if (m_impl->ndiOnDemand == v) return;
    m_impl->ndiOnDemand = v;
    m_impl->settings.setValue(QString::fromLatin1(Impl::kNdiOnDemand), v);
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
    m_impl->settings.setValue(QString::fromLatin1(Impl::kNdiPixelFormat), normalized);
    emit ndiPixelFormatChanged();
}

void SettingsService::setNdiResolution(const QString& v)
{
    const QString n = v.toLower();
    const QString normalized =
        (n == QStringLiteral("720p")) ? n : QStringLiteral("native");
    if (m_impl->ndiResolution == normalized) return;
    m_impl->ndiResolution = normalized;
    m_impl->settings.setValue(QString::fromLatin1(Impl::kNdiResolution), normalized);
    emit ndiResolutionChanged();
}

void SettingsService::setDefaultScriptureVersion(const QString& code)
{
    if (m_impl->defaultScriptureVersion == code) return;
    m_impl->defaultScriptureVersion = code;
    m_impl->settings.setValue(QString::fromLatin1(Impl::kDefaultScriptureVersion), code);
    emit defaultScriptureVersionChanged();
}

void SettingsService::setShowVerseNumbers(bool v)
{
    if (m_impl->showVerseNums == v) return;
    m_impl->showVerseNums = v;
    m_impl->settings.setValue(QString::fromLatin1(Impl::kShowVerseNums), v);
    emit showVerseNumbersChanged();
}

void SettingsService::setHighlightCurrentVerse(bool v)
{
    if (m_impl->highlightVerse == v) return;
    m_impl->highlightVerse = v;
    m_impl->settings.setValue(QString::fromLatin1(Impl::kHighlightVerse), v);
    emit highlightCurrentVerseChanged();
}

void SettingsService::setShowScriptureFooter(bool v)
{
    if (m_impl->showScriptureFooter == v) return;
    m_impl->showScriptureFooter = v;
    m_impl->settings.setValue(QString::fromLatin1(Impl::kShowScriptureFooter), v);
    emit showScriptureFooterChanged();
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

void SettingsService::setAutoAdvance(bool v)
{
    if (m_impl->autoAdvance == v) return;
    m_impl->autoAdvance = v;
    m_impl->settings.setValue(QString::fromLatin1(Impl::kAutoAdvance), v);
    emit autoAdvanceChanged();
}

void SettingsService::setAutoAdvanceDelaySeconds(int v)
{
    // Clamp to a sane broadcast range: a stray 0 would spin the timer with
    // no gap, and an absurd value would strand the operator on one slide.
    const int clamped = qBound(1, v, 600);
    if (m_impl->autoAdvanceDelay == clamped) return;
    m_impl->autoAdvanceDelay = clamped;
    m_impl->settings.setValue(QString::fromLatin1(Impl::kAutoAdvanceDelay), clamped);
    emit autoAdvanceDelaySecondsChanged();
}

void SettingsService::setAutoAdvanceLoop(bool v)
{
    if (m_impl->autoAdvanceLoop == v) return;
    m_impl->autoAdvanceLoop = v;
    m_impl->settings.setValue(QString::fromLatin1(Impl::kAutoAdvanceLoop), v);
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
    m_impl->settings.setValue(QString::fromLatin1(Impl::kMediaDefaultFit), normalized);
    emit mediaDefaultFitChanged();
}

void SettingsService::setShowMatchedLyricSnippet(bool v)
{
    if (m_impl->showMatchedLyricSnippet == v) return;
    m_impl->showMatchedLyricSnippet = v;
    m_impl->settings.setValue(QString::fromLatin1(Impl::kShowMatchedLyricSnippet), v);
    emit showMatchedLyricSnippetChanged();
}

void SettingsService::setHighlightSongMatches(bool v)
{
    if (m_impl->highlightSongMatches == v) return;
    m_impl->highlightSongMatches = v;
    m_impl->settings.setValue(QString::fromLatin1(Impl::kHighlightSongMatches), v);
    emit highlightSongMatchesChanged();
}

void SettingsService::setHighlightScriptureMatches(bool v)
{
    if (m_impl->highlightScriptureMatches == v) return;
    m_impl->highlightScriptureMatches = v;
    m_impl->settings.setValue(QString::fromLatin1(Impl::kHighlightScriptureMatches), v);
    emit highlightScriptureMatchesChanged();
}

void SettingsService::setHighlightStrongsMatches(bool v)
{
    if (m_impl->highlightStrongsMatches == v) return;
    m_impl->highlightStrongsMatches = v;
    m_impl->settings.setValue(QString::fromLatin1(Impl::kHighlightStrongsMatches), v);
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
    m_impl->settings.setValue(QString::fromLatin1(Impl::kLanguage), normalized);
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
    m_impl->settings.setValue(QString::fromLatin1(Impl::kGlobalSearchActions),
                              QString::fromUtf8(QJsonDocument(obj).toJson(QJsonDocument::Compact)));
    emit globalSearchActionsChanged();
}

}  // namespace crater
