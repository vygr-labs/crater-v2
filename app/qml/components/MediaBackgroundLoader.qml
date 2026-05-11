import QtQuick
import QtMultimedia
import Crater

// Resolves a numeric mediaId via MediaService.byId() and renders the image
// or video inside its parent. When mediaId is 0 (or the lookup fails) the
// loader stays inactive — siblings can layer their own colors underneath.
//
// Threading:
//   - Image asynchronous load avoids blocking the GUI thread on a fresh
//     theme-tile render with a 4K background.
//   - MediaPlayer (videos) decodes off-thread on Windows/macOS/Linux via the
//     platform's native codec (ARCHITECTURE.md §5.1).
//
// Looping: videos auto-restart at the end so a 5-second loop feels seamless
// behind a song. autoPlay defaults to true — toggle off when this loader is
// inside a ThemePreview tile to keep dozens of preview tiles from each
// running a video.
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

    Loader {
        anchors.fill: parent
        active: root._path.length > 0
        sourceComponent: root._type === "video" ? videoComp : imageComp
    }

    Component {
        id: imageComp
        Image {
            source: Qt.resolvedUrl("file:///" + root._path)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: true
            opacity: root.bgOpacity
        }
    }

    Component {
        id: videoComp
        Item {
            anchors.fill: parent
            opacity: root.bgOpacity
            MediaPlayer {
                id: player
                source: Qt.resolvedUrl("file:///" + root._path)
                loops: MediaPlayer.Infinite
                videoOutput: vo
                // We deliberately don't connect an AudioOutput — themes are
                // visual; audio tracks come from a separate playlist.
            }
            VideoOutput { id: vo; anchors.fill: parent; fillMode: VideoOutput.PreserveAspectCrop }
            Component.onCompleted: if (root.autoPlay) player.play()
        }
    }
}
