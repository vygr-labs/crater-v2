#include "NdiRenderer.h"

#include <QByteArray>
#include <QDebug>
#include <QElapsedTimer>
#include <QImage>
#include <QOffscreenSurface>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickRenderControl>
#include <QQuickRenderTarget>
#include <QQuickWindow>
#include <QSettings>
#include <QTimer>
#include <QUrl>

#include <rhi/qrhi.h>

#include <algorithm>
#include <array>
#include <numeric>

namespace crater {

namespace {

// Canvas-native render-target size. ProjectionScene's letterbox/scale
// collapses to 1:1 at this size, so the readback pixels match the theme
// canvas dimensions exactly. Themes today are all 1920×1080; parameterise
// this if non-default canvas sizes ever become a use case.
constexpr int kRenderWidth  = 1920;
constexpr int kRenderHeight = 1080;

// Initial render cadence (ms). Adaptive scheduler demotes to 33 ms
// (~30 Hz) when sustained paint cost exceeds budget; promotes back to
// 16 ms (~60 Hz) once cost recovers.
constexpr int kTickIntervalMs60Hz = 16;
constexpr int kTickIntervalMs30Hz = 33;

// Adaptive-scheduler thresholds (paint-cost milliseconds, GUI-thread wall-
// clock for the whole renderTick). Hysteresis between demote and promote
// values prevents oscillation when the cost hovers near the edge.
constexpr qint64 kDemoteAboveMs = 10;
constexpr qint64 kPromoteBelowMs = 6;

// Sample-window sizes. Demotion reacts on the *recent* 30 samples (≈500 ms
// at 60 Hz / 1 s at 30 Hz) so we drop framerate quickly under sustained
// pressure. Promotion needs a longer 60-sample window (≈1 s at 60 Hz /
// 2 s at 30 Hz) — we want strong evidence that the system has stabilised
// before bumping work back up.
constexpr int kCostRingSize    = 60;
constexpr int kDemoteWindow    = 30;
constexpr int kPromoteWindow   = 60;

// On-demand keepalive cadence. When the scene is idle (nothing to render),
// re-send the cached last frame every Nth tick so the NDI receiver (vMix,
// Studio Monitor, …) holds a live source with correct timing rather than
// timing it out. 6 ticks @ 30 Hz ≈ 5 Hz — a re-send only (no render, no
// readback, no color convert), so the cost is negligible.
constexpr int kKeepaliveEveryNTicks = 6;

// On-demand render burst. A scene change arms this many render ticks. We must
// keep rendering for a few ticks AFTER the last change because async readback
// completes on the *next* beginFrame() — a one-shot "render once" would submit
// the changed frame's readback and then go idle before any beginFrame fired it,
// leaving NDI one change behind. A burst longer than the 3-deep readback ring
// guarantees the settled frame flushes all the way out before we idle. At
// 30 Hz this is ~200 ms of rendering after a text advance, then idle.
constexpr int kRenderBurstTicks = 6;

// Inline QML loaded into the headless window. Imports `Crater` so it can
// reference `ProjectionScene` (a type registered into the same module the
// main app uses). `outputKind="ndi"` is the whole reason this scene exists
// — it makes ProjectionScene resolve via the OutputService registry's
// "ndi" OutputBinding (its per-kind theme slots + its transition style /
// duration) in dual mode.
//
// `opacity: NdiService.blank ? 0 : 1` is the cooperative perf hint for the
// blank toggle — when the operator blanks the broadcast, the scene graph
// drops to alpha 0 so the QRhi composer skips most of the rasterization
// work. The actual frame-blanking happens unconditionally at the
// NdiService::onHeadlessFrame intercept downstream, so this binding is
// belt+suspenders, not the mechanism. If singletons aren't ready at
// component creation time (the "Component is not ready" warning at
// startup that has historically been an issue), the binding still
// compiles fine — NdiService is a C++ singleton registered eagerly
// before this engine instantiates any components.
const char* const kSceneQml = R"(
import QtQuick
import Crater
ProjectionScene {
    outputKind: "ndi"
    width: 1920
    height: 1080
    opacity: NdiService.blank ? 0 : 1
}
)";

}  // namespace

