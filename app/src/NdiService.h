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
// Runtime loading: `Processing.NDI.Lib.x64.dll` (Windows), `libndi.dylib`
// (macOS) or `libndi.so.6` (Linux) is dynamically loaded via QLibrary at
// construction. If absent (NDI Tools not installed),
// `available` stays false and start() refuses; the Settings dialog reflects
// that via `diagnostic`. We never link against the NDI SDK at build time —
// the ABI we need is mirrored in src/NdiAbi.h.
//
// Capture paths — start() picks one based on the QSettings flag
// `Settings/useHeadlessNdi` (default true):
//   • Headless (preferred): consume frames from NdiRenderer::frameReady,
//     which renders ProjectionScene into a QRhiTexture via
//     QQuickRenderControl and async-reads back premultiplied R-G-B-A
//     pixels. No OS window dependency; runs at 60 Hz adaptive (drops to
//     30 Hz under sustained paint-cost pressure). See
//     qt/docs/render-pipeline-decouple.md.
//   • Legacy (fallback): `setSourceWindow(QQuickWindow*)` registers a
//     projection window; a 30 Hz QTimer calls grabToImage() on it. Used
//     when the headless renderer is disabled by setting or when its
//     start() fails.
//
// Threading: all public API is invoked from the QML/UI thread. Both capture
// paths hand each frame to a dedicated send thread (queueFrame), which does
// the pixel-format conversion, scaling and the NDI send off the UI thread.
// NDI's async send requires the frame buffer remain valid until the *next*
// send, so the send thread holds the previous buffer as a member.
class NdiService : public QObject
{
    Q_OBJECT

    // True when the NDI runtime library loaded
    // successfully AND initialised. Drives the dialog's "is this section
    // operable" guard.
    Q_PROPERTY(bool    available    READ available    NOTIFY availableChanged)
    Q_PROPERTY(bool    sending      READ sending      NOTIFY sendingChanged)
    // Blank-the-broadcast flag — session-scoped, defaults false. When true,
    // the send thread replaces each outgoing frame with an empty one
    // (transparent in BGRA; BGRX and UYVY go out opaque black), regardless
    // of which capture pipeline
    // (legacy grabToImage / headless QRhi) is active and regardless of
    // single/dual output mode. Intercepting at the send boundary makes this
    // bullet-proof: every NDI source path funnels through queueFrame(). Scene-level QML opacity bindings would only catch a subset.
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
    struct SendJob;

    void captureFrame();
    // Headless path: invoked on NdiRenderer::frameReady. Queues the frame
    // for the send thread, like captureFrame() does for the legacy grab.
    void onHeadlessFrame(const QImage& image, bool bottomUp);
    // GUI thread. Stamps the blank flag on the frame and puts it in the send
    // thread's one-slot mailbox, replacing a frame not yet taken. `image`
    // holds premultiplied colour in any 32-bit premultiplied format;
    // `bottomUp` says its rows are stored bottom-up (OpenGL readback);
    // `overBlack` picks what BGRX/UYVY get: the colour over black (headless)
    // or the straight colour (legacy grab, as it always sent). rateN/rateD
    // carry each path's advertised frame rate.
    void queueFrame(QImage image, bool bottomUp, bool overBlack,
                    int rateN, int rateD);
    // Send thread body: waits for a queued frame and sends it.
    void sendLoop();
    // Send thread. Applies the configured downscale (done premultiplied)
    // and pixel format, then issues the async/sync send. BGRA always goes
    // out straight alpha; BGRX takes the colour `overBlack` picks with an
    // opaque 4th byte; UYVY packs it.
    void sendResolvedFrame(const SendJob& job);
    // Dedicated worker thread body. Sits inside the NDI runtime's
    // blocking get_tally call and posts state changes back to the
    // GUI thread via QMetaObject::invokeMethod with Qt::QueuedConnection.
    void tallyLoop();

    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

}  // namespace crater
