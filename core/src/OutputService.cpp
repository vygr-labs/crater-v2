#include "crater/OutputService.h"

#include <QDebug>
#include <QGuiApplication>
#include <QScreen>
#include <QSettings>

namespace crater {

struct OutputService::Impl
{
    QList<Screen> screens;
    int           selectedIndex  = 0;
    bool          projectionOpen = false;
    QSettings     settings{QStringLiteral("Voyager Labs"), QStringLiteral("Crater")};

    static constexpr const char* kSettingKey = "Output/selectedScreen";
};

OutputService::OutputService(QObject* parent)
    : QObject(parent)
    , m_impl(std::make_unique<Impl>())
{
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

void OutputService::setSelectedScreenIndex(int index)
{
    if (!m_impl) return;
    if (index < 0 || index >= m_impl->screens.size()) return;
    if (m_impl->selectedIndex == index) return;
    m_impl->selectedIndex = index;
    m_impl->settings.setValue(QString::fromLatin1(Impl::kSettingKey), index);
    emit selectedScreenIndexChanged();
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
    emit screensChanged();
}

}  // namespace crater
