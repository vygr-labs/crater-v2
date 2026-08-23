#include "crater/OutputService.h"
#include "crater/ThemeService.h"
#include "crater/value/Theme.h"

#include <QDebug>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QPointer>
#include <QScreen>
#include <QSettings>
#include <QStringList>
#include <QTimer>

namespace crater {

namespace {

// Whitelist transition style strings — anything outside the three known
// values collapses to "crossfade" so a hand-edited registry or a buggy
// QML write can't put the projection in an undefined render state. Same
// policy as SettingsService used to apply to its three style slots.
QString normalizedTransitionStyle(const QString& style)
{
    if (style == QStringLiteral("cut"))       return QStringLiteral("cut");
    if (style == QStringLiteral("fadeBlack")) return QStringLiteral("fadeBlack");
    return QStringLiteral("crossfade");
}

// Anything beyond ~1.5 s feels like an outage on stage; below 0 is
// nonsense. Clamp so persisted values stay sane regardless of where
// they came from.
int clampedTransitionMs(int ms)
{
    if (ms < 0)    return 0;
    if (ms > 1500) return 1500;
    return ms;
}

// Content mode decides which scene a window mounts, so an unrecognised
// value must not be allowed through: a physical display rendering neither
// the audience view nor the presenter view is a black screen the operator
// has no way to diagnose. Anything unknown collapses to the audience
// render, which is the mode every output had before stage mode existed.
QString normalizedContentMode(const QString& mode)
{
    if (mode == QStringLiteral("stage")) return QStringLiteral("stage");
    return QStringLiteral("mirror");
}

// The mode a freshly-seeded or newly-registered output starts in. Derived
// from role rather than stored as a second default, so "register a stage
// output" cannot produce a stage output that mirrors.
QString contentModeForRole(const QString& role)
{
    if (role == QStringLiteral("stage")) return QStringLiteral("stage");
    return QStringLiteral("mirror");
}

// Built-in seeds. The three slugs match the values QML scenes pass as
// outputKind today, so existing consumers find a binding the moment they
// look one up. displayName mirrors what the Themes tab + Projection
// settings already show; future operator-facing rename UI writes through
// to OutputBinding.displayName directly.
QList<OutputBinding> defaultBuiltins()
{
    OutputBinding primary;
    primary.id          = QStringLiteral("primary");
    primary.displayName = QStringLiteral("Primary Output");
    primary.role        = QStringLiteral("projection");

    OutputBinding ndi;
    ndi.id          = QStringLiteral("ndi");
    ndi.displayName = QStringLiteral("NDI Broadcast");
    ndi.role        = QStringLiteral("ndi");

    OutputBinding stage;
    stage.id          = QStringLiteral("stage");
    stage.displayName = QStringLiteral("Stage Monitor");
    stage.role        = QStringLiteral("stage");
    stage.contentMode = QStringLiteral("stage");
    // Ships off. A stage monitor that turned itself on at first launch
    // would seize a display nobody has told us about yet, and on a
    // two-screen desk that display is the audience projector. The operator
    // enables it in Settings > Projection, which is also where they pick
    // the screen it lands on.
    stage.enabled     = false;

    return { primary, ndi, stage };
}

QString themesToJson(const OutputThemeSlots& s)
{
    QJsonObject o;
    o.insert(QStringLiteral("song"),         s.song);
    o.insert(QStringLiteral("scripture"),    s.scripture);
    o.insert(QStringLiteral("presentation"), s.presentation);
    return QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact));
}

OutputThemeSlots themesFromJson(const QString& text)
{
    OutputThemeSlots s;
    if (text.isEmpty()) return s;
    const auto doc = QJsonDocument::fromJson(text.toUtf8());
    if (!doc.isObject()) return s;
    const auto o = doc.object();
    s.song         = o.value(QStringLiteral("song"))        .toInt(0);
    s.scripture    = o.value(QStringLiteral("scripture"))   .toInt(0);
    s.presentation = o.value(QStringLiteral("presentation")).toInt(0);
    return s;
}

// Bucket a theme id into the matching kind slot of an OutputThemeSlots,
// based on Theme.kind. Anything unrecognised goes into "song" (the most
// common kind, and the legacy single-pin behaviour was "use this theme
// regardless of kind" — picking song is the closest single-slot equivalent).
void assignByKind(OutputThemeSlots& s, const QString& kind, int themeId)
{
    if (kind == QStringLiteral("scripture"))    { s.scripture    = themeId; return; }
    if (kind == QStringLiteral("presentation")) { s.presentation = themeId; return; }
    s.song = themeId;
}

}  // namespace

