import QtQuick
import QtMultimedia

// Reusable media monitor — renders an image or a looping video at the
// caller's geometry. Used by the Preview and Live mini-monitors today;
// the projection window will use the same component in a follow-up.
//
// Performance contract (the whole reason this is its own file):
//   • Decoder is only instantiated while mediaPath is non-empty AND
//     mediaKind is "image" or "video". The Loader.active gate destroys
//     the MediaPlayer entirely when the operator switches to a non-media
//     item — no paused-but-resident decoder, no pinned GPU memory.
//   • Image has explicit sourceSize so a 4K source doesn't upload a 4K
//     texture just to render at 320×180.
//   • PreserveAspectFit (the default here) avoids the extra crop pass
//     PreserveAspectCrop adds; mini-monitors letterbox cleanly.
//   • play() is called from onSourceChanged so swapping the active item
//     within the same kind ("video" → "video", different path) re-uses
//     the existing player instead of tearing it down. Switching kind
//     ("video" → "image") destroys the player via Loader recomposition;
//     that's intentional — there's no codec state to preserve.
//
// Why not reuse MediaBackgroundLoader.qml: it takes a numeric mediaId
// and re-queries MediaService.byId(); here the schedule item already
// carries mediaPath directly so we skip the lookup. It also deliberately
// has no AudioOutput (theme backgrounds are visual). The Live monitor
// needs audio routing — separate concerns, separate component.
Item {
    id: root

    // ── Inputs ──────────────────────────────────────────────────────────
    property string mediaKind: ""       // "image" | "video" | "" (inactive)
    property string mediaPath: ""       // absolute file path
    property bool   muted: true         // preview: true, live: false
    property bool   crop: false         // false = PreserveAspectFit, true = PreserveAspectCrop

    readonly property bool _isMedia:
        mediaPath.length > 0 && (mediaKind === "image" || mediaKind === "video")

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
            // file:/// prefix matches how MediaTab and the rest of the app
            // build URLs from absolute paths; consistent prefix avoids
            // Qt's "is this a resource or filesystem path" guessing.
            source: "file:///" + root.mediaPath
            fillMode: root.crop ? Image.PreserveAspectCrop : Image.PreserveAspectFit
            asynchronous: true
            cache: true
            // Cap decoded texture to a slightly-larger-than-display size.
            // The Live mini-monitor is 320×180 today; 512×288 leaves
            // headroom for higher-DPI displays without wasting memory on
            // a 4K decode.
            sourceSize.width:  512
            sourceSize.height: 288
        }
    }

    // ── Video branch ────────────────────────────────────────────────────
    Component {
        id: videoComp
        Item {
            anchors.fill: parent

            MediaPlayer {
                id: player
                source: root.mediaPath.length > 0
                            ? "file:///" + root.mediaPath
                            : ""
                loops: MediaPlayer.Infinite
                videoOutput: vo
                // AudioOutput is always present so the player's audio bus
                // is real; muted toggles routing rather than swapping the
                // bus, which avoids a brief click on the operator's
                // default device when an item flips between preview and
                // live.
                audioOutput: AudioOutput {
                    muted:  root.muted
                    volume: 1.0
                }

                // Fires on initial binding *and* on subsequent path
                // changes within the same kind, so we don't need a
                // separate Component.onCompleted hook.
                onSourceChanged: {
                    if (player.source.toString().length > 0) play()
                }
            }

            VideoOutput {
                id: vo
                anchors.fill: parent
                fillMode: root.crop ? VideoOutput.PreserveAspectCrop
                                    : VideoOutput.PreserveAspectFit
            }
        }
    }
}
