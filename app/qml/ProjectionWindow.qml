import QtQuick
import QtQuick.Window
import Crater

// Second-monitor output window. A separate QQuickWindow (NOT inside an
// ApplicationWindow), bound directly to ProjectionService Q_PROPERTYs — when
// projection state changes, Qt's binding engine re-evaluates and this window
// re-renders, no IPC, no Redux, no event bus. See plan's "Deviations from
// Electron" table for the rationale.
//
// As of tokens v2 the theme is a node graph (containers + texts positioned
// by percent on a canvas). This window letterboxes the canvas into the
// screen and Repeats node delegates inside that stage. Per-node fade is
// not animated — the entire content layer fades on go-live/page-change.
Window {
    id: projectionWindow

    // The screen index to target. Main.qml binds this to OutputService.
    property int screenIndex: 0

    // Two orthogonal flags that together define the window's render state:
    //
    //   visibleToOperator | keepRendering | resulting state
    //   ──────────────────┼───────────────┼─────────────────────────────
    //   true              | (don't care)  | shown on display (Windowed
    //                                       or FullScreen per OutputService)
    //   false             | true          | parked offscreen as Qt.Tool —
    //                                       scene graph keeps rendering
    //                                       so NDI / future consumers
    //                                       have fresh frames available
    //   false             | false         | Window.Hidden — scene graph
    //                                       suspended, no resources used
    //
    // Main.qml binds visibleToOperator to AppState.projectorVisible (the
    // operator's "is projection on the audience screen" state) and
    // keepRendering to NdiService.sending (or, in the future, any
    // consumer that needs frames in the background). The window's OS-level
    // visibility, flags, and position derive from these two flags via the
    // _offscreen helper below.
    property bool visibleToOperator: true
    property bool keepRendering: false

    readonly property bool _anyActive: visibleToOperator || keepRendering
    readonly property bool _offscreen: keepRendering && !visibleToOperator

    // Exposes the canvas-native render Item so external consumers (NDI
    // sender today; future recording / multi-output sinks) can grab
    // canvas-resolution frames without going through the window-sized
    // letterbox container. Aliased through ProjectionScene's renderItem
    // (the inner `stage` Item) so this window's renderItem keeps the
    // same identity whether the scene is rendered here or in NdiCanvas.
    property alias renderItem: scene.renderItem

    readonly property var _targetScreen:
        Qt.application.screens[screenIndex] || Qt.application.screens[0]

    readonly property bool _windowed:
        OutputService.projectionMode === OutputService.Windowed

    screen: _targetScreen

    // Detach from the operator console's window family. Without this, Qt
    // makes nested Windows transient children of their declaring ancestor —
    // they share a taskbar slot and inherit z-order quirks. Setting to null
    // gives this window its own taskbar entry on Windows, its own Alt+Tab
    // slot, and lets the operator click back to the console even when the
    // projection is fullscreen on a single-monitor laptop.
    transientParent: null

    // Visibility — three states depending on the two flags above:
    //   • Operator wants projection visible → Windowed or FullScreen per
    //     OutputService.projectionMode
    //   • Operator closed projection but a consumer (NDI) needs frames →
    //     Windowed at an offscreen position (Qt.Tool flag hides it from
    //     taskbar / Alt+Tab); scene graph keeps rendering
    //   • Nothing wants this window → Window.Hidden (suspends scene graph,
    //     reclaims render-thread budget)
    visibility: !_anyActive
        ? Window.Hidden
        : _offscreen
            ? Window.Windowed
            : (_windowed ? Window.Windowed : Window.FullScreen)

    // Flags: standard window in operator-visible production; tool-flagged
    // (no taskbar entry, no Alt+Tab, doesn't accept focus) when parked
    // offscreen for capture-only use. When Hidden, the flags don't matter
    // visually but we still want sensible defaults for the brief moment
    // before/after visibility toggles.
    flags: _offscreen
        ? (Qt.Tool | Qt.FramelessWindowHint | Qt.WindowDoesNotAcceptFocus)
        : _windowed
            ? Qt.Window
            : (Qt.Window | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint)
    title: qsTr("Crater Projection")

    // Geometry. In operator-visible mode: 480×270 windowed thumbnail
    // anchored to the bottom-right of the target screen. In offscreen
    // capture mode: full 1920×1080 (so NDI receivers get canvas-resolution
    // frames) parked way off the virtual desktop. FullScreen visibility
    // overrides these, so unconditional defaults are safe.
    width:  _offscreen ? 1920 : 480
    height: _offscreen ? 1080 : 270
    x: _offscreen
        ? -32000
        : (_targetScreen
            ? _targetScreen.virtualX + _targetScreen.width  - width  - 24
            : 100)
    y: _offscreen
        ? -32000
        : (_targetScreen
            ? _targetScreen.virtualY + _targetScreen.height - height - 24
            : 100)

    // Background color = first container's color, falling back to black.
    // Painted BEFORE the canvas stage so anything outside the letterbox
    // looks intentional (matte black, not theme color stretched).
    color: "#000000"

    // OutputService.projectionOpen tracks the operator-facing axis only —
    // it's "is the audience seeing the projection right now?", independent
    // of whether NDI or any other consumer happens to be rendering the
    // scene in the background.
    onVisibleToOperatorChanged: {
        if (visibleToOperator) OutputService.notifyProjectionOpened()
        else                   OutputService.notifyProjectionClosed()
    }

    // User clicked the close (X) button on the windowed projector. Reject
    // the OS-level close so the nested QQuickWindow object is reused on
    // the next goLive() — calling endLive() routes through projectorVisible,
    // which drives Main.qml's visibility binding to Window.Hidden cleanly.
    onClosing: function(closeEvent) {
        closeEvent.accepted = false
        AppState.endLive()
    }

    // Esc is the universal escape hatch — useful primarily in Fullscreen
    // mode on a single-monitor system, where there's no title bar to click
    // and the operator can otherwise get stuck behind the projection. The
    // Shortcut's default Qt.WindowShortcut context scopes it to this
    // window, so it doesn't fight Main.qml's Esc handler (modals / schedule
    // deselect), which runs in the operator console's scope.
    Shortcut {
        sequence: "Escape"
        onActivated: AppState.endLive()
    }

    // The audience-facing render surface. outputKind="primary" so theme
    // resolution honors themeIdForPrimary. The component encapsulates
    // letterbox + canvas-native stage + content/no-theme/logo layers —
    // see qml/components/ProjectionScene.qml. NdiCanvas mounts the same
    // component with outputKind="ndi" when dual output is on, so NDI
    // renders its own scene with its own theme assignment.
    ProjectionScene {
        id: scene
        anchors.fill: parent
        outputKind: "primary"
    }
}
