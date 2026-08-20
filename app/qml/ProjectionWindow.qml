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

    // Windowed when the operator picked it, and unconditionally when the
    // audience has no display of its own (see _windowedForced).
    readonly property bool _windowed:
        OutputService.projectionMode === OutputService.Windowed
        || _windowedForced

    // True when this machine has no display other than the one the operator
    // console is on — either it never had a second one, or the cable just
    // came out mid-service. Sourced from OutputService rather than
    // Qt.application.screens because OutputService rebuilds on screenAdded /
    // screenRemoved / primaryScreenChanged, so this re-evaluates the moment
    // a display appears or disappears.
    readonly property bool _singleScreen: OutputService.screens.length <= 1

    // Fullscreen is only ever safe when the audience output has a screen to
    // itself. With one display, a fullscreen projector covers the console the
    // operator is driving — and the failure is worst exactly when it hurts
    // most: HDMI pulled mid-service, the window follows onto the laptop
    // panel, and the operator is left clicking at an output they can't drive.
    //
    // Dropping WindowStaysOnTopHint (the previous mitigation, still in the
    // flags below) was not enough. It lets the console come forward, but only
    // once something raises it, and nothing did on cable removal — the raise
    // in Main.qml hangs off go-live. The window also keeps a fullscreen
    // footprint, so every stray click lands on the audience output.
    //
    // So a single screen demotes the projector to the windowed preview: a
    // small titled sub-window in the corner, the way EasyWorship shows its
    // output when there is nowhere else to put it. This is an override of the
    // render state, NOT a write to OutputService.projectionMode — the
    // operator's stored Fullscreen preference is untouched, so plugging the
    // display back in re-evaluates this to false and fullscreen returns on
    // its own.
    readonly property bool _windowedForced: _singleScreen

    // Size of the windowed preview. This used to be a flat 480x270, which
    // was fine while windowed mode was an occasional choice on a 1080p
    // desk. It is not fine now that a single-screen console lives in this
    // mode for the whole service: on a 4K panel 480 px is a postage stamp,
    // and the preview is the only view of the audience output there is.
    //
    // A quarter of the target display, floored so it stays legible on a
    // 1366-wide laptop and capped so it stays a glanceable thumbnail rather
    // than a second console on an ultrawide. The arithmetic lands on
    // exactly 480x270 at 1920 wide, so nothing moves on the display this
    // was designed against.
    readonly property int _previewWidth: {
        const sw = _targetScreen ? _targetScreen.width : 1920
        return Math.round(Math.max(400, Math.min(800, sw * 0.25)))
    }
    readonly property int _previewHeight: Math.round(_previewWidth * 9 / 16)

    // Base window-type flag for the operator-visible states. Qt.Window gives
    // the projection its own taskbar button + Alt-Tab slot; Qt.Tool
    // (WS_EX_TOOLWINDOW on Windows) hides it from BOTH so a fixed projector
    // stops cluttering the switcher. Driven by SettingsService.projectionInAltTab.
    // (The offscreen-NDI branch below stays Qt.Tool unconditionally — it's
    // never meant to be operator-visible regardless of this preference.)
    readonly property int _windowTypeFlag:
        SettingsService.projectionInAltTab ? Qt.Window : Qt.Tool

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
            ? _windowTypeFlag
            // Fullscreen production. On a multi-monitor rig the audience output
            // owns the always-on-top layer so nothing can pop over it. On a
            // SINGLE screen we drop that hint (see _singleScreen) so the
            // projector sits behind the console rather than burying it; the
            // _windowTypeFlag (Qt.Window unless the operator hid it from
            // Alt-Tab) keeps a taskbar entry so they can still surface it.
            : (_windowTypeFlag | Qt.FramelessWindowHint
               | (_singleScreen ? 0 : Qt.WindowStaysOnTopHint))
    title: qsTr("Crater Projection")

    // Geometry — three cases, matching the visibility states above:
    //   • offscreen capture → full 1920×1080 (canvas-resolution NDI
    //     frames) parked way off the virtual desktop.
    //   • windowed, operator-visible → 480×270 thumbnail anchored to the
    //     bottom-right of the target screen.
    //   • fullscreen, operator-visible → the target screen's full
    //     geometry. Window.FullScreen visibility alone is NOT enough —
    //     these are live bindings and the _offscreen term re-fires them
    //     the instant the operator goes live, so a fixed 480×270 actively
    //     fights the fullscreen state. The binding must AGREE with it.
    width: _offscreen ? 1920
         : _windowed  ? _previewWidth
         : (_targetScreen ? _targetScreen.width : 1920)
    height: _offscreen ? 1080
          : _windowed  ? _previewHeight
          : (_targetScreen ? _targetScreen.height : 1080)
    x: _offscreen ? -32000
     : !_windowed ? (_targetScreen ? _targetScreen.virtualX : 0)
     : (_targetScreen
         ? _targetScreen.virtualX + _targetScreen.width  - width  - 24
         : 100)
    y: _offscreen ? -32000
     : !_windowed ? (_targetScreen ? _targetScreen.virtualY : 0)
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
    // resolution honors the "primary" OutputBinding's per-kind slots in
    // OutputService. The component encapsulates letterbox + canvas-native
    // stage + content/no-theme/logo layers — see qml/components/
    // ProjectionScene.qml. NdiCanvas mounts the same component with
    // outputKind="ndi" when dual output is on, so NDI renders its own
    // scene with its own per-kind theme assignment.
    ProjectionScene {
        id: scene
        anchors.fill: parent
        outputKind: "primary"
    }
}
