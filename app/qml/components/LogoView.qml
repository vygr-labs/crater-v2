import QtQuick
import Crater

// Pre-service / between-content logo — the placeholder the projection
// shows when AppState.showLogo is on and live content should be hidden.
// Pulls its source from ProjectionService.logoBgPath / logoBgKind and
// renders it through MediaMonitor so image AND video logos work
// uniformly. Falls back to the Crater mark when no logo path is
// configured so toggling logo before picking a file still shows
// something intentional rather than a black square.
//
// Shared by:
//   • ProjectionWindow.qml (full-screen audience-facing logo)
//   • LivePanel.qml mini-monitor (operator-side mirror of the logo)
//
// The `active` flag gates the video decoder: a video logo that isn't
// currently displayed releases its MediaPlaybackService token so an
// always-loaded LogoView never pins a decoder. Picture logos are the
// opposite: they stay decoded (at screen size, MediaMonitor caps it)
// whenever a logo is set, because decoding on demand meant the fade-in
// showed the black matte until a large photo finished loading. `ready`
// tells the caller when it is safe to fade in.
Item {
    id: root

    // Whether the logo should currently be visible. Callers drive their
    // own opacity transition (e.g. ProjectionWindow's fade) — this flag
    // only governs the decoder lifecycle.
    property bool active: false

    readonly property string _path: ProjectionService.logoBgPath
    readonly property string _kind: ProjectionService.logoBgKind
    readonly property bool _hasPath: _path && _path.length > 0
    readonly property bool _isImage: _kind === "image"
    // Safe to show: the picture is decoded, or there is nothing to wait for
    // (video, or the Crater mark placeholder).
    readonly property bool ready: !_hasPath || !_isImage || monitor.imageReady

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
        id: monitor
        anchors.fill: parent
        // Pictures preload while a path is set. Video only runs while active.
        readonly property bool _load: root._hasPath && (root._isImage || root.active)
        mediaKind: _load ? root._kind : ""
        mediaPath: _load ? root._path : ""
        muted: true
        // Logos always letterbox on the black matte above — a fixed "contain"
        // regardless of the operator's global media-fit default, so a logo is
        // never cropped or stretched.
        fitMode: "contain"
    }

    // Fallback when no logo path is configured. Sized as a fraction of
    // parent.height so the same component reads correctly at projection
    // scale (~1080 -> ~225px) and mini-monitor scale (~180 -> ~38px).
    // sourceSize follows the drawn size so the SVG rasterizes sharp at
    // either scale instead of being scaled up from its 32-unit viewBox.
    Image {
        readonly property int _size: Math.max(24, Math.round(parent.height * 0.21))
        anchors.centerIn: parent
        visible: root.active && !root._hasPath
        source: "qrc:/brand/crater-mark.svg"
        width: _size
        height: _size
        sourceSize.width: _size
        sourceSize.height: _size
        fillMode: Image.PreserveAspectFit
        smooth: true
        antialiasing: true
    }
}
