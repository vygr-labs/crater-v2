#pragma once

#include "crater/value/Screen.h"

#include <QList>
#include <QObject>

namespace crater {

// Display routing — enumerates monitors, persists user's chosen output, and
// emits the request for the operator's ProjectionWindow.qml to (re)instantiate
// on a specific screen.
//
// Why we don't own the QQuickWindow here: ARCHITECTURE.md §1 forbids crater-core
// from linking Qt6::Quick. Instead, OutputService emits projectionWindowRequested
// and the executable's QML layer creates the window. Clean separation.
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
    Q_PROPERTY(QList<crater::Screen> screens              READ screens              NOTIFY screensChanged)
    Q_PROPERTY(int                   selectedScreenIndex  READ selectedScreenIndex  WRITE setSelectedScreenIndex NOTIFY selectedScreenIndexChanged)
    Q_PROPERTY(bool                  projectionOpen       READ projectionOpen       NOTIFY projectionOpenChanged)
    Q_PROPERTY(ProjectionMode        projectionMode       READ projectionMode       WRITE setProjectionMode      NOTIFY projectionModeChanged)

public:
    explicit OutputService(QObject* parent = nullptr);
    ~OutputService() override;

    QList<crater::Screen> screens() const;
    int            selectedScreenIndex() const;
    bool           projectionOpen() const;
    ProjectionMode projectionMode() const;

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

signals:
    void screensChanged();
    void selectedScreenIndexChanged();
    void projectionOpenChanged();
    void projectionModeChanged();

    // QML connects to this and instantiates ProjectionWindow.qml on the
    // indicated screen index (matches `screens` list).
    void projectionWindowRequested(int screenIndex);
    void projectionWindowDismissed();

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;

    void           rebuildScreens();
    ProjectionMode computeDefaultMode() const;
};

}  // namespace crater