struct OutputService::Impl
{
    QList<Screen>                  screens;
    int                            selectedIndex   = 0;
    // What the operator actually asked for, kept apart from the
    // index in use. selectedIndex has to collapse to something
    // valid the instant a display disappears; these two do not,
    // and they are what a replug is resolved against.
    int                            desiredIndex    = -1;
    QString                        desiredName;
    bool                           projectionOpen  = false;
    OutputService::ProjectionMode  mode            = OutputService::Fullscreen;
    bool                           modeIsUserSet   = false;
    QSettings                      settings{QStringLiteral("Voyager Labs"), QStringLiteral("Crater")};

    QList<OutputBinding>           outputs;
    QPointer<ThemeService>         themeService;
    bool                           legacyMigrationDone = false;

    static constexpr const char* kSettingKey = "Output/selectedScreen";
    // Name as well as index: a projector that comes back on a different
    // port lands at a different index, and the name is what identifies
    // it across the unplug.
    static constexpr const char* kNameKey    = "Output/selectedScreenName";
    static constexpr const char* kModeKey    = "Output/projectionMode";

    // Registry storage prefix. Each output gets a sub-group keyed by id.
    // Master list of ids lives at "Outputs/ids" so we can walk them on
    // load without scanning the registry.
    static constexpr const char* kIdsKey     = "Outputs/ids";
    static QString prefix(const QString& id) { return QStringLiteral("Outputs/") + id + QChar('/'); }

    // Legacy keys we migrate from SettingsService. Kept here (not in
    // SettingsService) because the migration owner is the new home for
    // the data — SettingsService no longer knows these existed.
    static constexpr const char* kLegacyThemePrimary  = "Settings/themeIdForPrimary";
    static constexpr const char* kLegacyThemeNdi      = "Settings/themeIdForNdi";
    static constexpr const char* kLegacyThemeStage    = "Settings/themeIdForStage";
    static constexpr const char* kLegacyStylePrimary  = "Settings/transitionStyleForPrimary";
    static constexpr const char* kLegacyStyleNdi      = "Settings/transitionStyleForNdi";
    static constexpr const char* kLegacyStyleStage    = "Settings/transitionStyleForStage";
    static constexpr const char* kLegacyMsPrimary     = "Settings/transitionDurationMsForPrimary";
    static constexpr const char* kLegacyMsNdi         = "Settings/transitionDurationMsForNdi";
    static constexpr const char* kLegacyMsStage       = "Settings/transitionDurationMsForStage";
};

OutputService::OutputService(QObject* parent)
    : QObject(parent)
    , m_impl(std::make_unique<Impl>())
{
    // Load persisted mode BEFORE rebuildScreens() so its hot-plug recompute
    // respects modeIsUserSet from the very first call. Without this, the
    // default would briefly overwrite the user's saved preference.
    if (m_impl->settings.contains(QString::fromLatin1(Impl::kModeKey))) {
        m_impl->mode = static_cast<ProjectionMode>(
            m_impl->settings.value(QString::fromLatin1(Impl::kModeKey)).toInt());
        m_impl->modeIsUserSet = true;
    }

    // Load the stored display preference BEFORE rebuildScreens(), which
    // resolves it against whatever is plugged in at this moment. Doing it
    // the other way round makes the first resolve run blind and then get
    // overwritten, which is how the old code ended up with two different
    // notions of the selected screen.
    m_impl->desiredIndex =
        m_impl->settings.value(QString::fromLatin1(Impl::kSettingKey), -1).toInt();
    m_impl->desiredName =
        m_impl->settings.value(QString::fromLatin1(Impl::kNameKey)).toString();

    rebuildScreens();

    if (m_impl->desiredIndex < 0 && m_impl->desiredName.isEmpty()) {
        // Fresh install, nothing stored. Prefer a non-primary monitor — the
        // projector — over the operator's own panel, then adopt that as the
        // remembered choice so an unplug/replug later resolves back to it
        // instead of stranding the audience output on the console's screen.
        for (int i = 0; i < m_impl->screens.size(); ++i) {
            if (!m_impl->screens[i].isPrimary) { m_impl->selectedIndex = i; break; }
        }
        m_impl->desiredIndex = m_impl->selectedIndex;
        if (m_impl->selectedIndex < m_impl->screens.size()) {
            m_impl->desiredName = m_impl->screens[m_impl->selectedIndex].name;
        }
    }

    // React to monitor hot-plug. Use lambdas (not SIGNAL/SLOT macros) because
    // rebuildScreens is a private method, not a Q_SLOT.
    auto* app = qGuiApp;
    if (app) {
        connect(app, &QGuiApplication::screenAdded,
                this, [this](QScreen*) { rebuildScreens(); });
        connect(app, &QGuiApplication::screenRemoved,
                this, [this](QScreen*) { rebuildScreens(); });
        connect(app, &QGuiApplication::primaryScreenChanged,
                this, [this](QScreen*) { rebuildScreens(); });
    }

    // Registry: seed built-ins if this is a fresh install, then load
    // persisted bindings. Legacy migration is deferred until
    // attachThemeService() supplies the kind-resolution oracle — without
    // it we'd guess "song" for every legacy theme pin, which the explicit
    // attach path avoids.
    seedBuiltinsIfMissing();
    loadOutputsFromSettings();
}

