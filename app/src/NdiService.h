#pragma once

#include <QObject>
#include <QString>

#include <memory>

class QImage;
class QQuickItem;
class QQuickWindow;

namespace crater {

class NdiRenderer;

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
// Capture paths — start() picks one based on the QSettings flag
// `Settings/useHeadlessNdi` (default true):
//   • Headless (preferred): consume frames from NdiRenderer::frameReady,
//     which renders ProjectionScene into a QRhiTexture via
//     QQuickRenderControl and async-reads back BGRA pixels. No OS window
//     dependency; runs at 60 Hz adaptive (drops to 30 Hz under sustained
//     paint-cost pressure). See qt/docs/render-pipeline-decouple.md.
//   • Legacy (fallback): `setSourceWindow(QQuickWindow*)` registers a
//     projection window; a 30 Hz QTimer calls grabToImage() on it. Used
//     when the headless renderer is disabled by setting or when its
//     start() fails.
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
    // Blank-the-broadcast flag — session-scoped, defaults false. When true,
    // captureFrame() and onHeadlessFrame() zero the outgoing pixel buffer
    // before handing it to NDI's send, regardless of which capture pipeline
    // (legacy grabToImage / headless QRhi) is active and regardless of
    // single/dual output mode. Intercepting at the send boundary makes this
    // bullet-proof: every NDI source path funnels through one of those two
    // methods. Scene-level QML opacity bindings would only catch a subset.
    Q_PROPERTY(bool    blank        READ blank        WRITE setBlank NOTIFY blankChanged)
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
    bool    blank() const;
    void    setBlank(bool b);
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

    // Wire the headless renderer for the QRhi-based capture path. When
    // SettingsService.useHeadlessNdi is true AND this renderer is set
    // AND its start() succeeds, NdiService consumes frames from
    // NdiRenderer::frameReady instead of polling grabToImage on the
    // source window. Falls back to the legacy path on any gate failing.
    // Pass nullptr to clear (forces legacy path on next start).
    void setRenderer(NdiRenderer* renderer);

signals:
    void availableChanged();
    void sendingChanged();
    void blankChanged();
    void streamNameChanged();
    void diagnosticChanged();
    void onProgramChanged();
    void onPreviewChanged();

private:
    void captureFrame();
    // Headless path: invoked synchronously on NdiRenderer::frameReady.
    // Stashes the frame into the ping-pong buffer and hands it to the
    // NDI SDK's send_video_v2/_async_v2 entry. Mirrors the in-flight-
    // safe handoff used by captureFrame() so NDI's required "previous
    // buffer stays valid until next send" contract is honored across
    // both paths.
    void onHeadlessFrame(const QImage& image);
    // Dedicated worker thread body. Sits inside the NDI runtime's
    // blocking get_tally call and posts state changes back to the
    // GUI thread via QMetaObject::invokeMethod with Qt::QueuedConnection.
    void tallyLoop();

    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

}  // namespace crater
