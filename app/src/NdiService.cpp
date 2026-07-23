#include "NdiService.h"
#include "NdiAbi.h"
#include "NdiRenderer.h"

#include <QByteArray>
#include <QDebug>
#include <QImage>
#include <QLibrary>
#include <QMetaObject>
#include <QQuickItem>
#include <QQuickItemGrabResult>
#include <QQuickWindow>
#include <QSettings>
#include <QSharedPointer>
#include <QSize>
#include <QStringList>
#include <QTimer>

#include <atomic>
#include <thread>

namespace crater {

struct NdiService::Impl
{
    // Loader + resolved function pointers. Required symbols: init,
    // destroy, send_create, send_destroy, and at least one send_video
    // variant. Optional: async send + tally — older SDKs may lack them.
    QLibrary lib;
    NDIlib_initialize_fn               fn_init             = nullptr;
    NDIlib_destroy_fn                  fn_destroy          = nullptr;
    NDIlib_send_create_fn              fn_send_create      = nullptr;
    NDIlib_send_destroy_fn             fn_send_destroy     = nullptr;
    NDIlib_send_send_video_v2_fn       fn_send_video       = nullptr;
    NDIlib_send_send_video_async_v2_fn fn_send_video_async = nullptr;
    NDIlib_send_get_tally_fn           fn_send_get_tally   = nullptr;

    // Active sender instance (nullptr when not broadcasting).
    NDIlib_send_instance_t sender = nullptr;

    // Q_PROPERTY-backing state.
    bool    available  = false;
    bool    sending    = false;
    bool    blank      = false;   // when true, captureFrame / onHeadlessFrame zero the outgoing buffer
    QString streamName = QStringLiteral("Crater Live");
    QString diagnostic;
    bool    onProgram  = false;
    bool    onPreview  = false;

    // Capture target — set by setSourceWindow(). The capture timer is
    // a no-op when this is null even if sending == true.
    QQuickWindow* sourceWindow = nullptr;

    // Optional sub-item to grab from instead of the window's contentItem.
    // ProjectionWindow's canvas-native render Item sits inside a letterbox
    // scaler; pointing at it directly via setSourceItem() yields canvas-
    // native pixels (typically 1920×1080) regardless of display window
    // size. When null, we fall back to sourceWindow->contentItem().
    QQuickItem* sourceItem = nullptr;

    // Two-slot frame buffer ping-pong. NDIlib_send_send_video_async_v2
    // keeps the most-recently-sent buffer referenced until the NEXT call
    // for the same sender. We alternate slots so the buffer NDI is
    // currently consuming is never the one we're about to overwrite.
    //
    // Sequence (single sender): frame N writes to slot[0], NDI takes
    // slot[0]. Frame N+1 writes to slot[1] and sends slot[1]; NDI
    // releases slot[0] as part of that call. Frame N+2 writes to
    // slot[0] safely (NDI no longer holds it).
    QImage frameBuffers[2];
    int    activeBuffer = 0;

    // Broadcast format, resolved from Settings at start() (mirrors the
    // useHeadlessNdi read). fourCC is the direct 32-bit format for the
    // BGRA/BGRX paths; packUyvy switches to the 4:2:2 packer, which writes
    // into uyvyBuffers[activeBuffer] — a second ping-pong pair so the buffer
    // NDI's async send still references stays alive (dst.bits() is not the
    // UYVY data). targetSize, when valid, downscales each frame before send.
    NDIlib_FourCC_video_type_e ndiFourCC = NDIlib_FourCC_video_type_BGRA;
    bool       packUyvy  = false;
    QSize      targetSize;               // invalid → native (no downscale)
    QByteArray uyvyBuffers[2];

    // In-flight throttle for the async grab path. Set true when a
    // grabToImage() request is dispatched; cleared in the completion
    // lambda. While true, the timer's next tick is a no-op — this is
    // how we backpressure naturally when the render thread can't keep
    // up with our 30Hz capture cadence (the timer ticks at 30Hz, but
    // delivered framerate is whatever render can serve).
    bool   captureInFlight = false;

