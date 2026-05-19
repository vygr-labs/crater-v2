#pragma once

#include <QImage>
#include <QObject>

#include <memory>

class QQmlEngine;

namespace crater {

// Headless NDI render path. Builds a QQuickRenderControl-driven scene graph
// that renders ProjectionScene (outputKind="ndi") directly into a QRhiTexture
// we own, then async-reads back BGRA pixels for the NDI sender.
//
// Why headless rather than the legacy "hidden Item inside the main window +
// grabToImage" path: capture reliability. grabToImage requires a live render
// context on the source QQuickWindow; the Windows compositor doesn't reliably
// allocate one for offscreen windows (the bug that motivated this rewrite).
// A self-managed QRhi pipeline removes the OS-window dependency entirely.
// See qt/docs/render-pipeline-decouple.md for full rationale.
//
// Construction is cheap (Qt objects only, no GPU work) so the instance can
// live as long as the app. start() does the QRhi init + render target
// allocation; stop() symmetrically tears those down. The renderer can be
// stopped and started repeatedly without leaking GPU memory.
//
// Threading: GUI thread only. QQuickRenderControl runs synchronously on
// the calling thread. We trigger render() from a QTimer. Async readback
// is handled via QRhi's resource-update batch — completion fires on the
// next beginFrame().
class NdiRenderer : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool available READ isAvailable NOTIFY availableChanged)
    Q_PROPERTY(int  framerate READ framerate  NOTIFY framerateChanged)

public:
    // `engine` is the main app's QQmlApplicationEngine. We share it (rather
    // than spinning up a second engine) so the Crater singletons —
    // ProjectionService, SettingsService, AppState, ThemeService — resolve
    // to the same instances the main UI sees. A separate engine would yield
    // singleton duplicates and the NDI scene would diverge from live state.
    explicit NdiRenderer(QQmlEngine* engine, QObject* parent = nullptr);
    ~NdiRenderer() override;

    // True between successful start() and matching stop(). Used by
    // NdiService::start() to decide between the headless path and the
    // legacy grabToImage fallback.
    bool isAvailable() const;

    bool isRunning() const;

    // Effective tick rate in Hz. Adaptive scheduler (Phase D) demotes
    // between 60 and 30 based on observed paint cost.
    int framerate() const;

    // Begin rendering. Allocates the QRhi texture target, initialises the
    // render control, and starts the render tick. Returns true on success;
    // false if QRhi init failed (in which case isAvailable() stays false
    // and the caller should fall back to the legacy path).
    Q_INVOKABLE bool start();

    // Stop rendering and release GPU resources. Safe to call when not
    // running. Flushes any in-flight readbacks before destroying textures
    // so the GPU never holds a dangling reference.
    Q_INVOKABLE void stop();

signals:
    void availableChanged();
    void framerateChanged();

    // Emitted on the GUI thread after each successful async readback. The
    // QImage is BGRA (the channel order NDIlib_send_video_v2 expects via
    // NDIlib_FourCC_video_type_BGRA). Consumers must either consume the
    // image synchronously or copy it; the underlying buffer is reused
    // for the next frame.
    void frameReady(const QImage& image);

private slots:
    void renderTick();

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

}  // namespace crater