struct NdiRenderer::Impl
{
    QQmlEngine*               qmlEngine      = nullptr;

    // Qt objects created in the constructor and reused across start/stop
    // cycles. We never recreate these — only the QRhi resources below
    // are torn down on stop().
    QOffscreenSurface*        offscreen      = nullptr;
    QQuickRenderControl*      renderControl  = nullptr;
    QQuickWindow*             quickWindow    = nullptr;
    QQmlComponent*            sceneComponent = nullptr;
    QQuickItem*               sceneRoot      = nullptr;

    // QRhi resources — created in start(), destroyed in stop(). The QRhi
    // instance itself is owned by QQuickRenderControl and outlives these.
    // Raw pointers because their lifetime is managed manually relative to
    // QRhi's command queue.
    QRhiTexture*              renderTexture        = nullptr;
    QRhiTextureRenderTarget*  renderTarget         = nullptr;
    QRhiRenderPassDescriptor* renderPassDescriptor = nullptr;

    // Triple-buffered readback ring. Each renderTick picks the first
    // Available slot, submits a GPU→CPU copy into it, and marks it
    // InFlight. The QRhi `completed` callback fires on the next
    // beginFrame() boundary; that callback emits frameReady and flips
    // the slot back to Available. Three slots gives us enough pipeline
    // depth to absorb any single-frame GPU stalls without dropping
    // submissions; if all three are in-flight we drop the new tick
    // (natural backpressure).
    enum class SlotState { Available, InFlight };
    std::array<QRhiReadbackResult, 3> readbacks;
    std::array<SlotState, 3>          slotStates {
        SlotState::Available, SlotState::Available, SlotState::Available };
    int                       inFlightCount = 0;

    QTimer                    renderTimer;
    int                       framerateHz = 60;
    bool                      available   = false;
    bool                      running     = false;

    // Adaptive scheduler state. costSamplesMs is a ring of recent paint-
    // cost measurements (whole renderTick wall-clock, GUI thread). We
    // append on every successful frame; demote/promote decisions read
    // back over the kDemoteWindow / kPromoteWindow most-recent samples.
    std::array<qint64, kCostRingSize> costSamplesMs {};
    int                       costIdx     = 0;
    int                       costCount   = 0;

    // On-demand rendering state (opt-in via Settings/ndiOnDemand, read at
    // start()). When `onDemand` is set, renderTick renders only while
    // `renderBudget > 0` — re-armed to kRenderBurstTicks by the renderControl
    // sceneChanged / renderRequested signals — and otherwise re-sends
    // `lastFrame` every kKeepaliveEveryNTicks ticks. `idleTicks` counts ticks
    // since the last send. Capped at 30 Hz (no adaptive promotion) on-demand.
    bool                      onDemand    = false;
    int                       renderBudget = 0;     // render ticks remaining (on-demand)
    int                       idleTicks   = 0;       // ticks since last keepalive send
    QImage                    lastFrame;             // cached for keepalive re-send

    // Reports the QRhi backend Qt picked. Logged on start() so a future
    // bug report can include "we were running on D3D11 / Vulkan / etc."
    // without re-deriving it from Qt's logs.
    QString                   backendName;
};