OutputService::~OutputService() = default;

void OutputService::attachThemeService(ThemeService* svc)
{
    if (!m_impl) return;
    m_impl->themeService = svc;
    // Run the migration on the next event-loop tick so the caller doesn't
    // need to think about service-construction order. Idempotent — second
    // calls are a no-op via legacyMigrationDone.
    QTimer::singleShot(0, this, [this] { runLegacyMigration(); });
}

QList<Screen> OutputService::screens() const
{
    return m_impl ? m_impl->screens : QList<Screen>{};
}

int OutputService::selectedScreenIndex() const
{
    return m_impl ? m_impl->selectedIndex : 0;
}

bool OutputService::projectionOpen() const
{
    return m_impl && m_impl->projectionOpen;
}

OutputService::ProjectionMode OutputService::projectionMode() const
{
    return m_impl ? m_impl->mode : Fullscreen;
}

QList<OutputBinding> OutputService::outputs() const
{
    return m_impl ? m_impl->outputs : QList<OutputBinding>{};
}

void OutputService::setSelectedScreenIndex(int index)
{
    if (!m_impl) return;
    if (index < 0 || index >= m_impl->screens.size()) return;
    // Record the choice even when it matches the index already in use —
    // after an unplug forced a fallback, re-picking the same display is
    // how the operator says "this one, remember it".
    m_impl->desiredIndex = index;
    m_impl->desiredName  = m_impl->screens[index].name;
    m_impl->settings.setValue(QString::fromLatin1(Impl::kSettingKey), index);
    m_impl->settings.setValue(QString::fromLatin1(Impl::kNameKey),
                              m_impl->desiredName);
    if (m_impl->selectedIndex == index) return;
    m_impl->selectedIndex = index;
    emit selectedScreenIndexChanged();
}

void OutputService::setProjectionMode(ProjectionMode mode)
{
    if (!m_impl) return;
    const bool firstSet = !m_impl->modeIsUserSet;
    m_impl->modeIsUserSet = true;
    if (firstSet) {
        m_impl->settings.setValue(QString::fromLatin1(Impl::kModeKey),
                                  static_cast<int>(mode));
    }
    if (m_impl->mode == mode) return;
    m_impl->mode = mode;
    m_impl->settings.setValue(QString::fromLatin1(Impl::kModeKey),
                              static_cast<int>(mode));
    emit projectionModeChanged();
}

OutputService::ProjectionMode OutputService::computeDefaultMode() const
{
    if (!m_impl) return Fullscreen;
    for (const auto& s : m_impl->screens) {
        if (!s.isPrimary) return Fullscreen;
    }
    return Windowed;
}

void OutputService::openProjection()
{
    if (!m_impl) return;
    emit projectionWindowRequested(m_impl->selectedIndex);
}

void OutputService::closeProjection()
{
    emit projectionWindowDismissed();
}

void OutputService::notifyProjectionOpened()
{
    if (!m_impl || m_impl->projectionOpen) return;
    m_impl->projectionOpen = true;
    emit projectionOpenChanged();
}

void OutputService::notifyProjectionClosed()
{
    if (!m_impl || !m_impl->projectionOpen) return;
    m_impl->projectionOpen = false;
    emit projectionOpenChanged();
}

