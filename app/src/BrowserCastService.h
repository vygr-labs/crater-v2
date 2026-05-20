#pragma once

#include <QObject>
#include <QString>

#include <memory>

class QQuickItem;

namespace crater {

class ProjectionService;

// ─────────────────────────────────────────────────────────────────────────
// BrowserCastService  —  TEMPORARY / SELF-CONTAINED / REMOVABLE FEATURE
//
// Serves the live projection output to a TV's built-in web browser over the
// local network. The use case: a TV with no usable HDMI input, where the
// only way in is the TV's own browser.
//
// Two delivery paths, picked automatically:
//
//   • MJPEG  (GET /stream) — the composited projection (themed text, slides,
//     video-backgrounds-behind-text, transitions) is captured frame by frame
//     and pushed as multipart/x-mixed-replace. The TV page shows it in a
//     plain <img>, so this works even on very old TV browsers (no JS, no
//     WebSocket, no WebRTC needed). MJPEG carries no audio and tops out at
//     ~12 fps here — fine for slides, acceptable for motion backgrounds.
//
//   • Native video (GET /video, with HTTP Range) — when the *whole* live
//     output is a video (a live video item, or a video logo background) the
//     TV page switches to a native <video> element fed the file directly.
//     Hardware-decoded, smooth, and with audio — neither of which MJPEG can
//     do. This is the path that makes "support videos" actually work.
//
//   • GET /        — the one-page app that switches between the two.
//   • GET /state   — tiny JSON the page polls (~0.8 s) to decide which path.
//
// ── HOW TO REMOVE THIS FEATURE ───────────────────────────────────────────
// It is deliberately confined so removal is mechanical. Search the tree for
// the tag "BrowserCast" — every touch point outside this file pair carries
// that tag. To remove:
//   1. Delete app/src/BrowserCastService.h and app/src/BrowserCastService.cpp
//   2. app/CMakeLists.txt — delete the lines tagged "BrowserCast"
//   3. app/src/main.cpp    — delete the lines tagged "BrowserCast"
//   4. app/qml/Main.qml     — delete the lines tagged "BrowserCast"
// ProjectionService and ProjectionScene.qml are NOT modified by this feature.
//
// Layer placement: lives in the app target (not crater-core) because it
// captures pixels through QQuickItem::grabToImage — a Qt6::Quick API that
// crater-core deliberately cannot link (ARCHITECTURE.md §1). NdiService sits
// here for the same reason. Note this is a conscious deviation from §9's
// "talks to the network → crater-core" rule: as a short-lived, possibly
// throwaway feature it is kept in one place for trivial removal rather than
// split correctly across the core/app boundary.
// ─────────────────────────────────────────────────────────────────────────
class BrowserCastService : public QObject
{
    Q_OBJECT

    // True once the TCP server is bound and accepting connections.
    Q_PROPERTY(bool    listening READ listening NOTIFY listeningChanged)
    // The LAN URL to type into the TV browser, e.g. "http://192.168.1.20:7373".
    // Empty until listening. Also logged at startup.
    Q_PROPERTY(QString url       READ url       NOTIFY listeningChanged)
    // True while at least one TV browser is pulling the MJPEG stream. When
    // true the projection scene graph must keep rendering so grabToImage()
    // has fresh frames — Main.qml ORs this into ProjectionWindow.keepRendering
    // exactly as it does for NdiService.sending.
    Q_PROPERTY(bool    active    READ active    NOTIFY activeChanged)

public:
    // `projection` is read (never mutated) to decide MJPEG-vs-video mode and
    // to resolve the current video file path. Must outlive this service —
    // in practice both are stack objects in main() with the same lifetime.
    explicit BrowserCastService(ProjectionService* projection,
                                QObject* parent = nullptr);
    ~BrowserCastService() override;

    bool    listening() const;
    QString url() const;
    bool    active() const;

    // The canvas-native projection Item to capture — ProjectionWindow's
    // `renderItem`. Wired from Main.qml's Component.onCompleted, mirroring
    // NdiService::setSourceItem. Safe to call before or after start().
    Q_INVOKABLE void setSourceItem(QQuickItem* item);

    // Bind the server to a LAN port and begin serving. Idempotent — a second
    // call while already listening is a no-op returning true. Returns false
    // if no candidate port could be bound.
    Q_INVOKABLE bool start();

    // Stop serving and drop all connections. Safe to call when not started.
    Q_INVOKABLE void stop();

signals:
    void listeningChanged();
    void activeChanged();

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

}  // namespace crater
