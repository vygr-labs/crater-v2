import QtQuick
import QtQuick.Window
import QtMultimedia
import Crater

// Reusable media monitor — renders an image or a looping video at the
// caller's geometry. Used by the Preview and Live mini-monitors today;
// the projection window will use the same component in a follow-up.
//
// Performance contract:
//   • Videos go through the shared MediaPlaybackService. When Preview
//     and Live point at the same source URL — the common case after the
//     operator goes live — the service runs ONE QMediaPlayer + sink and
//     broadcasts each decoded frame to every attached VideoOutput sink.
//     Half the decoder cost when both panels show the same clip.
//   • Image.sourceSize binds to (width × Screen.devicePixelRatio) so a
//     4K JPEG decodes only to the resolution actually shown.
//   • The Loader gate keeps non-media items free of any Image or
//     VideoOutput — the component is "empty" until a real media path
//     arrives.
//   • Token lifecycle: created on path/kind change, destroyed on the
//     component's destruction or when the path empties. No grace period.
//
// Audio model:
//   • The shared player's audio is muted iff NO subscriber wants audio.
//   • Preview always says "muted: true" → contributes nothing to the
//     audio bus. Live says "muted: false" → audio plays. When both
//     subscribe to the same URL the bus is driven once and routed to
//     the system audio device — no double-routing risk.
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
    property bool   crop: false         // false = PreserveAspectFit, true = Crop

    readonly property bool _isMedia:
        mediaPath.length > 0 && (mediaKind === "image" || mediaKind === "video")

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
            // Same URL — just sync audio preference instead of re-subbing.
            MediaPlaybackService.setWantsAudio(sharedToken, !muted)
            return
        }
        if (sharedToken >= 0) {
            MediaPlaybackService.release(sharedToken)
            sharedToken = -1
            activeUrl   = ""
        }
        if (url.length > 0) {
            sharedToken = MediaPlaybackService.acquire(url, !muted)
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
    Component.onCompleted: _refreshToken()
    Component.onDestruction: {
        if (sharedToken >= 0) MediaPlaybackService.release(sharedToken)
    }

    Loader {
        id: loader
        anchors.fill: parent
        active: root._isMedia
        sourceComponent: root.mediaKind === "video" ? videoComp : imageComp
    }

    // ── Image branch ────────────────────────────────────────────────────
    Component {
        id: imageComp
        Image {
            source: "file:///" + root.mediaPath
            fillMode: root.crop ? Image.PreserveAspectCrop
                                : Image.PreserveAspectFit
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

    // ── Video branch ────────────────────────────────────────────────────
    // VideoOutput owns its own QVideoSink (read-only in Qt 6). The
    // service pushes decoded frames into that sink via setVideoFrame.
    // We attach on creation + on token changes, detach on destruction.
    Component {
        id: videoComp
        VideoOutput {
            id: vo
            anchors.fill: parent
            fillMode: root.crop ? VideoOutput.PreserveAspectCrop
                                : VideoOutput.PreserveAspectFit

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