namespace {

// Map the operator's stored preference onto the displays that exist right
// now. Name first, because that survives a cable coming out and going back
// into a different port; then the index, which covers a fresh install that
// never named anything; then the old blind clamp as a last resort.
int resolveScreenIndex(const QList<crater::Screen>& screens,
                       const QString& desiredName,
                       int desiredIndex)
{
    if (screens.isEmpty()) return 0;
    if (!desiredName.isEmpty()) {
        for (int i = 0; i < screens.size(); ++i) {
            if (screens[i].name == desiredName) return i;
        }
    }
    if (desiredIndex >= 0 && desiredIndex < screens.size()) return desiredIndex;
    return qMax(0, screens.size() - 1);
}

// Extra outputs resolve strictly: the remembered name first, then the
// stored index while it is still in range, otherwise -1 (unassigned).
//
// The difference from resolveScreenIndex above is the missing fallback,
// and it is deliberate. The audience output must always land somewhere --
// a service with no projection is worse than a projection on the wrong
// screen. A stage monitor or overflow display is the opposite: if its
// screen is unplugged the only safe answer is "nowhere". Clamping it the
// way primary clamps would walk a confidence monitor onto the operator
// console mid-service, covering the controls with a window whose whole
// purpose is to be looked at by somebody else.
//
// screenName is left intact when this returns -1, so plugging the display
// back in re-resolves by name and the output returns to it on its own.
int resolveStrictScreenIndex(const QList<crater::Screen>& screens,
                             const QString& desiredName,
                             int desiredIndex)
{
    if (screens.isEmpty()) return -1;
    if (!desiredName.isEmpty()) {
        for (int i = 0; i < screens.size(); ++i) {
            if (screens[i].name == desiredName) return i;
        }
        // A recorded name that no longer matches anything means the chosen
        // display is genuinely gone. Don't fall through to the index -- on
        // a machine that just lost a monitor, the old index now points at a
        // DIFFERENT display.
        return -1;
    }
    if (desiredIndex >= 0 && desiredIndex < screens.size()) return desiredIndex;
    return -1;
}

}  // namespace

void OutputService::rebuildScreens()
{
    if (!m_impl) return;

    QList<Screen> list;
    const auto* primary = QGuiApplication::primaryScreen();
    for (auto* s : QGuiApplication::screens()) {
        Screen v;
        v.name             = s->name();
        v.geometry         = s->geometry();
        v.isPrimary        = (s == primary);
        v.devicePixelRatio = s->devicePixelRatio();
        list.append(std::move(v));
    }
    m_impl->screens = std::move(list);

    // Re-resolve on EVERY rebuild, not just when the current index has
    // gone out of range. The old one-way clamp meant an unplug rewrote
    // selectedIndex to 0 and a replug left it there: the audience output
    // came back on the operator's own panel, and because two screens
    // existed again it also regained WindowStaysOnTopHint and fullscreen
    // — an always-on-top window burying the console mid-service, which
    // is the exact failure the single-screen demotion was added to stop.
    const int resolved = resolveScreenIndex(m_impl->screens,
                                            m_impl->desiredName,
                                            m_impl->desiredIndex);
    if (resolved != m_impl->selectedIndex) {
        m_impl->selectedIndex = resolved;
        emit selectedScreenIndexChanged();
    }

    // Same replug recovery for every other output.
    const bool outputsMoved = resolveOutputScreens();

    if (!m_impl->modeIsUserSet) {
        const auto newMode = computeDefaultMode();
        if (newMode != m_impl->mode) {
            m_impl->mode = newMode;
            emit projectionModeChanged();
        }
    }

    emit screensChanged();
    // Emitted after screensChanged, so a QML handler reacting to the new
    // screen list already sees re-resolved placements rather than bindings
    // still pointing at displays that no longer exist.
    if (outputsMoved) emit outputsChanged();
}

// ── Registry helpers ────────────────────────────────────────────────────