NdiRenderer::NdiRenderer(QQmlEngine* engine, QObject* parent)
    : QObject(parent)
    , m_impl(std::make_unique<Impl>())
{
    m_impl->qmlEngine = engine;

    // Offscreen surface. Required by QQuickRenderControl on every QRhi
    // backend even when we never present to it — the surface anchors the
    // graphics context creation. defaultFormat() picks up any global tweak
    // (e.g. requested OpenGL version); we don't override anything here.
    m_impl->offscreen = new QOffscreenSurface();
    m_impl->offscreen->setFormat(QSurfaceFormat::defaultFormat());
    m_impl->offscreen->create();

    // Render control + headless QQuickWindow. The window has no native
    // window handle (it's never shown to the OS) but it still owns a
    // scene graph that we drive via the render control's beginFrame /
    // sync / render / endFrame cycle.
    m_impl->renderControl = new QQuickRenderControl(this);
    m_impl->quickWindow   = new QQuickWindow(m_impl->renderControl);
    m_impl->quickWindow->setColor(Qt::black);
    // Logical size only — the window is headless. Setting size on a
    // window without a native handle gives the scene graph a viewport
    // size for `anchors.fill: parent` to resolve against.
    m_impl->quickWindow->setGeometry(0, 0, kRenderWidth, kRenderHeight);

    // Load ProjectionScene via inline QML. We use the shared QQmlEngine
    // so Crater's singletons resolve to the already-registered instances
    // — the NDI scene and the audience scene observe the same
    // ProjectionService state. A second engine would yield a separate
    // SettingsService singleton and the NDI feed would diverge from
    // live operator changes.
    m_impl->sceneComponent = new QQmlComponent(m_impl->qmlEngine, this);
    m_impl->sceneComponent->setData(
        QByteArray(kSceneQml),
        QUrl(QStringLiteral("crater://NdiRenderer/scene.qml")));
    if (m_impl->sceneComponent->isError()) {
        qWarning().noquote() << "NdiRenderer: failed to compile NDI scene QML:"
                             << m_impl->sceneComponent->errorString();
        return;
    }
    QObject* obj = m_impl->sceneComponent->create();
    if (!obj) {
        qWarning().noquote() << "NdiRenderer: failed to create NDI scene:"
                             << m_impl->sceneComponent->errorString();
        return;
    }
    m_impl->sceneRoot = qobject_cast<QQuickItem*>(obj);
    if (!m_impl->sceneRoot) {
        qWarning() << "NdiRenderer: NDI scene root is not a QQuickItem";
        obj->deleteLater();
        return;
    }
    m_impl->sceneRoot->setParentItem(m_impl->quickWindow->contentItem());
    m_impl->sceneRoot->setWidth(kRenderWidth);
    m_impl->sceneRoot->setHeight(kRenderHeight);

    // Render tick — connected here, started in start(). The slot drives
    // the polishItems / beginFrame / sync / render / readback / endFrame
    // cycle for each frame.
    m_impl->renderTimer.setTimerType(Qt::PreciseTimer);
    m_impl->renderTimer.setInterval(kTickIntervalMs60Hz);
    connect(&m_impl->renderTimer, &QTimer::timeout,
            this, &NdiRenderer::renderTick);

    // Dirty tracking for on-demand mode. QQuickRenderControl emits these
    // whenever the scene graph needs a fresh frame — content/property changes
    // (sceneChanged) or a running animation/transition asking to repaint
    // (renderRequested). Each re-arms the render burst; renderTick draws while
    // the budget lasts (on-demand) or ignores it entirely (default path).
    connect(m_impl->renderControl, &QQuickRenderControl::sceneChanged,
            this, [this]() { m_impl->renderBudget = kRenderBurstTicks; });
    connect(m_impl->renderControl, &QQuickRenderControl::renderRequested,
            this, [this]() { m_impl->renderBudget = kRenderBurstTicks; });

    qInfo() << "NdiRenderer: constructed — offscreen surface, render control, "
               "and NDI scene ready";
}

NdiRenderer::~NdiRenderer()
{
    stop();

    // Order matters: invalidate scene graph first so render thread
    // releases all QSGNode references before we delete the QRhi-backed
    // window. delete order then mirrors construction order in reverse.
    if (m_impl->renderControl) {
        m_impl->renderControl->invalidate();
    }
    delete m_impl->sceneRoot;        // owns nothing else here
    delete m_impl->sceneComponent;
    delete m_impl->quickWindow;
    delete m_impl->renderControl;
    if (m_impl->offscreen) {
        m_impl->offscreen->destroy();
    }
    delete m_impl->offscreen;
}

