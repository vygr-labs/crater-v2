import QtQuick
import Crater

// Dedicated NDI render surface. Hosts a ProjectionScene with
// outputKind="ndi" so dual-output mode can broadcast under its own theme
// assignment, independent of what the audience-facing projection window
// is rendering.
//
// Implemented as a hidden Item inside the operator console's
// ApplicationWindow — NOT a separate QQuickWindow. The earlier design
// (standalone Window parked at -32000,-32000 with Qt.Tool) was unreliable
// on Windows: an offscreen window typically never receives an OS expose
// event, so its scene-graph render context is never allocated, so
// `grabToImage()` on items inside it returns null. Receivers saw the
// NDI source on the network but no frames ever arrived. Hosting inside
// the always-visible operator console window guarantees a live render
// context, and `grabToImage` works regardless of where the Item sits
// inside that window.
//
// Visual placement: positioned far outside the operator console's clip
// rect so the operator never sees its pixels. grabToImage doesn't care
// about position — it does an isolated offscreen FBO render of the
// target Item subtree and reads back canvas-native pixels.
//
// `visible: _shouldRender` suspends scene-graph cost when NDI isn't
// broadcasting OR single mode is selected — same gating intent as the
// previous Window.Hidden/Window.Windowed split. Toggling visible flips
// the Item in/out of the scene graph cheaply (no Window allocation
// churn).
Item {
    id: ndiCanvas

    readonly property bool _shouldRender:
        SettingsService.outputMode === "dual" && NdiService.sending

    // External consumers (Main.qml's _updateNdiSource) read this to get
    // the canvas-native Item the NDI grabber should target.
    property alias renderItem: scene.renderItem

    // Canvas-native — ProjectionScene's letterbox/scale collapses to 1:1
    // at this size, so grabbed pixels match theme canvas dimensions
    // exactly (1920×1080 by default; whatever the theme declares).
    width:  1920
    height: 1080

    // Park far outside the operator console's clip rect. The window
    // clips at its own bounds so the operator never sees these pixels.
    x: -3000
    y: -3000

    visible: _shouldRender

    ProjectionScene {
        id: scene
        anchors.fill: parent
        // outputKind="ndi" so resolveItemTheme honors themeIdForNdi when
        // the operator has pinned one — the whole point of dual output.
        outputKind: "ndi"
        // Scene-level hint that mirrors NdiService.blank, so when the
        // operator blanks the broadcast the scene graph also goes to
        // alpha 0 (skips rasterizing the doomed pixels). The real
        // bullet-proof blanking happens at the C++ frame-send boundary
        // inside NdiService::captureFrame / onHeadlessFrame — this
        // binding is the cooperative perf hint, not the mechanism.
        opacity: NdiService.blank ? 0 : 1
    }
}