// Skipped for "primary" (handled by the global selection it aliases) and for
// outputs that were never assigned a display, which must stay unassigned
// rather than adopt whatever sits at index 0.
bool OutputService::resolveOutputScreens()
{
    if (!m_impl) return false;
    bool moved = false;
    for (auto& b : m_impl->outputs) {
        if (b.id == QStringLiteral("primary")) continue;
        if (b.screenIndex < 0 && b.screenName.isEmpty()) continue;
        const int idx = resolveStrictScreenIndex(m_impl->screens,
                                                 b.screenName, b.screenIndex);
        if (idx == b.screenIndex) continue;
        b.screenIndex = idx;
        persistOutput(b);
        moved = true;
    }
    return moved;
}

void OutputService::seedBuiltinsIfMissing()
{
    if (!m_impl) return;
    auto& s = m_impl->settings;
    const QStringList ids = s.value(QString::fromLatin1(Impl::kIdsKey)).toStringList();
    if (!ids.isEmpty()) return;  // already seeded — respect whatever's on disk

    for (const auto& b : defaultBuiltins()) {
        persistOutput(b);
    }
    QStringList seeded;
    for (const auto& b : defaultBuiltins()) seeded.append(b.id);
    s.setValue(QString::fromLatin1(Impl::kIdsKey), seeded);
}

void OutputService::loadOutputsFromSettings()
{
    if (!m_impl) return;
    auto& s = m_impl->settings;
    QStringList ids = s.value(QString::fromLatin1(Impl::kIdsKey)).toStringList();

    // Defensive: if the on-disk list is missing any built-in (e.g. an
    // earlier crash mid-seed), reseed the missing ones so QML lookups
    // for the three legacy slugs always succeed.
    const auto builtins = defaultBuiltins();
    for (const auto& b : builtins) {
        if (!ids.contains(b.id)) {
            persistOutput(b);
            ids.append(b.id);
        }
    }
    s.setValue(QString::fromLatin1(Impl::kIdsKey), ids);

    QList<OutputBinding> loaded;
    for (const QString& id : ids) {
        const QString p = Impl::prefix(id);
        OutputBinding b;
        b.id                   = id;
        b.displayName          = s.value(p + QStringLiteral("displayName"), id).toString();
        b.role                 = s.value(p + QStringLiteral("role"),
                                         QStringLiteral("projection")).toString();
        b.themes               = themesFromJson(s.value(p + QStringLiteral("themes")).toString());
        b.transitionStyle      = normalizedTransitionStyle(
            s.value(p + QStringLiteral("transitionStyle"),
                    QStringLiteral("crossfade")).toString());
        b.transitionDurationMs = clampedTransitionMs(
            s.value(p + QStringLiteral("transitionDurationMs"), 280).toInt());
        b.enabled              = s.value(p + QStringLiteral("enabled"), false).toBool();
        b.screenIndex          = s.value(p + QStringLiteral("screenIndex"), -1).toInt();
        b.screenName           = s.value(p + QStringLiteral("screenName")).toString();
        // Default derived from role, not hardcoded to "mirror": an install
        // that predates multi-display has a persisted "stage" output with no
        // contentMode key, and reading that as a mirror would turn the newly
        // wired Stage Monitor into a second audience screen.
        b.contentMode          = normalizedContentMode(
            s.value(p + QStringLiteral("contentMode"),
                    contentModeForRole(b.role)).toString());
        loaded.append(std::move(b));
    }
    m_impl->outputs = std::move(loaded);

    // Resolve placements against the displays actually attached right now.
    // The constructor calls rebuildScreens() BEFORE this function -- it has
    // to, because the screen list is what a placement resolves against --
    // so that pass ran over an empty registry and this is the first chance
    // to check a stored screenIndex. Without it, a stage monitor whose
    // display came back on a different port would sit on the wrong screen
    // for the whole session, until some later hot-plug happened to fix it.
    resolveOutputScreens();
    emit outputsChanged();
}

void OutputService::persistOutput(const OutputBinding& b)
{
    if (!m_impl) return;
    auto& s = m_impl->settings;
    const QString p = Impl::prefix(b.id);
    s.setValue(p + QStringLiteral("displayName"),          b.displayName);
    s.setValue(p + QStringLiteral("role"),                 b.role);
    s.setValue(p + QStringLiteral("themes"),               themesToJson(b.themes));
    s.setValue(p + QStringLiteral("transitionStyle"),      b.transitionStyle);
    s.setValue(p + QStringLiteral("transitionDurationMs"), b.transitionDurationMs);
    s.setValue(p + QStringLiteral("enabled"),              b.enabled);
    s.setValue(p + QStringLiteral("screenIndex"),          b.screenIndex);
    s.setValue(p + QStringLiteral("screenName"),           b.screenName);
    s.setValue(p + QStringLiteral("contentMode"),          b.contentMode);
}

