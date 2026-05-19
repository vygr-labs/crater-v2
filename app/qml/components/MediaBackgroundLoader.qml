import QtQuick
import QtQuick.Window
import QtMultimedia
import Crater

// Resolves a numeric mediaId via MediaService.byId() and renders the image
// or video inside its parent. When mediaId is 0 (or the lookup fails) the
// loader stays inactive — siblings can layer their own colors underneath.
//
// Performance contract (videos):
//   The video branch acquires through MediaPlaybackService — a refcounted,
//   per-URL shared decoder. The four surfaces that can render the same
//   container backdrop simultaneously (Preview mini-monitor, Live mini-
//   monitor, ProjectionWindow's ProjectionScene, NDI's ProjectionScene)
//   all hit the same Entry inside the service, so the file is decoded ONCE
//   and each VideoOutput receives the same QVideoFrame via the broadcast
//   (frames are implicitly shared — the relay is a pointer copy). Without
//   this, a song with a video backdrop would spawn four independent
//   QMediaPlayers and quadruple the decode cost on the weak hardware
//   Crater targets (ARCHITECTURE.md §6).
//
// Performance contract (images):
//   asynchronous: true keeps a fresh decode off the GUI thread. sourceSize
//   is bound to the actual painted geometry × Screen.devicePixelRatio so a
//   4K JPEG decodes to the resolution the audience monitor will display
//   (~4× less memory + bandwidth than a naive full-res decode for typical
//   1080p projection).
//
// autoPlay semantics (videos):
//   true  → subscribes to the shared decoder; the player ticks at native
//           framerate, looping infinitely.
//   false → no decoder, no subscription. The Loader mounts a static
//           poster Image bound to VideoThumbnailer.thumbnailPathFor(id)
//           so the tile still reads as "this is what this clip looks
//           like" — not just a black box. Used by ThemePreview tiles in
//           ThemesTab so a grid of dozens of thumbnails costs N file
//           reads (one tiny JPG each) instead of N video decoders.
//
// Audio: theme video backgrounds are decorative — they never request
// audio (wantsAudio=false on acquire). Any audio bus is driven by media
// *items* (MediaMonitor) and by foreground media playback only.
Item {
    id: root
    property int  mediaId: 0
    property real bgOpacity: 1.0
    property bool autoPlay: true

    // Cache the lookup so we don't re-query MediaService on every binding
    // re-evaluation. Recompute only when mediaId changes.
    readonly property var _media: mediaId > 0 ? MediaService.byId(mediaId) : null
    readonly property string _path: _media && _media.path ? _media.path : ""
    readonly property string _type: _media && _media.type ? _media.type : ""

    // ── Shared-decoder subscription (videos only) ──────────────────────
    // Mirrors MediaMonitor's pattern: tokens live at the root level so
    // they survive Loader churn (videoComp unmount → remount within the
    // same _path keeps the same subscription).
    property int    sharedToken: -1
    property string activeUrl:   ""

    function _videoUrl() {
        return (_type === "video" && _path.length > 0 && autoPlay)
                   ? "file:///" + _path
                   : ""
    }

    function _refreshToken() {
        const url = _videoUrl()
        if (sharedToken >= 0 && activeUrl === url) return
        if (sharedToken >= 0) {
            MediaPlaybackService.release(sharedToken)
            sharedToken = -1
            activeUrl   = ""
        }
        if (url.length > 0) {
            // wantsAudio=false — see header comment.
            sharedToken = MediaPlaybackService.acquire(url, false)
            activeUrl   = url
        }
    }

    // The derived `_path` / `_type` are bound to `mediaId` (via the
    // MediaService.byId lookup) — so watching the input is enough. Use
    // Qt.callLater so the readonly bindings settle first, then the
    // refresh reads the new values in one consistent pass.
    onMediaIdChanged:  Qt.callLater(_refreshToken)
    onAutoPlayChanged: Qt.callLater(_refreshToken)
    Component.onCompleted: _refreshToken()
    Component.onDestruction: {
        if (sharedToken >= 0) MediaPlaybackService.release(sharedToken)
    }

    Loader {
        anchors.fill: parent
        active: root._path.length > 0
        // For videos, the choice between live-decode and poster pivots on
        // `autoPlay`. ThemesTab tiles pass autoPlayVideos=false → posterComp;
        // the editor canvas and live render surfaces pass true → videoComp.
        sourceComponent: root._type === "video"
                            ? (root.autoPlay ? videoComp : posterComp)
                            : imageComp
    }

    Component {
        id: imageComp
        Image {
            source: Qt.resolvedUrl("file:///" + root._path)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: true
            opacity: root.bgOpacity
            // DPR-aware texture cap — keeps a 4K source from decoding to
            // its full native size when the container box is much smaller
            // (theme tiles, mini-monitors). At full-screen projection this
            // collapses to the native resolution. width/height read 0
            // during initial layout; the 1920×1080 fallback covers that
            // window for backgrounds in canvas-native containers.
            sourceSize.width:
                width  > 0 ? Math.ceil(width  * Screen.devicePixelRatio) : 1920
            sourceSize.height:
                height > 0 ? Math.ceil(height * Screen.devicePixelRatio) : 1080
        }
    }

    // ── Poster component (autoPlay=false videos) ───────────────────────
    // Bind `source` through VideoThumbnailer.readyCounter so a tile that
    // mounted before the worker finished extracting its still frame
    // flips from empty → thumb the moment the JPG hits disk, no tab-
    // refresh required. Matches the pattern MediaTab's grid uses for the
    // identical concern.
    //
    // Thumbs are generated at 320×180 (see VideoThumbnailer.h), so the
    // sourceSize cap matches — going larger only stretches the same
    // pixels. fillMode = PreserveAspectCrop keeps the tile geometry
    // consistent with the live-decode branch.
    Component {
        id: posterComp
        Item {
            opacity: root.bgOpacity
            // Stable dark ground so a missing/in-flight thumb reads as a
            // deliberate placeholder rather than a transparent hole that
            // shows whatever sibling rendering is behind the loader.
            Rectangle { anchors.fill: parent; color: "#0d0d12" }

            Image {
                anchors.fill: parent
                source: {
                    const _ = VideoThumbnailer.readyCounter
                    const id = root.mediaId
                    const p = id > 0 ? VideoThumbnailer.thumbnailPathFor(id) : ""
                    return p.length > 0 ? "file:///" + p : ""
                }
                visible: status === Image.Ready
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: true
                sourceSize.width:  320
                sourceSize.height: 180
            }
        }
    }

    Component {
        id: videoComp
        // VideoOutput owns its own QVideoSink (read-only in Qt 6). The
        // shared MediaPlaybackService pushes decoded frames into that sink
        // via setVideoFrame. Attach on creation + on token changes;
        // detach on destruction.
        VideoOutput {
            id: vo
            anchors.fill: parent
            fillMode: VideoOutput.PreserveAspectCrop
            opacity: root.bgOpacity

            Connections {
                target: root
                function onSharedTokenChanged() {
                    if (!vo.videoSink) return
                    if (root.sharedToken >= 0)
                        MediaPlaybackService.attachOutput(root.sharedToken, vo.videoSink)
                    else
                        MediaPlaybackService.detachOutput(vo.videoSink)
                }
            }
            Component.onCompleted: {
                if (root.sharedToken >= 0 && vo.videoSink)
                    MediaPlaybackService.attachOutput(root.sharedToken, vo.videoSink)
            }
            Component.onDestruction: {
                if (vo.videoSink) MediaPlaybackService.detachOutput(vo.videoSink)
            }
        }
    }
}