bool NdiRenderer::isAvailable() const { return m_impl->available; }
bool NdiRenderer::isRunning() const   { return m_impl->running; }
int  NdiRenderer::framerate() const   { return m_impl->framerateHz; }

bool NdiRenderer::start()
{
    if (m_impl->running) return true;
    if (!m_impl->renderControl || !m_impl->quickWindow || !m_impl->sceneRoot) {
        qWarning() << "NdiRenderer::start: construction failed earlier — "
                      "cannot start. Caller should fall back to legacy path";
        return false;
    }

    // Initialise the render control. Creates the QRhi (D3D11 on Windows
    // by default in Qt 6.7+) and the scene graph backing resources.
    // Returns false on unsupported hardware or driver init failure.
    if (!m_impl->renderControl->initialize()) {
        qWarning() << "NdiRenderer::start: QQuickRenderControl::initialize() "
                      "failed — falling back to legacy NDI path";
        return false;
    }

    QRhi* rhi = m_impl->quickWindow->rhi();
    if (!rhi) {
        qWarning() << "NdiRenderer::start: no QRhi after initialize() — "
                      "cannot continue";
        m_impl->renderControl->invalidate();
        return false;
    }
    m_impl->backendName = QString::fromLatin1(rhi->backendName());
    qInfo().noquote() << "NdiRenderer: QRhi backend =" << m_impl->backendName;
    if (rhi->backend() != QRhi::D3D11) {
        // Today Crater is Windows-only; D3D11 is the expected QRhi backend.
        // Any other backend means we're on an unfamiliar platform combo —
        // surface it loudly so a regression doesn't go silent.
        qWarning().noquote() << "NdiRenderer: non-D3D11 backend in use ("
                             << m_impl->backendName
                             << "). Untested combination — proceeding but flagging";
    }

    // Render-target texture. RGBA8 because it's universally supported
    // across QRhi backends; we channel-swap to BGRA in the readback
    // completion callback (renderTick()) — that's the format
    // NDIlib_send_video_v2 expects via NDIlib_FourCC_video_type_BGRA.
    m_impl->renderTexture = rhi->newTexture(
        QRhiTexture::RGBA8,
        QSize(kRenderWidth, kRenderHeight),
        /*sampleCount*/ 1,
        QRhiTexture::RenderTarget);
    if (!m_impl->renderTexture->create()) {
        qWarning() << "NdiRenderer::start: failed to create render texture";
        stop();
        return false;
    }

    QRhiColorAttachment color(m_impl->renderTexture);
    m_impl->renderTarget = rhi->newTextureRenderTarget({color});
    m_impl->renderPassDescriptor =
        m_impl->renderTarget->newCompatibleRenderPassDescriptor();
    m_impl->renderTarget->setRenderPassDescriptor(m_impl->renderPassDescriptor);
    if (!m_impl->renderTarget->create()) {
        qWarning() << "NdiRenderer::start: failed to create render target";
        stop();
        return false;
    }

    m_impl->quickWindow->setRenderTarget(
        QQuickRenderTarget::fromRhiRenderTarget(m_impl->renderTarget));

    // Reset readback ring — every slot Available, none in flight.
    for (auto& s : m_impl->slotStates) s = Impl::SlotState::Available;
    m_impl->inFlightCount = 0;

    // Reset adaptive-scheduler state so a previous run's costs don't
    // bleed into this one (e.g. a heavy theme during the last broadcast
    // shouldn't keep us throttled when the operator restarts NDI under a
    // light theme).
    // Read the on-demand toggle fresh on each broadcast start (same lifecycle
    // as useHeadlessNdi — a Settings change applies on the next NDI start, not
    // mid-stream). Read straight from QSettings to avoid coupling the renderer
    // to SettingsService; the key matches SettingsService::kNdiOnDemand.
    {
        QSettings s(QStringLiteral("Voyager Labs"), QStringLiteral("Crater"));
        m_impl->onDemand = s.value(QStringLiteral("Settings/ndiOnDemand"), false).toBool();
    }
    m_impl->renderBudget = kRenderBurstTicks;  // draw the opening frames
    m_impl->idleTicks    = 0;
    m_impl->lastFrame    = QImage();

    m_impl->costSamplesMs.fill(0);
    m_impl->costIdx   = 0;
    m_impl->costCount = 0;
    // On-demand caps at 30 Hz (no promotion); otherwise start at 60 Hz and let
    // the adaptive scheduler demote under load.
    const int startHz = m_impl->onDemand ? 30 : 60;
    if (m_impl->framerateHz != startHz) {
        m_impl->framerateHz = startHz;
        emit framerateChanged();
    }
    m_impl->renderTimer.setInterval(
        m_impl->onDemand ? kTickIntervalMs30Hz : kTickIntervalMs60Hz);

    m_impl->running   = true;
    m_impl->available = true;
    emit availableChanged();

    m_impl->renderTimer.start();

    qInfo().noquote() << "NdiRenderer: started — render target"
                      << kRenderWidth << "x" << kRenderHeight
                      << "@" << m_impl->framerateHz << "Hz";
    return true;
}