void OutputService::runLegacyMigration()
{
    if (!m_impl || m_impl->legacyMigrationDone) return;
    m_impl->legacyMigrationDone = true;

    auto& s = m_impl->settings;
    auto* themes = m_impl->themeService.data();

    // Each legacy theme pin: look up the theme's kind via ThemeService,
    // write into the matching output's matching kind slot, delete the
    // legacy key. Done individually so a partial migration (e.g. only
    // NDI had been pinned) doesn't churn unrelated outputs.
    auto migrateThemePin = [&](const char* legacyKey, const QString& outputId) {
        if (!s.contains(QString::fromLatin1(legacyKey))) return;
        const int legacyId = s.value(QString::fromLatin1(legacyKey)).toInt();
        s.remove(QString::fromLatin1(legacyKey));
        if (legacyId <= 0) return;

        QString kind = QStringLiteral("song");  // assignByKind's fallback
        if (themes) {
            const auto t = themes->theme(legacyId);
            if (!t.kind.isEmpty()) kind = t.kind;
        }
        const int idx = [&] {
            for (int i = 0; i < m_impl->outputs.size(); ++i)
                if (m_impl->outputs[i].id == outputId) return i;
            return -1;
        }();
        if (idx < 0) return;
        assignByKind(m_impl->outputs[idx].themes, kind, legacyId);
        persistOutput(m_impl->outputs[idx]);
    };

    migrateThemePin(Impl::kLegacyThemePrimary, QStringLiteral("primary"));
    migrateThemePin(Impl::kLegacyThemeNdi,     QStringLiteral("ndi"));
    migrateThemePin(Impl::kLegacyThemeStage,   QStringLiteral("stage"));

    // Transition style + duration: copy verbatim, delete legacy key.
    auto migrateTransition = [&](const char* styleKey, const char* msKey,
                                 const QString& outputId) {
        const bool hasStyle = s.contains(QString::fromLatin1(styleKey));
        const bool hasMs    = s.contains(QString::fromLatin1(msKey));
        if (!hasStyle && !hasMs) return;

        const int idx = [&] {
            for (int i = 0; i < m_impl->outputs.size(); ++i)
                if (m_impl->outputs[i].id == outputId) return i;
            return -1;
        }();
        if (idx < 0) {
            // Clean up legacy keys anyway so we don't keep retrying.
            s.remove(QString::fromLatin1(styleKey));
            s.remove(QString::fromLatin1(msKey));
            return;
        }
        if (hasStyle) {
            m_impl->outputs[idx].transitionStyle = normalizedTransitionStyle(
                s.value(QString::fromLatin1(styleKey)).toString());
            s.remove(QString::fromLatin1(styleKey));
        }
        if (hasMs) {
            m_impl->outputs[idx].transitionDurationMs = clampedTransitionMs(
                s.value(QString::fromLatin1(msKey)).toInt());
            s.remove(QString::fromLatin1(msKey));
        }
        persistOutput(m_impl->outputs[idx]);
    };

    migrateTransition(Impl::kLegacyStylePrimary, Impl::kLegacyMsPrimary,
                      QStringLiteral("primary"));
    migrateTransition(Impl::kLegacyStyleNdi,     Impl::kLegacyMsNdi,
                      QStringLiteral("ndi"));
    migrateTransition(Impl::kLegacyStyleStage,   Impl::kLegacyMsStage,
                      QStringLiteral("stage"));

    emit outputsChanged();
}

// ── Registry public API ─────────────────────────────────────────────────

OutputBinding OutputService::output(const QString& id) const
{
    if (!m_impl) return {};
    for (const auto& b : m_impl->outputs) {
        if (b.id == id) return b;
    }
    return {};
}

int OutputService::themeIdFor(const QString& outputId, const QString& kind) const
{
    if (!m_impl) return 0;
    for (const auto& b : m_impl->outputs) {
        if (b.id != outputId) continue;
        if (kind == QStringLiteral("scripture"))    return b.themes.scripture;
        if (kind == QStringLiteral("presentation")) return b.themes.presentation;
        if (kind == QStringLiteral("song"))         return b.themes.song;
        return 0;
    }
    return 0;
}

