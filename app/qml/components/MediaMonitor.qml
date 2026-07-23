import QtQuick
import QtQuick.Window
import QtMultimedia
import Crater

// Reusable media monitor — renders an image or a video at the caller's
// geometry, honoring a fit mode (contain / cover / stretch) and an optional
// normalized crop sub-region. Used by the projection scene, the Preview /
// Live mini-monitors (via ThemedMonitor), and LogoView.
//
// Fit + crop:
//   • fitMode picks how the frame maps to this monitor: "contain"
//     (PreserveAspectFit, letterbox), "cover" (PreserveAspectCrop, fill +
//     clip overflow), or "stretch" (Stretch, aspect ignored). The sentinel
//     "default" resolves to SettingsService.mediaDefaultFit so callers can
//     pass a media item's own fit_mode straight through.
//   • cropRect is a normalized 0..1 sub-region applied BEFORE fit. Identity
//     {0,0,1,1} = whole frame. Images clip via Image.sourceClipRect (exact,
//     crisp). Video has no clip-rect in Qt 6, so a cropped video is rendered
//     through an oversized, offset, clipped VideoOutput that maps the chosen
//     sub-rect onto the monitor (fills the crop box; fit is a no-op once
//     cropped — the crop rectangle defines the framing).
//
// Performance contract:
//   • Videos go through the shared MediaPlaybackService. When two surfaces
//     point at the same source URL — the common case once the operator has
//     gone live — the service runs ONE QMediaPlayer + sink and broadcasts
//     each decoded frame to every attached VideoOutput sink.
//   • Image.sourceSize binds to (width × Screen.devicePixelRatio) so a 4K
//     JPEG decodes only to the resolution actually shown. (The cropped image
//     branch decodes at natural size so its sourceClipRect stays exact.)
//   • The Loader gate keeps non-media items free of any Image or VideoOutput.
//   • Token lifecycle: created on path/kind change, destroyed on the
//     component's destruction or when the path empties. No grace period.
//
// Audio model:
//   • The shared player's audio is muted iff NO subscriber wants audio.
//   • Preview always says "muted: true"; Live says "muted: false" unless the
//     item is force-muted. When both subscribe to the same URL the bus is
//     driven once — no double-routing risk.
//
// Why this design (and not VideoOutput.videoSink binding):
//   In Qt 6 VideoOutput's videoSink is read-only — it creates its own
//   sink internally. The supported way to drive a VideoOutput from
//   shared decoded frames is to push them in via the public
//   QVideoSink::setVideoFrame slot. The service does that for every
//   attached output on every decoded frame.
Item {
    id: root

    // ── Inputs ──────────────────────────────────────────────────────────
    property string mediaKind: ""       // "image" | "video" | "" (inactive)
    property string mediaPath: ""       // absolute file path (no file:/// prefix)
    property bool   muted: true         // preview: true, live: false
    // "contain" | "cover" | "stretch" | "default" (→ SettingsService default).
    property string fitMode: "contain"
    // Normalized 0..1 crop sub-region, applied before fit. Identity = whole frame.
    property rect   cropRect: Qt.rect(0, 0, 1, 1)
    // Video only: restart at end (true) or play once + hold last frame (false).
    property bool   loop: true

    readonly property bool _isMedia:
        mediaPath.length > 0 && (mediaKind === "image" || mediaKind === "video")

    readonly property bool _cropped:
        cropRect.x !== 0 || cropRect.y !== 0
        || cropRect.width !== 1 || cropRect.height !== 1

    // Resolve the effective fit token, mapping the "default" sentinel (and any
    // stray value) onto the global default so the render is always well-defined.
    function _effFit() {
        if (fitMode === "contain" || fitMode === "cover" || fitMode === "stretch")
            return fitMode
        return SettingsService.mediaDefaultFit
    }
    function _imgFill() {
        const f = _effFit()
        return f === "cover"   ? Image.PreserveAspectCrop
             : f === "stretch" ? Image.Stretch
                               : Image.PreserveAspectFit
    }
    function _voFill() {
        const f = _effFit()
        return f === "cover"   ? VideoOutput.PreserveAspectCrop
             : f === "stretch" ? VideoOutput.Stretch
                               : VideoOutput.PreserveAspectFit
    }

    // ── Shared-decoder subscription (videos only) ───────────────────────
    // sharedToken >= 0 when we hold an active subscription. activeUrl
    // tracks which URL we acquired against so we can detect "same URL
    // again" and skip the release/acquire churn.
    //
    // No leading underscore on the property names so QML's auto-generated
    // signal names (sharedTokenChanged) and handlers (onSharedTokenChanged)
    // stay clean — underscore-prefixed properties create awkward handler
    // names in Connections blocks.
    property int    sharedToken: -1
    property string activeUrl: ""

    function _videoUrl() {
        return (mediaKind === "video" && mediaPath.length > 0)
                   ? "file:///" + mediaPath
                   : ""
    }

    function _refreshToken() {
        const url = _videoUrl()
        if (sharedToken >= 0 && activeUrl === url) {
            // Same URL — just sync audio + loop preference instead of re-subbing.
            MediaPlaybackService.setWantsAudio(sharedToken, !muted)
            MediaPlaybackService.setLoop(sharedToken, loop)
            return
        }
        if (sharedToken >= 0) {
            MediaPlaybackService.release(sharedToken)
            sharedToken = -1
            activeUrl   = ""
        }
        if (url.length > 0) {
            sharedToken = MediaPlaybackService.acquire(url, !muted, loop)
            activeUrl   = url
        }
    }

    onMediaPathChanged: Qt.callLater(_refreshToken)
    onMediaKindChanged: Qt.callLater(_refreshToken)
    onMutedChanged: {
        // Cheap path — the service handles a mute flip without churning
        // the player.
        if (sharedToken >= 0) MediaPlaybackService.setWantsAudio(sharedToken, !muted)
    }
    onLoopChanged: {
        // Also cheap — updates the shared player's loop count in place.
        if (sharedToken >= 0) MediaPlaybackService.setLoop(sharedToken, loop)
    }
    Component.onCompleted: _refreshToken()
    Component.onDestruction: {
        if (sharedToken >= 0) MediaPlaybackService.release(sharedToken)
    }

    Loader {
        id: loader
        anchors.fill: parent
        active: root._isMedia
        sourceComponent: root.mediaKind === "video" ? videoComp
                       : root._cropped               ? imageCropComp
                                                     : imageComp
    }

    // ── Image branch (uncropped) ────────────────────────────────────────
    Component {
        id: imageComp
        Image {
            source: "file:///" + root.mediaPath
            fillMode: root._imgFill()
            asynchronous: true
            cache: true
            // DPR-aware texture cap. On a standard 280×158 mini-monitor
            // this decodes to ~280×158 pixels, not the 4K native of the
            // source — ~9× less memory + scanout work on Hi-DPI laptops
            // with 4K source images. width/height read 0 briefly during
            // initial layout; the 512×288 fallback covers that window.
            sourceSize.width:
                width  > 0 ? Math.ceil(width  * Screen.devicePixelRatio) : 512
            sourceSize.height:
                height > 0 ? Math.ceil(height * Screen.devicePixelRatio) : 288
        }
    }

    // ── Image branch (cropped) ──────────────────────────────────────────
    // sourceClipRect (Qt 6.6+) crops in source-pixel space; combined with the
    // fit fillMode the cropped region maps onto the monitor (contain letterboxes
    // any aspect mismatch, cover fills + clips, stretch distorts). Decoded at
    // natural size so the clip coordinates read the true source dimensions.
    Component {
        id: imageCropComp
        Image {
            source: "file:///" + root.mediaPath
            fillMode: root._imgFill()
            asynchronous: true
            cache: true
            sourceClipRect: {
                if (sourceSize.width <= 0 || sourceSize.height <= 0)
                    return Qt.rect(0, 0, 0, 0)
                const c = root.cropRect
                return Qt.rect(c.x * sourceSize.width,
                               c.y * sourceSize.height,
                               c.width  * sourceSize.width,
                               c.height * sourceSize.height)
            }
        }
    }

    // ── Video branch ────────────────────────────────────────────────────
    // VideoOutput owns its own QVideoSink (read-only in Qt 6). The service
    // pushes decoded frames into that sink via setVideoFrame. We attach on
    // creation + on token changes, detach on destruction.
    //
    // Crop: with no source-clip in Qt 6, an oversized + offset + clipped
    // VideoOutput does it. Sizing the output to (box / cropW) × (box / cropH)
    // and offsetting by -cropX/-cropY maps the normalized sub-rect exactly onto
    // the monitor; Stretch fills that oversized output. Aspect stays true when
    // the crop matches the video's aspect (the cropper's 16:9 lock on 16:9
    // footage) — an off-aspect crop of off-aspect footage distorts slightly.
    Component {
        id: videoComp
        Item {
            id: vwrap
            anchors.fill: parent
            clip: root._cropped

            VideoOutput {
                id: vo
                readonly property real _cw: Math.max(0.01, root.cropRect.width)
                readonly property real _ch: Math.max(0.01, root.cropRect.height)
                width:  root._cropped ? vwrap.width  / _cw : vwrap.width
                height: root._cropped ? vwrap.height / _ch : vwrap.height
                x: root._cropped ? -root.cropRect.x * width  : 0
                y: root._cropped ? -root.cropRect.y * height : 0
                fillMode: root._cropped ? VideoOutput.Stretch : root._voFill()

                // Re-attach whenever the upstream token changes (path swap
                // within the same kind). attachOutput is idempotent for
                // same-entry calls and moves the sink for cross-entry ones.
                Connections {
                    target: root
                    function onSharedTokenChanged() {
                        if (vo.videoSink) {
                            if (root.sharedToken >= 0) {
                                MediaPlaybackService.attachOutput(
                                    root.sharedToken, vo.videoSink)
                            } else {
                                MediaPlaybackService.detachOutput(vo.videoSink)
                            }
                        }
                    }
                }

                Component.onCompleted: {
                    if (root.sharedToken >= 0 && vo.videoSink) {
                        MediaPlaybackService.attachOutput(root.sharedToken, vo.videoSink)
                    }
                }
                Component.onDestruction: {
                    if (vo.videoSink) MediaPlaybackService.detachOutput(vo.videoSink)
                }
            }
        }
    }
}