    QTimer captureTimer;

    // Headless capture wiring (the QRhi path). When `renderer` is set
    // and SettingsService.useHeadlessNdi is true, start() will try to
    // start the renderer and subscribe to its frameReady signal instead
    // of running the captureTimer. `usingHeadless` tells stop() which
    // path to tear down — it's set in start() based on the runtime
    // decision, not on the QSettings flag (so flipping the flag
    // mid-broadcast doesn't desync the two halves).
    NdiRenderer*           renderer        = nullptr;
    bool                   usingHeadless   = false;
    QMetaObject::Connection frameConnection;

    // Tally polling — dedicated thread that sits inside NDI's blocking
    // get_tally call. Wakes every 100ms to check the stop flag so
    // shutdown is responsive without burning CPU. Launched in start(),
    // joined in stop() before destroying the sender (the loop calls
    // fn_send_get_tally(sender) — must exit before sender is freed).
    std::thread       tallyThread;
    std::atomic<bool> tallyStop{false};
};

NdiService::NdiService(QObject* parent)
    : QObject(parent)
    , m_impl(std::make_unique<Impl>())
{
    // Locate the NDI runtime. Standard `Processing.NDI.Lib.x64.dll` on PATH
    // is the happy path; in practice the installer's PATH update doesn't
    // always propagate to a running app, so we probe known install paths
    // + the env vars NDI sets system-wide. We log each attempt so the log
    // tells a clear story when load still fails despite NDI being present.
    QStringList candidates;
    candidates << QStringLiteral("Processing.NDI.Lib.x64");  // PATH search

    // Env vars set by the NDI 5 / NDI 6 installers — these survive any
    // PATH issues. Strip trailing slash defensively before appending.
    auto appendFromEnv = [&candidates](const char* envName) {
        const QByteArray raw = qgetenv(envName);
        if (raw.isEmpty()) return;
        QString dir = QString::fromLocal8Bit(raw);
        while (dir.endsWith(QLatin1Char('/')) || dir.endsWith(QLatin1Char('\\'))) {
            dir.chop(1);
        }
        candidates << (dir + QStringLiteral("/Processing.NDI.Lib.x64.dll"));
    };
    appendFromEnv("NDI_RUNTIME_DIR_V6");
    appendFromEnv("NDI_RUNTIME_DIR_V5");
    appendFromEnv("NDI_RUNTIME_DIR_V4");
    appendFromEnv("NDI_SDK_DIR");

    // Standard install paths, derived from %ProgramFiles% so the search
    // works on systems where Windows isn't on C:\ (or where Program Files
    // is localised — e.g. "Programmes" on French Windows). The env var
    // name itself stays in English regardless of OS locale, so resolution
    // is deterministic. We also probe %ProgramFiles(x86)% in case a
    // future 32-bit installer ever lands there.
    static constexpr const char* kRelPaths[] = {
        "NDI/NDI 6 Tools/Bin/x64/Processing.NDI.Lib.x64.dll",
        "NDI/NDI 6 Tools/Bin/Processing.NDI.Lib.x64.dll",
        "NDI/NDI 6 Runtime/v6/Processing.NDI.Lib.x64.dll",
        "NDI/NDI 5 Tools/Bin/x64/Processing.NDI.Lib.x64.dll",
        "NDI/NDI 5 Tools/Bin/Processing.NDI.Lib.x64.dll",
        "NDI/NDI 5 Runtime/v5/Processing.NDI.Lib.x64.dll",
        "NDI 5 Tools/Bin/x64/Processing.NDI.Lib.x64.dll",
        "NDI 6 SDK/Bin/x64/Processing.NDI.Lib.x64.dll",
        "NDI 5 SDK/Bin/x64/Processing.NDI.Lib.x64.dll",
        "NDI 4 SDK/Bin/x64/Processing.NDI.Lib.x64.dll",
        "NewTek/NDI 5 Tools/Bin/x64/Processing.NDI.Lib.x64.dll",
        "NewTek/NDI 5 SDK/Bin/x64/Processing.NDI.Lib.x64.dll",
        "NewTek/NDI 4 SDK/Bin/x64/Processing.NDI.Lib.x64.dll",
    };
    auto withPrefix = [&candidates](const QString& prefix) {
        if (prefix.isEmpty()) return;
        QString cleanPrefix = prefix;
        while (cleanPrefix.endsWith(QLatin1Char('/'))
            || cleanPrefix.endsWith(QLatin1Char('\\'))) {
            cleanPrefix.chop(1);
        }
        for (const char* rel : kRelPaths) {
            candidates << (cleanPrefix
                + QLatin1Char('/')
                + QString::fromLatin1(rel));
        }
    };
    withPrefix(qEnvironmentVariable("ProgramFiles"));
    withPrefix(qEnvironmentVariable("ProgramFiles(x86)"));

    qInfo() << "NDI: probing for runtime DLL across" << candidates.size() << "candidate paths";
    QString lastError;
    for (const QString& path : std::as_const(candidates)) {
        m_impl->lib.setFileName(path);
        if (m_impl->lib.load()) {
            qInfo().noquote() << "NDI: loaded runtime from" << m_impl->lib.fileName();
            break;
        }
        lastError = m_impl->lib.errorString();
        qInfo().noquote() << "NDI:   miss" << path << "—" << lastError;
    }

    if (!m_impl->lib.isLoaded()) {
        m_impl->diagnostic = tr(
            "NDI runtime not found. Install NDI Tools (ndi.video/tools) or set "
            "NDI_RUNTIME_DIR_V6 / V5 to the directory containing "
            "Processing.NDI.Lib.x64.dll.");
        qWarning().noquote() << "NDI: all probe paths failed; last error =" << lastError;
        return;
    }

    // Required symbols.
    m_impl->fn_init         = (NDIlib_initialize_fn)
        m_impl->lib.resolve("NDIlib_initialize");
    m_impl->fn_destroy      = (NDIlib_destroy_fn)
        m_impl->lib.resolve("NDIlib_destroy");
    m_impl->fn_send_create  = (NDIlib_send_create_fn)
        m_impl->lib.resolve("NDIlib_send_create");
    m_impl->fn_send_destroy = (NDIlib_send_destroy_fn)
        m_impl->lib.resolve("NDIlib_send_destroy");
    m_impl->fn_send_video   = (NDIlib_send_send_video_v2_fn)
        m_impl->lib.resolve("NDIlib_send_send_video_v2");

    if (!m_impl->fn_init || !m_impl->fn_destroy
     || !m_impl->fn_send_create || !m_impl->fn_send_destroy
     || !m_impl->fn_send_video) {
        m_impl->diagnostic = tr(
            "NDI runtime found but required symbols missing — incompatible SDK version.");
        qWarning() << "NDI: failed to resolve one or more required entry points";
        return;
    }

    // Optional symbols. Async send avoids UI-thread blocks when the
    // runtime's frame clock kicks in; we fall back to sync if absent.
    // get_tally drives the on-air/preview Q_PROPERTYs; without it
    // those simply never update from defaults.
    m_impl->fn_send_video_async = (NDIlib_send_send_video_async_v2_fn)
        m_impl->lib.resolve("NDIlib_send_send_video_async_v2");
    m_impl->fn_send_get_tally   = (NDIlib_send_get_tally_fn)
        m_impl->lib.resolve("NDIlib_send_get_tally");
    if (!m_impl->fn_send_video_async) {
        qInfo() << "NDI: async send unavailable, falling back to sync send";
    }
    if (!m_impl->fn_send_get_tally) {
        qInfo() << "NDI: tally polling unavailable on this runtime";
    }

    if (!m_impl->fn_init()) {
        // NDIlib_initialize() returns false if the host CPU lacks SSSE3
        // (extremely rare for modern hardware) or another initialisation
        // step failed inside the SDK.
        m_impl->diagnostic = tr(
            "NDI runtime initialisation failed (unsupported CPU feature set?).");
        qWarning() << "NDI: NDIlib_initialize returned false";
        return;
    }

    m_impl->available = true;
    m_impl->diagnostic = tr("NDI runtime ready");
    qInfo() << "NDI: runtime initialised";

    // Capture timer — fires at ~30 Hz. PreciseTimer because frame pacing
    // matters: drift here shows up as choppy playback in OBS. We start
    // the timer in start() and stop it in stop().
    m_impl->captureTimer.setInterval(33);
    m_impl->captureTimer.setTimerType(Qt::PreciseTimer);
    connect(&m_impl->captureTimer, &QTimer::timeout,
            this, [this]() { captureFrame(); });
}

NdiService::~NdiService()
{
    stop();
    if (m_impl && m_impl->available && m_impl->fn_destroy) {
        m_impl->fn_destroy();
    }
}

bool    NdiService::available() const   { return m_impl->available; }
bool    NdiService::sending() const     { return m_impl->sending; }
bool    NdiService::blank() const       { return m_impl->blank; }
QString NdiService::streamName() const  { return m_impl->streamName; }
QString NdiService::diagnostic() const  { return m_impl->diagnostic; }
bool    NdiService::onProgram() const   { return m_impl->onProgram; }
bool    NdiService::onPreview() const   { return m_impl->onPreview; }

void NdiService::setBlank(bool b)
{
    // Idempotent — no signal storm if the operator rapid-clicks the toggle.
    // The pixel-zeroing in captureFrame / onHeadlessFrame is gated on this
    // flag at frame-build time, so flipping it takes effect on the very
    // next outgoing frame (within ~16-33 ms depending on path).
    if (m_impl->blank == b) return;
    m_impl->blank = b;
    emit blankChanged();
}

void NdiService::setStreamName(const QString& name)
{
    if (m_impl->streamName == name) return;
    m_impl->streamName = name;
    emit streamNameChanged();

    // Renaming a live stream requires tearing down + recreating the sender.
    // Receivers (OBS) see this as the source disappearing + reappearing —
    // acceptable for a settings tweak; this is not a "rename while live"
    // production workflow today.
    if (m_impl->sending) {
        stop();
        start();
    }
}

void NdiService::setSourceWindow(QQuickWindow* window)
{
    m_impl->sourceWindow = window;
}

void NdiService::setSourceItem(QQuickItem* item)
{
    m_impl->sourceItem = item;
}

void NdiService::setRenderer(NdiRenderer* renderer)
{
    m_impl->renderer = renderer;
}

bool NdiService::start()
{
    if (!m_impl->available) {
        // diagnostic was set at construction; leave it alone.
        return false;
    }
    if (m_impl->sending) return true;

    // Decide capture path. Read the flag via QSettings directly so we
    // don't take a hard dependency on SettingsService (which is a QML
    // singleton, not a C++ one accessible here). Default true matches
    // SettingsService's compiled-in default.
    const bool wantHeadless = QSettings()
        .value(QStringLiteral("Settings/useHeadlessNdi"), true).toBool();

    bool useHeadless = false;
    if (wantHeadless && m_impl->renderer) {
        if (m_impl->renderer->start()) {
            useHeadless = true;
        } else {
            qWarning() << "NDI: headless renderer start() failed — "
                          "falling back to legacy grabToImage path";
        }
    }

    // The legacy path needs a registered source window. The headless
    // path doesn't — it brings its own scene + render target.
    if (!useHeadless && !m_impl->sourceWindow) {
        m_impl->diagnostic = tr("NDI: no projection window registered");
        emit diagnosticChanged();
        return false;
    }

    NDIlib_send_create_t settings = {};
    const QByteArray name = m_impl->streamName.toUtf8();
    settings.p_ndi_name  = name.constData();
    settings.p_groups    = nullptr;     // default group only — most receivers
    settings.clock_video = true;        // let NDI rate-limit our sends
    settings.clock_audio = false;

    m_impl->sender = m_impl->fn_send_create(&settings);
    if (!m_impl->sender) {
        if (useHeadless) m_impl->renderer->stop();
        m_impl->diagnostic = tr("NDI sender creation failed");
        emit diagnosticChanged();
        return false;
    }

    m_impl->sending         = true;
    m_impl->usingHeadless   = useHeadless;
    m_impl->activeBuffer    = 0;       // reset ping-pong
    m_impl->captureInFlight = false;   // ensure clean slate after a previous stop

    // Resolve broadcast format + resolution from Settings (same direct-
    // QSettings read as useHeadlessNdi above, for the same reason). Snapshot
    // into m_impl so the frame builders don't re-read per frame; a change
    // applies on the next broadcast (re)start. Unknown values fall back to
    // the original fixed path (BGRA, native).
    {
        const QString fmt = QSettings()
            .value(QStringLiteral("Settings/ndiPixelFormat"), QStringLiteral("bgra"))
            .toString().toLower();
        m_impl->packUyvy  = (fmt == QStringLiteral("uyvy"));
        m_impl->ndiFourCC = (fmt == QStringLiteral("bgrx"))
                                ? NDIlib_FourCC_video_type_BGRX
                                : NDIlib_FourCC_video_type_BGRA;

        const QString res = QSettings()
            .value(QStringLiteral("Settings/ndiResolution"), QStringLiteral("native"))
            .toString().toLower();
        m_impl->targetSize = (res == QStringLiteral("720p")) ? QSize(1280, 720) : QSize();
    }

    if (useHeadless) {
        // Subscribe to the renderer's frame stream. The connection handle
        // lets stop() disconnect cleanly without affecting other QObject
        // signal/slot pairs on the same emitter.
        m_impl->frameConnection = connect(
            m_impl->renderer, &NdiRenderer::frameReady,
            this, [this](const QImage& img) { onHeadlessFrame(img); });
    } else {
        m_impl->captureTimer.start();
    }

    // Spawn tally polling thread. Only when get_tally is available; the
    // thread terminates within 100ms of tallyStop being set.
    if (m_impl->fn_send_get_tally) {
        m_impl->tallyStop.store(false);
        m_impl->tallyThread = std::thread([this]() { tallyLoop(); });
    }

    m_impl->diagnostic = tr("Broadcasting on local network as \"%1\"")
                             .arg(m_impl->streamName);
    emit sendingChanged();
    emit diagnosticChanged();
    qInfo().noquote() << "NDI: broadcasting as" << m_impl->streamName
                      << "via"
                      << (useHeadless ? "headless renderer" : "legacy grabToImage")
                      << "path";
    return true;
}

void NdiService::stop()
{
    if (!m_impl->sending) return;

    // Tear down the capture path we actually used (set in start()). The
    // QSettings flag could have changed mid-broadcast — stick to the
    // path we committed to so we don't leak a running timer OR a live
    // signal connection.
    if (m_impl->usingHeadless) {
        QObject::disconnect(m_impl->frameConnection);
        if (m_impl->renderer) m_impl->renderer->stop();
    } else {
        m_impl->captureTimer.stop();
    }

    // Tear down the tally thread BEFORE destroying the sender — the loop
    // calls fn_send_get_tally(sender), which would crash on a freed
    // instance. Setting tallyStop tells the loop to exit on its next
    // wake-up (within 100ms of the current iteration's timeout).
    m_impl->tallyStop.store(true);
    if (m_impl->tallyThread.joinable()) {
        m_impl->tallyThread.join();
    }

    // Reset tally so the dialog doesn't carry stale "on-air" state across
    // restart. We write directly + emit because the worker is joined.
    if (m_impl->onProgram) {
        m_impl->onProgram = false;
        emit onProgramChanged();
    }
    if (m_impl->onPreview) {
        m_impl->onPreview = false;
        emit onPreviewChanged();
    }

    if (m_impl->sender) {
        m_impl->fn_send_destroy(m_impl->sender);
        m_impl->sender = nullptr;
    }
    // Release the held buffers — NDI no longer references them.
    m_impl->frameBuffers[0] = QImage();
    m_impl->frameBuffers[1] = QImage();
    m_impl->uyvyBuffers[0]  = QByteArray();
    m_impl->uyvyBuffers[1]  = QByteArray();

    m_impl->sending       = false;
    m_impl->usingHeadless = false;
    m_impl->diagnostic = m_impl->available
        ? tr("NDI runtime ready")
        : m_impl->diagnostic;  // preserve install/init diagnostics
    emit sendingChanged();
    emit diagnosticChanged();
    qInfo() << "NDI: broadcast stopped";
}

void NdiService::captureFrame()
{
    if (!m_impl->sending || !m_impl->sourceWindow || !m_impl->sender) return;

    // Skip if a previous grab is still pending. The render thread will
    // complete it and clear the flag; we'll catch the next timer tick.
    // This is the natural backpressure that protects the GUI thread
    // from queuing capture requests faster than the render can serve.
    if (m_impl->captureInFlight) return;

    // Prefer the explicit sourceItem (canvas-native render surface) if
    // wired; fall back to the window's full contentItem otherwise. The
    // sourceItem path yields canvas-native pixels regardless of how big
    // the actual display window is — important when the operator has the
    // projection in a small windowed preview but NDI should still
    // broadcast at full 1920×1080.
    QQuickItem* root = m_impl->sourceItem
        ? m_impl->sourceItem
        : m_impl->sourceWindow->contentItem();
    if (!root) return;

    // Async grab — returns a QSharedPointer<QQuickItemGrabResult>
    // immediately. The render thread does the offscreen render in the
    // background; the GUI thread is free to handle operator input.
    // result->ready() fires (on the GUI thread) when the bytes are
    // available. This replaces the previous synchronous grabWindow()
    // path that was stalling the GUI thread ~5-15ms per call at 30Hz.
    auto result = root->grabToImage();
    if (!result) return;

    m_impl->captureInFlight = true;

    // Qt::SingleShotConnection is critical here — without it, the
    // connection persists after `ready()` fires once, which keeps the
    // lambda (and its captured QSharedPointer<QQuickItemGrabResult>)
    // alive forever. That creates a circular reference: the result
    // can't be freed because the connection holds it via the lambda,
    // and the connection can't be auto-removed because the result is
    // still alive. At 30 Hz with ~8MB per grabbed 1080p frame, this
    // leaks ~240MB/sec. SingleShotConnection auto-disconnects after
    // the first emission so the chain unwinds cleanly: lambda is
    // destroyed → shared pointer ref drops → result is freed → memory
    // is reclaimed.
    connect(result.data(), &QQuickItemGrabResult::ready, this, [this, result]() {
        m_impl->captureInFlight = false;

        // Recheck guards — the operator may have flipped NDI off while
        // the grab was in flight, in which case sender is now null and
        // we'd crash calling into the runtime.
        if (!m_impl->sending || !m_impl->sender) return;

        QImage img = result->image();
        if (img.isNull()) return;
        if (img.format() != QImage::Format_ARGB32) {
            img = img.convertToFormat(QImage::Format_ARGB32);
        }

        // Toggle FIRST, then assign into the now-free slot. The other
        // slot is whatever NDI is currently consuming from the previous
        // send — must not touch.
        m_impl->activeBuffer ^= 1;
        QImage& dst = m_impl->frameBuffers[m_impl->activeBuffer];
        dst = std::move(img);

        // Blank intercept — operator toggled "Blank broadcast" in the
        // TopBar. Zero the just-assigned buffer; the BGRA pixel layout
        // becomes all-zero, which NDI sends as fully-transparent (alpha-
        // respecting receivers) or solid black (alpha-stripping). The
        // grab itself already happened — we eat that cost — but the
        // outgoing frame is blank. We keep streaming at full cadence so
        // receivers stay locked on the source instead of timing out.
        if (m_impl->blank) dst.fill(Qt::transparent);

        // Apply the configured resolution + pixel format and send. 30000/1001
        // (29.97) is the legacy grab path's advertised rate.
        sendResolvedFrame(dst, 30000, 1001);
    }, Qt::SingleShotConnection);
}

// Pack an ARGB32 (little-endian: byte order B,G,R,A) image into UYVY 4:2:2.
// Two horizontal pixels share one U/V pair (averaged); each keeps its own
// luma. BT.709 limited-range coefficients (video range 16–235 luma), scaled
// by 256. UYVY byte order per pixel-pair: U, Y0, V, Y1.
static void packArgb32ToUyvy(const QImage& img, QByteArray& out)
{
    const int w = img.width();
    const int h = img.height();
    if (w <= 0 || h <= 0) { out.clear(); return; }
    const int stride = w * 2;                 // 2 bytes per pixel
    out.resize(stride * h);                   // no-op once capacity is reached
    auto* dstBase = reinterpret_cast<uint8_t*>(out.data());

    auto clamp8 = [](int v) -> uint8_t {
        return uint8_t(v < 0 ? 0 : (v > 255 ? 255 : v));
    };

    for (int y = 0; y < h; ++y) {
        const uchar* src = img.constScanLine(y);
        uint8_t* d = dstBase + y * stride;
        for (int x = 0; x < w; x += 2) {
            const int b0 = src[4 * x + 0];
            const int g0 = src[4 * x + 1];
            const int r0 = src[4 * x + 2];
            const int x1 = (x + 1 < w) ? (x + 1) : x;   // clamp odd last column
            const int b1 = src[4 * x1 + 0];
            const int g1 = src[4 * x1 + 1];
            const int r1 = src[4 * x1 + 2];

            const int y0 = clamp8((( 47 * r0 + 157 * g0 + 16 * b0) >> 8) + 16);
            const int y1 = clamp8((( 47 * r1 + 157 * g1 + 16 * b1) >> 8) + 16);
            const int ra = (r0 + r1) >> 1, ga = (g0 + g1) >> 1, ba = (b0 + b1) >> 1;
            const int u  = clamp8(((-26 * ra -  87 * ga + 112 * ba) >> 8) + 128);
            const int v  = clamp8((( 112 * ra - 102 * ga -  10 * ba) >> 8) + 128);

            d[0] = uint8_t(u);
            d[1] = uint8_t(y0);
            d[2] = uint8_t(v);
            d[3] = uint8_t(y1);
            d += 4;
        }
    }
}

void NdiService::sendResolvedFrame(QImage& dst, int rateN, int rateD)
{
    // Optional downscale, written back into the SAME ping-pong slot so the
    // pixels p_data points at stay alive until NDI releases them.
    if (m_impl->targetSize.isValid()
        && (dst.width()  != m_impl->targetSize.width()
         || dst.height() != m_impl->targetSize.height())) {
        dst = dst.scaled(m_impl->targetSize.width(), m_impl->targetSize.height(),
                         Qt::IgnoreAspectRatio, Qt::SmoothTransformation);
    }

    NDIlib_video_frame_v2_t frame = {};
    frame.xres                  = dst.width();
    frame.yres                  = dst.height();
    frame.frame_rate_N          = rateN;
    frame.frame_rate_D          = rateD;
    frame.picture_aspect_ratio  = dst.height() > 0
        ? float(dst.width()) / float(dst.height())
        : 16.0f / 9.0f;
    frame.frame_format_type     = NDIlib_frame_format_type_progressive;
    frame.timecode              = 0;       // 0 = "synthesise on receive"
    frame.p_metadata            = nullptr;
    frame.timestamp             = 0;

    if (m_impl->packUyvy) {
        QByteArray& buf = m_impl->uyvyBuffers[m_impl->activeBuffer];
        packArgb32ToUyvy(dst, buf);
        frame.FourCC               = NDIlib_FourCC_video_type_UYVY;
        frame.p_data               = reinterpret_cast<uint8_t*>(buf.data());
        frame.line_stride_in_bytes = dst.width() * 2;
    } else {
        // BGRA or BGRX — identical 32-bit layout; only the FourCC (whether
        // the alpha byte is honored) differs. dst is ARGB32 → B,G,R,A bytes.
        frame.FourCC               = m_impl->ndiFourCC;
        frame.p_data               = dst.bits();
        frame.line_stride_in_bytes = dst.bytesPerLine();
    }

    // Prefer async send when the runtime exposes it (returns after queueing);
    // fall back to sync on older SDKs.
    if (m_impl->fn_send_video_async) {
        m_impl->fn_send_video_async(m_impl->sender, &frame);
    } else {
        m_impl->fn_send_video(m_impl->sender, &frame);
    }
}

void NdiService::onHeadlessFrame(const QImage& image)
{
    // Recheck guards — flag flipped or stop() ran between the renderer's
    // emit and our slot invocation. The connection itself is disconnected
    // by stop(), but a single in-flight signal can still arrive.
    if (!m_impl->sending || !m_impl->sender) return;
    if (image.isNull()) return;

    // Toggle the ping-pong index FIRST so we never overwrite the buffer
    // NDI is currently sending from (whatever was in the previous
    // activeBuffer slot is what NDI's previous send_video_async_v2 call
    // still holds; that ref is released when we issue the new send).
    m_impl->activeBuffer ^= 1;
    QImage& dst = m_impl->frameBuffers[m_impl->activeBuffer];
    dst = image;
    if (dst.format() != QImage::Format_ARGB32) {
        dst = dst.convertToFormat(QImage::Format_ARGB32);
    }

    // Blank intercept — same gate as the legacy captureFrame path. Mirror
    // the comment there: cost of the headless render is already paid,
    // but the outgoing pixels go transparent so the broadcast goes dark
    // without breaking the stream.
    if (m_impl->blank) dst.fill(Qt::transparent);

    // Apply the configured resolution + pixel format and send. 60000/1001
    // (≈59.94) is the headless renderer's advertised rate — see below on why
    // advertising 60 is fine even when adaptive demotion drops delivery to 30.
    // Receivers handle the gap because clock_video was set true at create.
    sendResolvedFrame(dst, 60000, 1001);
}

void NdiService::tallyLoop()
{
    // Runs on a dedicated worker thread. Waits inside the NDI runtime's
    // blocking get_tally call (which wakes when tally state changes or
    // the 100ms timeout elapses). Any tally change is posted back to the
    // GUI thread via QMetaObject::invokeMethod with Qt::QueuedConnection
    // so QML bindings observe atomic property updates on their natural
    // thread.
    NDIlib_tally_t tally = {};
    bool prevProgram = false;
    bool prevPreview = false;

    while (!m_impl->tallyStop.load()) {
        if (!m_impl->sender || !m_impl->fn_send_get_tally) break;
        m_impl->fn_send_get_tally(m_impl->sender, &tally, 100);
        if (m_impl->tallyStop.load()) break;

        if (tally.on_program != prevProgram) {
            prevProgram = tally.on_program;
            const bool v = tally.on_program;
            QMetaObject::invokeMethod(this, [this, v]() {
                if (m_impl->onProgram == v) return;
                m_impl->onProgram = v;
                emit onProgramChanged();
            }, Qt::QueuedConnection);
        }
        if (tally.on_preview != prevPreview) {
            prevPreview = tally.on_preview;
            const bool v = tally.on_preview;
            QMetaObject::invokeMethod(this, [this, v]() {
                if (m_impl->onPreview == v) return;
                m_impl->onPreview = v;
                emit onPreviewChanged();
            }, Qt::QueuedConnection);
        }
    }
}

}  // namespace crater