void OutputService::setThemeIdFor(const QString& outputId, const QString& kind, int themeId)
{
    if (!m_impl) return;
    for (auto& b : m_impl->outputs) {
        if (b.id != outputId) continue;
        const auto before = b.themes;
        if      (kind == QStringLiteral("scripture"))    b.themes.scripture    = themeId;
        else if (kind == QStringLiteral("presentation")) b.themes.presentation = themeId;
        else if (kind == QStringLiteral("song"))         b.themes.song         = themeId;
        else return;
        if (b.themes == before) return;
        persistOutput(b);
        emit outputsChanged();
        return;
    }
}

QString OutputService::transitionStyle(const QString& outputId) const
{
    if (!m_impl) return QStringLiteral("crossfade");
    for (const auto& b : m_impl->outputs) {
        if (b.id == outputId) return b.transitionStyle;
    }
    return QStringLiteral("crossfade");
}

void OutputService::setTransitionStyle(const QString& outputId, const QString& style)
{
    if (!m_impl) return;
    const QString s = normalizedTransitionStyle(style);
    for (auto& b : m_impl->outputs) {
        if (b.id != outputId) continue;
        if (b.transitionStyle == s) return;
        b.transitionStyle = s;
        persistOutput(b);
        emit outputsChanged();
        return;
    }
}

int OutputService::transitionDurationMs(const QString& outputId) const
{
    if (!m_impl) return 280;
    for (const auto& b : m_impl->outputs) {
        if (b.id == outputId) return b.transitionDurationMs;
    }
    return 280;
}

void OutputService::setTransitionDurationMs(const QString& outputId, int ms)
{
    if (!m_impl) return;
    const int v = clampedTransitionMs(ms);
    for (auto& b : m_impl->outputs) {
        if (b.id != outputId) continue;
        if (b.transitionDurationMs == v) return;
        b.transitionDurationMs = v;
        persistOutput(b);
        emit outputsChanged();
        return;
    }
}

// ── Multi-display placement ─────────────────────────────────────────────

bool OutputService::outputEnabled(const QString& outputId) const
{
    // "primary" reports enabled unconditionally. Its window always exists;
    // whether the audience is SEEING it is AppState.projectorVisible, a live
    // gesture rather than a stored preference. Reporting the raw (always
    // false) flag here would make every "does this output have a window"
    // caller -- screenIsContested included -- skip the audience output,
    // which is precisely the one that matters.
    if (outputId == QStringLiteral("primary")) return true;
    if (!m_impl) return false;
    for (const auto& b : m_impl->outputs) {
        if (b.id == outputId) return b.enabled;
    }
    return false;
}

void OutputService::setOutputEnabled(const QString& outputId, bool enabled)
{
    if (!m_impl) return;
    // primary and ndi own their own lifecycles (projectorVisible and
    // NdiService.sending respectively). Accepting a write here would store
    // a flag nothing reads, which is worse than refusing it -- the operator
    // would see a switch that appears to do something and does not.
    if (outputId == QStringLiteral("primary")) return;
    if (outputId == QStringLiteral("ndi"))     return;
    for (auto& b : m_impl->outputs) {
        if (b.id != outputId) continue;
        if (b.enabled == enabled) return;
        b.enabled = enabled;
        persistOutput(b);
        emit outputsChanged();
        return;
    }
}

int OutputService::screenIndexFor(const QString& outputId) const
{
    if (!m_impl) return -1;
    // Aliased onto the global selection rather than copied -- see the
    // header. Keeps one answer to "which display is the audience on",
    // shared with the Projection settings picker and the replug recovery.
    if (outputId == QStringLiteral("primary")) return m_impl->selectedIndex;
    for (const auto& b : m_impl->outputs) {
        if (b.id == outputId) return b.screenIndex;
    }
    return -1;
}

void OutputService::setScreenIndexFor(const QString& outputId, int index)
{
    if (!m_impl) return;
    if (outputId == QStringLiteral("primary")) {
        setSelectedScreenIndex(index);
        return;
    }
    // -1 is a legal write: it means "unassign", and the settings UI offers
    // it so an operator can park an output for a week without deleting it
    // and losing its theme pins and transition tuning.
    if (index < -1 || index >= m_impl->screens.size()) return;
    for (auto& b : m_impl->outputs) {
        if (b.id != outputId) continue;
        const QString name = (index >= 0) ? m_impl->screens[index].name : QString();
        if (b.screenIndex == index && b.screenName == name) return;
        b.screenIndex = index;
        // Record the name alongside the index so a replug onto a different
        // port still finds this display. Cleared on unassign, so a stale
        // name cannot resurrect the output on the next hot-plug rebuild.
        b.screenName  = name;
        persistOutput(b);
        emit outputsChanged();
        return;
    }
}

