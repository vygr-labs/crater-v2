import QtQuick
import Crater

// Pre-service / between-content logo — the placeholder the projection
// shows when AppState.showLogo is on and live content should be hidden.
// Pulls its source from ProjectionService.logoBgPath / logoBgKind and
// renders it through MediaMonitor so image AND video logos work
// uniformly. Falls back to a "CRATER" text placeholder when no logo path
// is configured so toggling logo before picking a file still shows
// something intentional rather than a black square.
//
// Shared by:
//   • ProjectionWindow.qml (full-screen audience-facing logo)
//   • LivePanel.qml mini-monitor (operator-side mirror of the logo)
//
// The `active` flag gates the underlying decoder: a logo that isn't
// currently displayed releases its MediaPlaybackService token so an
// always-loaded LogoView never pins GPU memory.
Item {
    id: root

    // Whether the logo should currently be visible. Callers drive their
    // own opacity transition (e.g. ProjectionWindow's fade) — this flag
    // only governs the decoder lifecycle.
    property bool active: false

    readonly property string _path: ProjectionService.logoBgPath
    readonly property string _kind: ProjectionService.logoBgKind
    readonly property bool _hasPath: _path && _path.length > 0

    // Matte black canvas — matches Electron's LogoBackground (`bg: "black"`)
    // and gives the letterbox bars a deliberate color when the logo
    // aspect doesn't match the surface.
    Rectangle {
        anchors.fill: parent
        color: "#000000"
    }

    // The actual image/video. mediaKind/mediaPath collapse to "" when the
    // logo is inactive or no path is set, which trips MediaMonitor's
    // internal Loader and destroys the player — no idle decoder cost.
    MediaMonitor {
        anchors.fill: parent
        mediaKind: (root.active && root._hasPath) ? root._kind : ""
        mediaPath: (root.active && root._hasPath) ? root._path : ""
        muted: true
        crop:  false
    }

    // Fallback when no logo path is configured. Sized as a fraction of
    // parent.height so the same component reads correctly at projection
    // scale (~1080 -> ~130px) and mini-monitor scale (~180 -> ~22px).
    Text {
        anchors.centerIn: parent
        visible: root.active && !root._hasPath
        text: "CRATER"
        color: "#ffffff"
        font.family: Theme.font.family
        font.pixelSize: Math.max(14, Math.floor(parent.height * 0.12))
        font.weight: 900
        font.letterSpacing: Math.max(2, Math.floor(parent.height * 0.012))
    }
}