void NdiRenderer::stop()
{
    if (!m_impl->running) {
        // Defensive: if start() failed midway, some resources may still
        // exist. Clean them up too.
        delete m_impl->renderTarget;
        m_impl->renderTarget = nullptr;
        delete m_impl->renderPassDescriptor;
        m_impl->renderPassDescriptor = nullptr;
        delete m_impl->renderTexture;
        m_impl->renderTexture = nullptr;
        return;
    }

    m_impl->renderTimer.stop();

    // Flush in-flight GPU work before tearing down resources. QRhi::finish()
    // submits any pending command buffers and waits for the GPU to drain;
    // after it returns, GPU is idle and no command queue holds references
    // to our texture, so destruction is safe.
    //
    // Note: finish() does NOT fire pending readback `completed` callbacks
    // (those fire on the next beginFrame). We deliberately drop those —
    // we're stopping, so we don't care about the last few frames. Clearing
    // each readback's `completed` callback below prevents a future
    // beginFrame() in a restart from firing a callback with a now-stale
    // slot index.
    if (QRhi* rhi = m_impl->quickWindow ? m_impl->quickWindow->rhi() : nullptr) {
        rhi->finish();
    }
    for (auto& r : m_impl->readbacks) {
        r.completed = nullptr;
        r.data.clear();
    }
    for (auto& s : m_impl->slotStates) s = Impl::SlotState::Available;
    m_impl->inFlightCount = 0;

    delete m_impl->renderTarget;
    m_impl->renderTarget = nullptr;
    delete m_impl->renderPassDescriptor;
    m_impl->renderPassDescriptor = nullptr;
    delete m_impl->renderTexture;
    m_impl->renderTexture = nullptr;

    m_impl->running   = false;
    m_impl->available = false;
    emit availableChanged();
    qInfo() << "NdiRenderer: stopped";
}