QString OutputService::contentMode(const QString& outputId) const
{
    if (!m_impl) return QStringLiteral("mirror");
    for (const auto& b : m_impl->outputs) {
        if (b.id == outputId) return b.contentMode;
    }
    return QStringLiteral("mirror");
}

void OutputService::setContentMode(const QString& outputId, const QString& mode)
{
    if (!m_impl) return;
    const QString m = normalizedContentMode(mode);
    for (auto& b : m_impl->outputs) {
        if (b.id != outputId) continue;
        if (b.contentMode == m) return;
        b.contentMode = m;
        persistOutput(b);
        emit outputsChanged();
        return;
    }
}

void OutputService::setDisplayName(const QString& outputId, const QString& name)
{
    if (!m_impl) return;
    const QString trimmed = name.trimmed();
    // An empty rename is dropped rather than stored. A row labelled with
    // nothing is unusable in the output picker, and the operator has no
    // obvious way back from it.
    if (trimmed.isEmpty()) return;
    for (auto& b : m_impl->outputs) {
        if (b.id != outputId) continue;
        if (b.displayName == trimmed) return;
        b.displayName = trimmed;
        persistOutput(b);
        emit outputsChanged();
        return;
    }
}

bool OutputService::screenIsContested(const QString& outputId, int index) const
{
    if (!m_impl || index < 0) return false;
    for (const auto& b : m_impl->outputs) {
        if (b.id == outputId) continue;
        // NDI renders to a network stream, not a display, so it can never
        // contend for a physical screen no matter what index it carries.
        if (b.role == QStringLiteral("ndi")) continue;
        if (!outputEnabled(b.id)) continue;
        if (screenIndexFor(b.id) == index) return true;
    }
    return false;
}

QString OutputService::registerOutput(const QString& role, const QString& displayName)
{
    if (!m_impl) return {};
    // Auto-slug: "<role>-<n>" where n is the lowest integer that yields
    // a unique id. Built-in slugs ("primary","ndi","stage") aren't reused
    // — first dynamic projection becomes "projection-2", etc.
    auto exists = [this](const QString& id) {
        for (const auto& b : m_impl->outputs) if (b.id == id) return true;
        return false;
    };
    QString id;
    for (int n = 2; n < 1000; ++n) {
        id = role + QChar('-') + QString::number(n);
        if (!exists(id)) break;
    }

    OutputBinding b;
    b.id          = id;
    b.displayName = displayName.isEmpty() ? id : displayName;
    b.role        = role;
    b.contentMode = contentModeForRole(role);
    // On by default: the operator just asked for this output to exist, so
    // making them flip a second switch to see it is friction. It still has
    // no screen (screenIndex -1) until they pick one, so enabling it here
    // cannot put a window anywhere unexpected.
    b.enabled     = true;

    m_impl->outputs.append(b);
    persistOutput(b);

    QStringList ids;
    for (const auto& x : m_impl->outputs) ids.append(x.id);
    m_impl->settings.setValue(QString::fromLatin1(Impl::kIdsKey), ids);
    emit outputsChanged();
    return id;
}

void OutputService::unregisterOutput(const QString& id)
{
    if (!m_impl) return;
    // Built-ins are protected — UI shouldn't offer this in the first
    // place, but a buggy QML write shouldn't be able to make Primary /
    // NDI / Stage disappear.
    if (id == QStringLiteral("primary") || id == QStringLiteral("ndi")
        || id == QStringLiteral("stage")) {
        return;
    }
    for (int i = 0; i < m_impl->outputs.size(); ++i) {
        if (m_impl->outputs[i].id != id) continue;
        m_impl->outputs.removeAt(i);
        m_impl->settings.remove(QStringLiteral("Outputs/") + id);
        QStringList ids;
        for (const auto& x : m_impl->outputs) ids.append(x.id);
        m_impl->settings.setValue(QString::fromLatin1(Impl::kIdsKey), ids);
        emit outputsChanged();
        return;
    }
}

}  // namespace crater
