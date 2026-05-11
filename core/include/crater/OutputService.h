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

    Q_PROPERTY(QList<crater::Screen> screens              READ screens              NOTIFY screensChanged)
    Q_PROPERTY(int                   selectedScreenIndex  READ selectedScreenIndex  WRITE setSelectedScreenIndex NOTIFY selectedScreenIndexChanged)
    Q_PROPERTY(bool                  projectionOpen       READ projectionOpen       NOTIFY projectionOpenChanged)

public:
    explicit OutputService(QObject* parent = nullptr);
    ~OutputService() override;

    QList<crater::Screen> screens() const;
    int  selectedScreenIndex() const;
    bool projectionOpen() const;

    void setSelectedScreenIndex(int index);

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

    // QML connects to this and instantiates ProjectionWindow.qml on the
    // indicated screen index (matches `screens` list).
    void projectionWindowRequested(int screenIndex);
    void projectionWindowDismissed();

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;

    void rebuildScreens();
};

}  // namespace crater
