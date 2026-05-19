# Render Pipeline Decouple

> Headless QRhi-based capture for the NDI broadcast path. Phase 1 — NDI only.

## Why

NDI broadcast captures pixels from a Qt scene-graph and pushes them onto the
local network. The first iteration of this pipeline grabbed frames via
`QQuickItem::grabToImage()` on a scene hosted inside a real `QQuickWindow`
(initially `ProjectionWindow`; later, a hidden `NdiCanvas` Item inside the
operator console window). That works on the happy path but is fragile:
`grabToImage` only succeeds when the source `QQuickWindow` has been
*exposed* by the OS compositor — which on Windows is unreliable for
offscreen windows (DWM may not allocate a render context for a window
positioned outside the visible desktop, depending on driver, screensaver
state, RDP, etc.). The class of bug surfaces as *"NDI source appears on
the network but no frames flow."*

The headless path removes the OS window from the capture dependency chain
entirely. We render the NDI scene into a `QRhiTexture` we own, using
`QQuickRenderControl` to drive a `QQuickWindow` that's never shown to the
OS. Async readback via `QRhi::nextResourceUpdateBatch().readBackTexture`
delivers BGRA pixels to the NDI sender without touching the OS
compositor at all.

## Architecture

```
   ┌───────────────────────────────┐
   │  ProjectionScene.qml          │
   │  outputKind="ndi"             │   loaded via QQmlComponent into the
   └──────────────┬────────────────┘   shared QQmlApplicationEngine so
                  │                     Crater singletons (Theme,
                  │                     SettingsService, ProjectionService,
                  │                     AppState) resolve to the same
                  │                     instances the UI uses.
   ┌──────────────▼────────────────┐
   │  NdiRenderer                  │   GUI thread, single-threaded QRC.
   │   ├─ QOffscreenSurface        │
   │   ├─ QQuickRenderControl      │   beginFrame / sync / render /
   │   ├─ QQuickWindow (headless)  │     endFrame cycle from a QTimer.
   │   ├─ QRhiTexture (RGBA8 RT)   │
   │   ├─ AdaptiveScheduler        │   60→30 Hz hysteresis on observed
   │   │                           │     GUI-thread paint cost.
   │   └─ Async readback ring      │   triple-buffered QRhiReadbackResult;
   │      (3 × QRhiReadbackResult) │     completion fires on the next
   │                               │     beginFrame() boundary.
   └──────────────┬────────────────┘
                  │ QImage (BGRA, canvas-native 1920×1080)
                  │ — frameReady signal
   ┌──────────────▼────────────────┐
   │  NdiService                   │
   │   onHeadlessFrame()           │   ping-pong frame buffer; hands
   │   → fn_send_video_async_v2    │     dst.bits() to NDI SDK.
   └──────────────┬────────────────┘
                  │
              NDI network
```

### Why a hidden `QQuickWindow` rather than no window at all?

`QQuickRenderControl` needs a `QQuickWindow` to attach the scene graph to.
Qt 6.7+ supports headless `QQuickWindow`s (no native window handle,
visibility never goes to the OS). The `QQuickRenderControl` drives the
scene graph's render cycle manually rather than relying on the
compositor's expose events — which is exactly what makes the path
robust.

### Why one `QQmlEngine` shared with the main app?

Crater's services (`Theme`, `SettingsService`, `ProjectionService`,
`AppState`, …) are QML singletons registered via
`qmlRegisterSingletonInstance`. A second `QQmlEngine` would yield
*duplicate* singleton instances that observe a different state graph.
The NDI scene would diverge from operator-visible state immediately
(operator clicks "go live" — the projection updates, but the NDI scene
sees an unchanged `ProjectionService.currentItem`). Sharing the engine
costs nothing and keeps state consistent.

## Adaptive scheduling

The render tick runs at 60 Hz by default. After every render, the
renderer records the wall-clock cost of the tick (polishItems through
endFrame) into a 60-sample ring. Two thresholds drive transitions:

