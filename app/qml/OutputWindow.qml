import QtQuick
import QtQuick.Window
import Crater

// A window for any output that is NOT the audience projector — a stage /
// confidence monitor, an overflow-room screen, a foyer display. One instance
// per enabled, screen-assigned entry in the OutputService registry; Main.qml
// Repeats them.
//
// Why this is separate from ProjectionWindow rather than a mode on it:
// ProjectionWindow is 250 lines of single-screen safety logic, and every
// line of it exists because the AUDIENCE output shares a machine with the
// console the operator is driving. It demotes itself to a corner preview
// when the projector is unplugged, it drops its always-on-top hint when
// there is only one display, it re-raises the console a tick after going
// live. None of that applies to an output that has been given a display of
// its own by name: it is fullscreen on that display or it does not exist.
// Folding both behaviours into one component would mean re-reading all of
// that reasoning every time either changed.
//
// The one piece of that safety worth keeping is the last-resort case: a
// machine with a single display, where an extra output has nowhere to go
// that is not the operator console. See _windowed below.
Window {
    id: outputWindow

    // Registry id ("stage", "projection-2", …). Everything else derives.
    property string outputId: ""

    // OutputService exposes placement through Q_INVOKABLE functions, not
    // properties, so bindings over them need an explicit dependency to
    // re-evaluate. Same bump-counter pattern ProjectionScene uses for the
    // per-output transition lookups.
    property int _rev: 0
    Connections {
        target: OutputService
        function onOutputsChanged() { outputWindow._rev++ }
        function onScreensChanged() { outputWindow._rev++ }
    }

    readonly property bool _enabled: {
        _rev  // dep
        return OutputService.outputEnabled(outputId)
    }
    readonly property int _screenIndex: {
        _rev  // dep
        return OutputService.screenIndexFor(outputId)
    }
    readonly property string _contentMode: {
        _rev  // dep
        return OutputService.contentMode(outputId)
    }
    readonly property string _displayName: {
        _rev  // dep
        const b = OutputService.output(outputId)
        return (b && b.displayName) || outputId
    }

    readonly property var _targetScreen:
        (_screenIndex >= 0 && _screenIndex < Qt.application.screens.length)
            ? Qt.application.screens[_screenIndex]
            : null

    // Unassigned, disabled, or pointing at a display that is no longer
    // plugged in — all three collapse to "no window". OutputService already
    // resolves screenIndex back to -1 when a remembered display disappears
    // (resolveStrictScreenIndex), so an unplugged stage monitor goes away
    // here and comes back on its own when the cable does.
    readonly property bool _active: _enabled && _targetScreen !== null

    readonly property bool _singleScreen: {
        _rev  // dep
        return OutputService.screens.length <= 1
    }

    // With one display there is nowhere to put an extra output except on top
    // of the operator. Rather than refuse to render (which looks broken while
    // the operator is setting it up on a laptop before the service) it
    // demotes to a corner preview — the same answer ProjectionWindow reaches
    // for the same reason, and enough to confirm the output works.
    readonly property bool _windowed: _singleScreen

    readonly property int _previewWidth: {
        const sw = _targetScreen ? _targetScreen.width : 1920
        return Math.round(Math.max(400, Math.min(800, sw * 0.25)))
    }
    readonly property int _previewHeight: Math.round(_previewWidth * 9 / 16)

    screen: _targetScreen

    // Detached from the console's window family, so this gets its own
    // taskbar slot and the operator can always click back past it.
    transientParent: null

    visibility: !_active
        ? Window.Hidden
        : (_windowed ? Window.Windowed : Window.FullScreen)

    // Always-on-top only when this output owns a display the console is not
    // on. A stage monitor pointed at the console's own screen must stay
    // behind, or it buries the controls the operator needs to drive it —
    // and unlike the audience projector, nothing about an overflow or
    // confidence screen justifies covering the console.
    readonly property bool _ownsItsScreen: {
        _rev  // dep
        if (_targetScreen === null || _singleScreen) return false
        const list = OutputService.screens
        if (_screenIndex < 0 || _screenIndex >= list.length) return false
        return !list[_screenIndex].isPrimary
    }

    flags: _windowed
        ? Qt.Window
        : (Qt.Window | Qt.FramelessWindowHint
           | (_ownsItsScreen ? Qt.WindowStaysOnTopHint : 0))

    title: _displayName

    width:  _windowed ? _previewWidth  : (_targetScreen ? _targetScreen.width  : 1920)
    height: _windowed ? _previewHeight : (_targetScreen ? _targetScreen.height : 1080)
    // Bottom-LEFT for the windowed fallback. ProjectionWindow parks its own
    // single-screen preview bottom-right, so opposite corners keep the two
    // from landing on top of each other without either needing to know how
    // many of the other exist.
    x: _windowed
        ? (_targetScreen ? _targetScreen.virtualX + 24 : 100)
        : (_targetScreen ? _targetScreen.virtualX : 0)
    y: _windowed
        ? (_targetScreen ? _targetScreen.virtualY + _targetScreen.height - height - 24 : 100)
        : (_targetScreen ? _targetScreen.virtualY : 0)

    color: "#000000"

    // Closing the window turns the output off rather than leaving an
    // invisible-but-enabled entry that the settings row still claims is on.
    // Rejecting the OS close keeps this QML object alive so re-enabling it
    // in settings brings the same window back.
    onClosing: function(closeEvent) {
        closeEvent.accepted = false
        OutputService.setOutputEnabled(outputWindow.outputId, false)
    }

    // Escape is the way out of a fullscreen window on a machine where the
    // operator has lost track of which display has focus. Scoped to this
    // window by the default Qt.WindowShortcut context, so it does not fight
    // the console's own Escape handling.
    Shortcut {
        sequence: "Escape"
        onActivated: OutputService.setOutputEnabled(outputWindow.outputId, false)
    }

    // ── Content ─────────────────────────────────────────────────────────
    // Two scenes, one switch. "mirror" reuses ProjectionScene verbatim,
    // which is why a second audience screen costs nothing here: the scene
    // already resolves its own per-kind theme and its own transition style
    // from this output's registry entry. "stage" swaps in the presenter
    // view instead.
    //
    // Loaders rather than two always-built children: only one is ever
    // visible, and building the unused one would keep a second full theme
    // render tree (with its gradient shaders and video decoders) alive on a
    // machine that already has the console and the audience output up.
    // outputKind is bound inside each Component, not assigned in onLoaded.
    // ProjectionScene defaults it to "primary", so a post-load assignment
    // would let the scene resolve one frame against the AUDIENCE output's
    // theme pins and transition before switching to its own -- a visible
    // flash of the wrong theme every time an output is enabled.
    Loader {
        anchors.fill: parent
        active: outputWindow._active && outputWindow._contentMode !== "stage"
        sourceComponent: Component {
            ProjectionScene { outputKind: outputWindow.outputId }
        }
    }

    Loader {
        anchors.fill: parent
        active: outputWindow._active && outputWindow._contentMode === "stage"
        sourceComponent: Component {
            StageScene { outputKind: outputWindow.outputId }
        }
    }
}