void NdiRenderer::renderTick()
{
    if (!m_impl->running) return;

    // On-demand: once the render burst from the last scene change is spent,
    // skip the entire render → readback → color-convert → encode chain. Re-send
    // the cached last frame every Nth tick so the NDI receiver keeps the source
    // live. This is the CPU win for static broadcasts (e.g. a dual-output
    // lower-third that only changes on text advance). The budget is re-armed by
    // the renderControl signals wired in the constructor; it's decremented
    // below once we commit to a real render.
    if (m_impl->onDemand && m_impl->renderBudget <= 0) {
        if (!m_impl->lastFrame.isNull()
            && ++m_impl->idleTicks >= kKeepaliveEveryNTicks) {
            m_impl->idleTicks = 0;
            emit frameReady(m_impl->lastFrame);
        }
        return;
    }

    // Backpressure: if the GPU is more than three frames behind, drop
    // this tick. The next completion will free a slot and we'll resume.
    // Without this guard we'd build an unbounded queue of pending
    // readbacks under sustained pressure.
    if (m_impl->inFlightCount >= static_cast<int>(m_impl->readbacks.size())) {
        return;
    }

    // Pick the first Available slot. Guaranteed to find one given the
    // check above.
    int slot = -1;
    for (int i = 0; i < static_cast<int>(m_impl->slotStates.size()); ++i) {
        if (m_impl->slotStates[i] == Impl::SlotState::Available) {
            slot = i;
            break;
        }
    }
    if (slot < 0) return;

    // Committed to rendering this tick — spend one unit of the burst budget.
    // Decrementing here (after the backpressure/slot guards, not at the top)
    // means a tick we *defer* keeps its budget and retries next time. A scene
    // change landing mid-burst re-arms the budget via the renderControl
    // signals, so nothing is lost.
    if (m_impl->onDemand) --m_impl->renderBudget;
    m_impl->idleTicks = 0;

    // Wall-clock the entire render+submit sequence. This is what the
    // adaptive scheduler reads back from: if our GUI thread spends >10 ms
    // per tick at 60 Hz, we're at risk of missing frames, so we demote.
    QElapsedTimer tickTimer;
    tickTimer.start();

    // polishItems before beginFrame — runs QML layout / sizing logic so
    // the scene graph sees the correct geometry on this frame's render.
    m_impl->renderControl->polishItems();

    // QQuickRenderControl::beginFrame() returns void in Qt 6.11; any
    // device-lost / unrecoverable graphics state surfaces via separate
    // signals on the render control, not via the begin call.
    m_impl->renderControl->beginFrame();

    // The sync step transfers QML state changes (property updates, new
    // items, etc.) into the scene graph. render() then records draw
    // commands into the QRhi command buffer.
    m_impl->renderControl->sync();
    m_impl->renderControl->render();

    // Now inside the active frame — attach a readback batch to the same
    // command buffer that just received the render commands. The GPU
    // will execute render → copy-to-CPU as one sequence; the completion
    // callback fires on the *next* beginFrame() (or endOffscreenFrame).
    //
    // commandBuffer() is on QQuickRenderControl, not QQuickWindow — the
    // render control owns the QRhi command buffer for the current
    // frame; the headless window is just the scene-graph host.
    QRhi* rhi = m_impl->quickWindow->rhi();
    QRhiCommandBuffer* cb = m_impl->renderControl->commandBuffer();
    if (rhi && cb) {
        QRhiResourceUpdateBatch* batch = rhi->nextResourceUpdateBatch();
        QRhiReadbackDescription readDesc(m_impl->renderTexture);

        QRhiReadbackResult* result = &m_impl->readbacks[slot];
        // Capture-by-value of slot so the callback survives the next
        // tick reusing this slot. The lambda outlives this function — it
        // sticks to the readback result until QRhi invokes it.
        result->completed = [this, slot]() {
            QRhiReadbackResult& r = m_impl->readbacks[slot];

            // Reset state BEFORE emitting so a synchronous consumer that
            // calls back into start/stop sees a consistent ring.
            m_impl->slotStates[slot] = Impl::SlotState::Available;
            m_impl->inFlightCount = std::max(0, m_impl->inFlightCount - 1);

            if (r.data.isEmpty()) return;

            // The texture was rendered as RGBA8, so the bytes are R-G-B-A
            // in order. Wrap (don't copy) into an RGBA8888 QImage, then
            // convertToFormat to ARGB32 — on little-endian (Windows), that
            // produces bytes in B-G-R-A order, which is exactly the
            // NDIlib_FourCC_video_type_BGRA layout. convertToFormat()
            // returns a deep copy so the new QImage outlives `r.data`
            // even when this slot gets recycled on the next tick.
            const QImage view(
                reinterpret_cast<const uchar*>(r.data.constData()),
                r.pixelSize.width(),
                r.pixelSize.height(),
                r.pixelSize.width() * 4,
                QImage::Format_RGBA8888);
            const QImage bgra = view.convertToFormat(QImage::Format_ARGB32);

            // Cache for the on-demand keepalive re-send. convertToFormat
            // returned a deep copy, so lastFrame owns its pixels independently
            // of the recycled readback slot. Harmless (one ~8 MB frame) when
            // on-demand is off — it's simply never re-sent.
            m_impl->lastFrame = bgra;
            emit frameReady(bgra);
        };

        batch->readBackTexture(readDesc, result);
        cb->resourceUpdate(batch);

        m_impl->slotStates[slot] = Impl::SlotState::InFlight;
        ++m_impl->inFlightCount;
    }

    m_impl->renderControl->endFrame();

    // On-demand mode runs at a fixed 30 Hz cap — skip the adaptive scheduler
    // entirely (no demote/promote). Promotion to 60 Hz would otherwise fire
    // here: a static scene renders cheaply, the cost average drops below the
    // promote threshold, and we'd bump back to 60 — defeating the cap.
    if (m_impl->onDemand) return;

    // ── Adaptive cadence ────────────────────────────────────────────────
    // Record paint cost for this tick and re-evaluate the framerate.
    // Demote on a recent-window (kDemoteWindow) average above the
    // threshold — fast reaction to a heavy theme dropping in. Promote
    // only on a longer-window (kPromoteWindow) average below the lower
    // threshold — slow reaction so we don't flap back to 60 Hz on a
    // single quiet stretch.
    const qint64 elapsedMs = tickTimer.elapsed();
    m_impl->costSamplesMs[m_impl->costIdx] = elapsedMs;
    m_impl->costIdx = (m_impl->costIdx + 1) % kCostRingSize;
    if (m_impl->costCount < kCostRingSize) ++m_impl->costCount;

    auto recentAverage = [this](int n) -> qint64 {
        const int count = std::min(n, m_impl->costCount);
        if (count <= 0) return 0;
        qint64 sum = 0;
        for (int i = 0; i < count; ++i) {
            const int idx = (m_impl->costIdx - 1 - i + kCostRingSize) % kCostRingSize;
            sum += m_impl->costSamplesMs[idx];
        }
        return sum / count;
    };

    if (m_impl->framerateHz == 60 && m_impl->costCount >= kDemoteWindow) {
        const qint64 avg = recentAverage(kDemoteWindow);
        if (avg > kDemoteAboveMs) {
            m_impl->framerateHz = 30;
            m_impl->renderTimer.setInterval(kTickIntervalMs30Hz);
            // Reset the sample buffer so the cost history at the new
            // cadence isn't contaminated by the high-cost 60Hz samples
            // that triggered the demotion.
            m_impl->costCount = 0;
            m_impl->costIdx   = 0;
            qInfo().noquote()
                << "NdiRenderer: demoted to 30 Hz — recent paint cost avg"
                << avg << "ms exceeded" << kDemoteAboveMs << "ms";
            emit framerateChanged();
        }
    } else if (m_impl->framerateHz == 30 && m_impl->costCount >= kPromoteWindow) {
        const qint64 avg = recentAverage(kPromoteWindow);
        if (avg < kPromoteBelowMs) {
            m_impl->framerateHz = 60;
            m_impl->renderTimer.setInterval(kTickIntervalMs60Hz);
            m_impl->costCount = 0;
            m_impl->costIdx   = 0;
            qInfo().noquote()
                << "NdiRenderer: promoted to 60 Hz — paint cost avg"
                << avg << "ms below" << kPromoteBelowMs << "ms over"
                << kPromoteWindow << "frames";
            emit framerateChanged();
        }
    }
}

}  // namespace crater