| State | Trigger | Action |
|-------|---------|--------|
| 60 Hz, recent-30 avg > 10 ms | Sustained pressure | Demote to 30 Hz; reset sample ring |
| 30 Hz, recent-60 avg < 6 ms | System recovered | Promote to 60 Hz; reset sample ring |

The asymmetric windows are intentional: demote on a *short* window
(react fast to a heavy theme dropping in) but promote on a *long* one
(don't flap back to 60 Hz on a brief quiet stretch). The hysteresis
between 10 ms (demote) and 6 ms (promote) means brief excursions don't
oscillate the cadence.

## Files

### Created

| File | Purpose |
|------|---------|
| `qt/app/src/NdiRenderer.h` / `.cpp` | The headless renderer itself. Public API: `start()`, `stop()`, `frameReady(QImage)` signal, `available` / `framerate` Q_PROPERTYs. |
| `qt/docs/render-pipeline-decouple.md` | This document. |

### Modified

| File | Change |
|------|--------|
| `qt/core/include/crater/SettingsService.h` + `.cpp` | Added `useHeadlessNdi` Q_PROPERTY (bool, default true). Mirrors the existing `outputMode` plumbing — Q_PROPERTY, `kUseHeadlessNdi` QSettings key, constructor load, setter with equality guard + signal. |
| `qt/app/qml/dialogs/settings/NdiSection.qml` | Added a `ToggleSwitch` row under "Dual output mode" that binds to `SettingsService.useHeadlessNdi`. User-facing fallback if a particular GPU misbehaves with QRhi readback. |
| `qt/app/src/NdiService.h` + `.cpp` | Added `setRenderer(NdiRenderer*)`. `start()` now reads `Settings/useHeadlessNdi` via `QSettings` directly and routes through either path; `stop()` tears down whichever path was actually used (tracked in `Impl::usingHeadless`). New private slot `onHeadlessFrame(const QImage&)` mirrors the legacy `captureFrame()` ping-pong-and-send sequence, just sourced from `NdiRenderer::frameReady` instead of `grabToImage`. |
| `qt/app/src/main.cpp` | Instantiates `NdiRenderer` (with `&engine`) *after* `engine.loadFromModule("Crater", "Main")` returns — the renderer's inline scene QML does `import Crater`, which requires the module to be registered. Wires it into `ndiService` via `setRenderer()`. |
| `qt/app/CMakeLists.txt` | Added `src/NdiRenderer.cpp` + `.h` to the executable sources. |

### Left alone

| File | Why |
|------|-----|
| `qt/app/qml/NdiCanvas.qml` | Still used by the legacy `grabToImage` path when `useHeadlessNdi` is false. Removed in a follow-up once the headless path has soaked for a release or two. |
| `qt/app/qml/Main.qml` | The `ndiCanvas` instantiation and `_updateNdiSource()` plumbing are still required by the legacy path. |
| `qt/app/qml/ProjectionWindow.qml` | The audience-facing pipeline is the load-bearing user-facing surface. Out of scope for this phase — see "Future phases" below. |

## Threading

GUI thread only. `QQuickRenderControl` runs synchronously on the calling
thread; the render `QTimer` ticks at 16 ms (60 Hz) or 33 ms (30 Hz). All
QRhi command submission happens on the GUI thread; the GPU side is
implicitly threaded by the driver. Async readback completion callbacks
fire from `QRhi::beginFrame()` of the *next* tick — also GUI thread, so
the `frameReady` signal handler in `NdiService` runs there too without
any cross-thread coordination.

Moving render to a worker thread is a known follow-up — see Future phases.

## QRhi backend

Crater is Windows-only today. Qt 6.7+ defaults to **D3D11** on Windows
via QRhi; `NdiRenderer::start()` logs a `qWarning` if a different
backend got picked, so a regression doesn't go silent.

## Verification

After building, verify in the following order. The QSettings flag
`SettingsService.useHeadlessNdi` (default true) is toggleable via NDI
section in the Settings dialog.

### Functional

1. **Flag ON, single mode**: Start NDI broadcast. Open OBS / NDI Studio
   Monitor. Source appears; frames flow at 60 Hz (visible in OBS source
   stats). Close audience view — frames continue.
2. **Flag ON, dual mode**: Same as above. Pin a different theme to NDI in
   ThemesTab. Verify NDI shows the NDI-pinned theme while audience view
   (if open) shows the primary-pinned theme.
3. **Flag toggle mid-session**: Broadcasting with flag ON, flip the flag
   OFF in Settings. Stop and restart broadcast — legacy path engages.
   Flip back ON. Stop+restart — headless path resumes.
4. **Adaptive demotion**: temporarily add `QThread::msleep(20)` inside
   `NdiRenderer::renderTick()`. Confirm scheduler demotes to 30 Hz
   within ~1 second (log line: "demoted to 30 Hz — recent paint cost
   avg X ms"). Remove the sleep; confirm re-promotion.
5. **Resource cleanup**: Start/stop broadcast 10 times. Process working
   set should plateau, not grow.

### Regression

6. **Flag OFF**: NDI works exactly as the pre-decouple `NdiCanvas`
   architecture did.
7. **Projection window**: Audience view in single AND dual mode displays
   correctly. No artifacts, no framerate regression.
8. **App shutdown**: Close app while NDI is broadcasting. No crashes;
   `qInfo` log includes "NdiRenderer: stopped" cleanly.

### Performance

9. **CPU usage**: Compare CPU usage between flag ON and flag OFF during
   steady-state broadcast. Flag ON should be *lower* (async readback
   eliminates the GUI-thread block on `grabToImage`).
10. **Framerate**: OBS should report ~60 FPS for the headless path
    (or 30 FPS under sustained adaptive demotion).

## Future phases

The architecture is intentionally extensible. Each item below reuses or
extends `NdiRenderer` rather than replacing it.

| Phase | Description | Touches |
|-------|-------------|---------|
| **NV12 conversion on GPU** | Shader-based BGRA→NV12 in the readback path. Saves NDI SDK from CPU-side color conversion on every frame. Half a day of QRhi shader work. | `NdiRenderer.cpp` only |
| **Threaded QRC** | Move `render()` to a worker thread. Defer until GUI-thread budget pressure shows up in profiling. | `NdiRenderer.cpp`; coordination with QML state changes |
| **Shared render pass for projection + NDI** | A single scene-graph traversal feeding both the audience window and NDI. Eliminates double-rendering in dual mode. Touches the audience pipeline so deserves its own verification matrix. | `ProjectionWindow.qml`, `NdiRenderer.*`, new shared `HeadlessScene` abstraction |
| **Recording to MP4** | Clones the `NdiRenderer` pattern with an encoder consumer instead of an NDI sender. At this point a shared `HeadlessScene` extraction makes sense — currently folded into `NdiRenderer` per YAGNI. | New `RecordingService.*`, extract `HeadlessScene` |
| **Stage Monitor** | Second visible consumer of the shared scene — a third window showing the NDI-themed scene on a secondary monitor for the stage team. | New `StageMonitorWindow.qml`, consumes the shared FBO |
| **RTMP streaming** | Third capture consumer; encodes and pushes to an RTMP server. Same pattern as Recording but with a network sink. | New `RtmpService.*` |
| **Remove legacy fallback** | Delete `NdiCanvas.qml`, the `_updateNdiSource()` plumbing in `Main.qml`, and the `setSourceWindow`/`setSourceItem`/`captureFrame` codepaths in `NdiService`. Done once headless has soaked in production for a release or two with no fallback toggles observed in user telemetry. | `NdiCanvas.qml` (delete), `Main.qml`, `NdiService.*` |
