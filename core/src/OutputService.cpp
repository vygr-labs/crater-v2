#include "crater/OutputService.h"

#include <QDebug>
#include <QGuiApplication>
#include <QScreen>
#include <QSettings>

namespace crater {

struct OutputService::Impl
{
    QList<Screen>                  screens;
    int                            selectedIndex   = 0;
    bool                           projectionOpen  = false;
    OutputService::ProjectionMode  mode            = OutputService::Fullscreen;
    // Sticky: once the user explicitly picks a mode, hot-plug events must
    // not silently overwrite it. Set true by setProjectionMode(); also
    // initialised true at construction if a persisted value exists.
    bool                           modeIsUserSet   = false;
    QSettings                      settings{QStringLiteral("Voyager Labs"), QStringLiteral("Crater")};

    static constexpr const char* kSettingKey = "Output/selectedScreen";
    static constexpr const char* kModeKey    = "Output/projectionMode";
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

    rebuildScreens();

    m_impl->selectedIndex =
        m_impl->settings.value(QString::fromLatin1(Impl::kSettingKey), 0).toInt();

    if (m_impl->selectedIndex < 0 || m_impl->selectedIndex >= m_impl->screens.size()) {
        // Prefer a non-primary monitor if available; else stay at 0.
        m_impl->selectedIndex = 0;
        for (int i = 0; i < m_impl->screens.size(); ++i) {
            if (!m_impl->screens[i].isPrimary) { m_impl->selectedIndex = i; break; }
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
}

OutputService::~OutputService() = default;

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

void OutputService::setSelectedScreenIndex(int index)
{
    if (!m_impl) return;
    if (index < 0 || index >= m_impl->screens.size()) return;
    if (m_impl->selectedIndex == index) return;
    m_impl->selectedIndex = index;
    m_impl->settings.setValue(QString::fromLatin1(Impl::kSettingKey), index);
    emit selectedScreenIndexChanged();
}

void OutputService::setProjectionMode(ProjectionMode mode)
{
    if (!m_impl) return;
    // Sticky once written, even if the new value matches the current one —
    // an explicit user choice should freeze subsequent hot-plug recomputes
    // regardless of whether the value actually changes.
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
    // Any non-primary screen present → assume external projector is the target.
    // Otherwise (laptop-only / single-monitor desktop) → Windowed preview.
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

    if (m_impl->selectedIndex >= m_impl->screens.size()) {
        m_impl->selectedIndex = qMax(0, m_impl->screens.size() - 1);
        emit selectedScreenIndexChanged();
    }

    // Hot-plug: if the user hasn't pinned a projection mode, recompute the
    // default. Plugging in an external display flips an auto-windowed laptop
    // back to fullscreen; unplugging the external while idle drops it back
    // to windowed. (We don't switch mid-live — that's UI policy, see
    // ProjectionWindow.qml + Main.qml.)
    if (!m_impl->modeIsUserSet) {
        const auto newMode = computeDefaultMode();
        if (newMode != m_impl->mode) {
            m_impl->mode = newMode;
            emit projectionModeChanged();
        }
    }

    emit screensChanged();
}

}  // namespace crater
