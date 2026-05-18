#pragma once

#include <QObject>
#include <QString>

#include <memory>

class QImage;
class QQuickItem;
class QQuickWindow;

namespace crater {

// NDI broadcast sender — captures the projection window's rendered frames
// and pushes them onto the local network via the NDI runtime.
//
// Lives in the app layer (not crater-core) because pixel capture requires
// Qt6::Quick (QQuickWindow::grabWindow), and crater-core deliberately stays
// Qt6::Quick-free. The companion services here (FileDialogService,
// MediaPlaybackService, VideoThumbnailer) follow the same pattern.
//
// Runtime loading: `Processing.NDI.Lib.x64.dll` (Windows) is dynamically
// loaded via QLibrary at construction. If absent (NDI Tools not installed),
// `available` stays false and start() refuses; the Settings dialog reflects
// that via `diagnostic`. We never link against the NDI SDK at build time —
// the ABI we need is mirrored in src/NdiAbi.h.
//
// Capture loop: `setSourceWindow(QQuickWindow*)` registers the projection
// window. While `sending` is true, a QTimer fires at ~30Hz, calls
// QQuickWindow::grabWindow() to pull rendered pixels (BGRA in memory),
// and hands them to the NDI runtime via send_video_v2. A future RHI
// texture-readback upgrade will replace the timer-driven path with an
// `afterRenderPassRecorded`-hooked async readback for 60 FPS at lower
// UI-thread cost.
//
// Threading: all public API is invoked from the QML/UI thread today.
// grabWindow() is itself synchronous; NDI's send_video_v2 is internally
// async but requires the frame buffer remain valid until the *next* send,
// so we hold the previous QImage as a member.
class NdiService : public QObject
{
    Q_OBJECT

    // True when the NDI runtime (Processing.NDI.Lib.x64.dll) loaded
    // successfully AND initialised. Drives the dialog's "is this section
    // operable" guard.
    Q_PROPERTY(bool    available    READ available    NOTIFY availableChanged)
    Q_PROPERTY(bool    sending      READ sending      NOTIFY sendingChanged)
    Q_PROPERTY(QString streamName   READ streamName   WRITE setStreamName NOTIFY streamNameChanged)
    // Human-readable status. "NDI Tools not installed", "NDI runtime ready",
    // "Broadcasting as 'Crater Live'", etc. Surfaced verbatim in the
    // NdiSection caption so the operator always knows the actual state.
    Q_PROPERTY(QString diagnostic   READ diagnostic   NOTIFY diagnosticChanged)
    // Tally state — receivers signal these. onProgram = "I have this source
    // on-air"; onPreview = "I'm previewing this source for an upcoming take".
    // Both default false when no receivers are paying attention. Polled on
    // a dedicated worker thread while broadcasting; emitted via queued
    // signals so QML bindings can react safely from the GUI thread.
    Q_PROPERTY(bool    onProgram    READ onProgram    NOTIFY onProgramChanged)
    Q_PROPERTY(bool    onPreview    READ onPreview    NOTIFY onPreviewChanged)

public:
    explicit NdiService(QObject* parent = nullptr);
    ~NdiService() override;

    bool    available() const;
    bool    sending() const;
    QString streamName() const;
    QString diagnostic() const;
    bool    onProgram() const;
    bool    onPreview() const;

    void setStreamName(const QString& name);

    // Begin broadcasting. Creates the NDI sender instance and starts the
    // capture timer. Returns false if the runtime isn't available, no
    // source window has been registered, or the sender create fails — in
    // each case `diagnostic` is updated.
    Q_INVOKABLE bool start();

    // Stop broadcasting. Tears down the NDI sender and stops the timer;
    // safe to call when not sending (no-op).
    Q_INVOKABLE void stop();

    // Wire the projection window we should capture. Called from Main.qml's
    // Component.onCompleted with the ProjectionWindow id. Required before
    // start() will succeed.
    Q_INVOKABLE void setSourceWindow(QQuickWindow* window);

    // Optional override — point the grab at a specific QQuickItem inside
    // the source window rather than the window's contentItem. ProjectionWindow
    // exposes its canvas-native `renderItem` for this; setting it via
    // setSourceItem makes NDI capture full-resolution frames from the
    // stage (e.g. 1920×1080) regardless of how big the visible window is.
    // Pass nullptr to revert to grabbing the full window contentItem.
    Q_INVOKABLE void setSourceItem(QQuickItem* item);

signals:
    void availableChanged();
    void sendingChanged();
    void streamNameChanged();
    void diagnosticChanged();
    void onProgramChanged();
    void onPreviewChanged();

private:
    void captureFrame();
    // Dedicated worker thread body. Sits inside the NDI runtime's
    // blocking get_tally call and posts state changes back to the
    // GUI thread via QMetaObject::invokeMethod with Qt::QueuedConnection.
    void tallyLoop();

    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

}  // namespace crater
