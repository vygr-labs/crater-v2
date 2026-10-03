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

    // The operator console. Main.qml binds it to its root window. Needed to
    // tell whether the output is aimed at the display the console is on, and
    // handed to ProjectionLayering so it knows which HWND to sit under.
    property var consoleWindow: null

    // The output is aimed at the console's own display on a desk that HAS
    // other displays (Settings > Output display set to the console's
    // screen). Compared by name because Qt.application.screens hands out
    // screen-info wrappers rather than the QScreen objects Window.screen
    // reports, so identity is not a safe test. Names are unique per display.
    readonly property bool _onConsoleScreen: {
        const c = consoleWindow ? consoleWindow.screen : null
        const t = _targetScreen
        return !!(c && t && c.name === t.name)
    }

    // The question every shared-display safety rule below actually asks:
    // "would a fullscreen output land on top of the console?" That is true
    // with one display, and ALSO with several when the output is pointed at
    // the console's screen. Gating on display count alone (the old
    // _singleScreen test) missed the second case: two monitors with the
    // output set to the console's monitor got the multi-display treatment, a
    // fullscreen ALWAYS-ON-TOP window over the console, and Main.qml's
    // raise-the-console fallback skipped it because there was more than one
    // screen. Public so Main.qml applies the same test.
    readonly property bool sharesConsoleScreen: _singleScreen || _onConsoleScreen

    // Fullscreen is only ever safe when the audience output has a screen to
    // itself. Sharing one, a fullscreen projector covers the console the
    // operator is driving — and the failure is worst exactly when it hurts
    // most: HDMI pulled mid-service, the window follows onto the laptop
    // panel, and the operator is left clicking at an output they can't drive.
    //
    // So a shared screen demotes the projector to the windowed preview: a
    // small titled sub-window in the corner. This is an override of the
    // render state, NOT a write to OutputService.projectionMode — the
    // operator's stored Fullscreen preference is untouched, so plugging the
    // display back in (or pointing the output at another screen)
    // re-evaluates this to false and fullscreen returns on its own.
    // …unless the operator picked the other shared-screen mode. See
    // _layeredBehind: the full-size output sits under the console instead
    // of shrinking into a corner, so it cannot bury the controls either way.
    readonly property bool _windowedForced:
        sharesConsoleScreen && !SettingsService.projectionBehindConsole

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

    // The shared-screen mode selector. When the output shares the console's
    // display there are two ways to keep it from burying the console, and
    // they suit different desks:
    //
    //   off (default) — demote to a small windowed preview in the corner,
    //     floating above the console. Always visible, but a thumbnail.
    //
    //   on — the EasyWorship 7 arrangement. A borderless window the size of
    //     the screen, stacked directly UNDER the console. The operator sees
    //     the real output wherever the console does not cover the screen
    //     (restore the console, or snap it to half the screen with
    //     Win+Left). A click on that visible output brings it in front. A
    //     second click, Escape, Alt-Tab or clicking anything else puts it
    //     back behind.
    //
    // The z-order rules live in C++ (app/src/ProjectionLayering.h) because
    // Windows has no "stay under this window" state for Qt flags to ask for.
    // The previous attempt here used Window.FullScreen plus
    // Qt.WindowStaysOnBottomHint. Entering the fullscreen state re-stacks
    // the window to the top on Windows, and the bottom hint let a click hand
    // keyboard focus to an output pinned out of sight, so Escape went
    // nowhere the operator could see.
    //
    // A fullscreen audience output that has a display to itself is not
    // affected and keeps WindowStaysOnTopHint, or any notification toast
    // lands in front of the congregation.
    //
    // _layeredBehind ignores _offscreen on purpose. ProjectionLayering is
    // on whenever this mode applies, NDI parking included, so the
    // show-without-activating request is already in place before go-live
    // moves the window onscreen. A window parked at -32000 is unaffected by
    // being stacked under the console.
    readonly property bool _layeredBehind:
        sharesConsoleScreen
        && SettingsService.projectionBehindConsole
        && OutputService.projectionMode !== OutputService.Windowed
    readonly property bool _belowConsole: _layeredBehind && !_offscreen

    on_LayeredBehindChanged: ProjectionLayering.setBehindConsole(_layeredBehind)
    onConsoleWindowChanged:  ProjectionLayering.attach(projectionWindow, consoleWindow)
    Component.onCompleted: {
        ProjectionLayering.attach(projectionWindow, consoleWindow)
        ProjectionLayering.setBehindConsole(_layeredBehind)
    }

    screen: _targetScreen

    // Detach from the operator console's window family. Without this, Qt
    // makes nested Windows transient children of their declaring ancestor —
    // they share a taskbar slot and inherit z-order quirks. Setting to null
    // gives this window its own taskbar entry on Windows, its own Alt+Tab
    // slot, and lets the operator click back to the console even when the
    // projection is fullscreen on a single-monitor laptop. Behind-the-console
    // mode depends on it too: Windows always stacks an owned window above
    // its owner, so a transient child of the console could never sit under it.
    transientParent: null

    // Visibility — three states depending on the two flags above:
    //   • Operator wants projection visible → Windowed or FullScreen per
    //     OutputService.projectionMode. Behind-the-console is Windowed,
    //     borderless at the screen's full size (see the geometry below),
    //     because entering Window.FullScreen re-stacks it above the console.
    //   • Operator closed projection but a consumer (NDI) needs frames →
    //     Windowed at an offscreen position (Qt.Tool flag hides it from
    //     taskbar / Alt+Tab); scene graph keeps rendering
    //   • Nothing wants this window → Window.Hidden (suspends scene graph,
    //     reclaims render-thread budget)
    visibility: !_anyActive
        ? Window.Hidden
        : _offscreen
            ? Window.Windowed
            : ((_windowed || _belowConsole) ? Window.Windowed : Window.FullScreen)

    // Flags: standard window in operator-visible production; tool-flagged
    // (no taskbar entry, no Alt+Tab, doesn't accept focus) when parked
    // offscreen for capture-only use. When Hidden, the flags don't matter
    // visually but we still want sensible defaults for the brief moment
    // before/after visibility toggles.
    flags: _offscreen
        ? (Qt.Tool | Qt.FramelessWindowHint | Qt.WindowDoesNotAcceptFocus)
        : _windowed
            ? _windowTypeFlag
            // Full size, two ways:
            //
            //   own display — the audience output owns the always-on-top
            //     layer so nothing can pop over it mid-service.
            //   shared with the console — NEVER topmost. Only reachable in
            //     behind-the-console mode (_windowedForced demotes the rest),
            //     where ProjectionLayering keeps it stacked under the console.
            //     No Qt.WindowStaysOnBottomHint either: Qt re-applies it as
            //     HWND_BOTTOM on every re-stack, which would also undo the
            //     click that brings the output forward.
            //
            // _windowTypeFlag (Qt.Window unless the operator hid it from
            // Alt-Tab) keeps a taskbar entry in every case.
            : (_windowTypeFlag | Qt.FramelessWindowHint
               | (sharesConsoleScreen ? 0 : Qt.WindowStaysOnTopHint))
    title: qsTr("Crater Projection")

    // Geometry — three cases, matching the visibility states above:
    //   • offscreen capture → full 1920×1080 (canvas-resolution NDI
    //     frames) parked way off the virtual desktop.
    //   • windowed, operator-visible → 480×270 thumbnail anchored to the
    //     bottom-right of the target screen.
    //   • fullscreen or behind-the-console, operator-visible → the target
    //     screen's full geometry. Window.FullScreen visibility alone is NOT enough —
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
    // mode on a shared screen, where there's no title bar to click and the
    // operator can otherwise get stuck behind the projection. The
    // Shortcut's default Qt.WindowShortcut context scopes it to this
    // window, so it doesn't fight Main.qml's Esc handler (modals / schedule
    // deselect), which runs in the operator console's scope.
    //
    // Behind-the-console mode is the exception: there Escape means "back to
    // the console", not "stop projecting". The output only ever has focus
    // after the operator brought it forward, and taking the audience screen
    // down is not what they asked for. The console's Go Live / End Live
    // button still stops it.
    Shortcut {
        sequence: "Escape"
        onActivated: {
            if (projectionWindow._belowConsole) ProjectionLayering.sendBehind()
            else                                AppState.endLive()
        }
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

    // Behind-the-console only: a click on the output once it is in front
    // sends it back and re-activates the console. The click that brought it
    // forward lands here too, and ProjectionLayering skips that one. Above
    // the scene so nothing in it can swallow the click. Disabled in every
    // other mode, where the output has no click behaviour at all.
    MouseArea {
        anchors.fill: parent
        enabled: projectionWindow._belowConsole
        acceptedButtons: Qt.LeftButton
        onClicked: ProjectionLayering.outputClicked()
    }
}
