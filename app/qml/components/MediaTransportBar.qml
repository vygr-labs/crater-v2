import QtQuick
import QtQuick.Controls
import Crater

// Compact video transport: a seek bar over a single row of controls.
//
//   0:12  [=========o-----------------------------]  2:00
//   restart  -10s  play/pause  +10s  stop  loop      -1:48  mute  [volume]
//
// Drives MediaPlaybackService's shared player for `source` through a
// MediaTransport. That player is the ONE every surface showing the URL
// renders from (audience ProjectionScene, NDI scene, the Live and Preview
// monitors), so a pause / seek here lands on all of them on the same frame.
// Nothing here owns a subscription: the bar is inert until a monitor
// acquires the URL, and goes inert again when the last one releases.
//
// Used by LivePanel (the live clip, with audio controls) and PreviewPanel
// (the staged clip, no audio controls since Preview is always silent).
Item {
    id: root

    // "file:///<path>", the same string MediaMonitor acquires with.
    property string source: ""
    // Seek-bar fill + active-toggle tint. Live passes its crimson, Preview its
    // champagne, so the bar reads as part of its channel.
    property color  accent: Theme.color.brand
    // Volume slider + mute. Off for Preview, which never makes sound.
    property bool   showAudio: true
    // Show position but take no input (Preview pointing at the clip that is
    // live: driving it from there would move the audience picture). The
    // hint replaces the buttons.
    property bool   readOnly: false
    property string readOnlyHint: ""
    property int    skipMs: 10000
    // Append the console shortcut to each tooltip. Only the Live bar sets
    // this: the shortcuts (Main.qml) always drive the live clip, so naming
    // them on the Preview bar would point at the wrong player.
    property bool   shortcutHints: false

    readonly property bool  _canControl: transport.available && !root.readOnly
    readonly property bool  _canSeek:    _canControl && transport.seekable
                                         && transport.duration > 0
    // Below this the volume slider folds away (mute stays).
    readonly property bool  _narrow: width < 360

    implicitHeight: seekRow.height + Theme.space.xs + controlRow.height

    MediaTransport {
        id: transport
        source: root.source
    }

    function _tip(label, keys) {
        return shortcutHints ? label + " (" + keys + ")" : label
    }

    // ── Time formatting ─────────────────────────────────────────────────
    function fmt(ms) {
        if (!(ms > 0)) return "0:00"
        const total = Math.floor(ms / 1000)
        const h = Math.floor(total / 3600)
        const m = Math.floor((total % 3600) / 60)
        const s = total % 60
        const ss = s < 10 ? "0" + s : "" + s
        if (h > 0) return h + ":" + (m < 10 ? "0" + m : "" + m) + ":" + ss
        return m + ":" + ss
    }

    // ── Scrub state ─────────────────────────────────────────────────────
    // While the operator drags, the thumb follows the pointer (not the
    // player) and seeks are throttled: one per 80 ms keeps the audience
    // picture tracking the drag without queueing a decoder seek per pixel.
    // After release the thumb holds the dropped spot briefly, because the
    // player reports its old position for a tick or two before the final
    // seek lands and the thumb would otherwise jump back and forth.
    property bool _scrubbing: false
    property real _scrubMs: 0
    readonly property real _shownMs:
        (_scrubbing || scrubSettle.running) ? _scrubMs : transport.position
    readonly property real _frac:
        transport.duration > 0
            ? Math.max(0, Math.min(1, _shownMs / transport.duration)) : 0

    Timer {
        id: scrubThrottle
        interval: 80
        onTriggered: transport.seek(root._scrubMs)
    }
    Timer {
        id: scrubSettle
        interval: 300
    }

    function _scrubTo(px) {
        const f = Math.max(0, Math.min(1, px / Math.max(1, track.width)))
        _scrubMs = Math.round(f * transport.duration)
    }
    function _endScrub() {
        if (!_scrubbing) return
        scrubThrottle.stop()
        transport.seek(_scrubMs)
        scrubSettle.restart()
        _scrubbing = false
    }

    // A transport button with a hover tooltip. HoverHandler is passive, so
    // IconButton's own MouseArea keeps its hover wash and click.
    component TransportButton: IconButton {
        property string tip: ""
        width: 26
        height: 26
        iconSize: Theme.icon.sm
        HoverHandler { id: tipHover }
        ToolTip.visible: tipHover.hovered && tip.length > 0
        ToolTip.text:    tip
        ToolTip.delay:   500
    }

    // ── Seek row ────────────────────────────────────────────────────────
    Item {
        id: seekRow
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 16

        Text {
            id: elapsedLabel
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: 48
            text: root.fmt(root._shownMs)
            color: Theme.color.textSecondary
            font.family: Theme.font.monoFamily
            font.pixelSize: Theme.font.microSize
        }

        Text {
            id: totalLabel
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: 48
            horizontalAlignment: Text.AlignRight
            text: transport.duration > 0 ? root.fmt(transport.duration) : "-:--"
            color: Theme.color.textSecondary
            font.family: Theme.font.monoFamily
            font.pixelSize: Theme.font.microSize
        }

        Rectangle {
            id: track
            anchors.left: elapsedLabel.right
            anchors.right: totalLabel.left
            anchors.leftMargin: Theme.space.xs
            anchors.rightMargin: Theme.space.xs
            anchors.verticalCenter: parent.verticalCenter
            height: seekMa.containsMouse || root._scrubbing ? 6 : 4
            radius: 0
            color: Theme.color.raised

            Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: parent.width * root._frac
                color: root._canControl ? root.accent : Theme.color.textTertiary
            }

            // Squared thumb, matching SimpleSlider's chip. Only shown while
            // the bar can actually seek, so a read-only bar reads as a meter.
            Rectangle {
                visible: root._canSeek
                width: 10; height: 10; radius: 0
                color: root.accent
                border.color: Theme.color.textPrimary
                border.width: 1
                x: parent.width * root._frac - width / 2
                anchors.verticalCenter: parent.verticalCenter
            }

            MouseArea {
                id: seekMa
                anchors.fill: parent
                anchors.topMargin: -6
                anchors.bottomMargin: -6
                enabled: root._canSeek
                hoverEnabled: true
                preventStealing: true
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                // Click-to-jump seeks on press. Drag-to-scrub continues from
                // there through the throttle; release commits the exact spot.
                onPressed: function(mouse) {
                    root._scrubbing = true
                    root._scrubTo(mouse.x)
                    transport.seek(root._scrubMs)
                }
                onPositionChanged: function(mouse) {
                    if (!pressed) return
                    root._scrubTo(mouse.x)
                    if (!scrubThrottle.running) scrubThrottle.start()
                }
                onReleased: root._endScrub()
                onCanceled: root._endScrub()
            }
        }
    }

    // ── Control row ─────────────────────────────────────────────────────
    Item {
        id: controlRow
        anchors.top: seekRow.bottom
        anchors.topMargin: Theme.space.xs
        anchors.left: parent.left
        anchors.right: parent.right
        height: 26

        Row {
            id: buttons
            visible: !root.readOnly
            anchors.left: parent.left
            // Line the first button's glyph up with the elapsed time above.
            anchors.leftMargin: -Theme.space.xs
            anchors.verticalCenter: parent.verticalCenter
            spacing: 0
            enabled: root._canControl

            TransportButton {
                iconName: "skip-back"
                tip: root._tip(qsTr("Restart"), "Alt+Home")
                onClicked: transport.restart()
            }
            TransportButton {
                iconName: "rewind"
                enabled: root._canSeek
                tip: root._tip(qsTr("Back %1 s").arg(Math.round(root.skipMs / 1000)), "Alt+Left")
                onClicked: transport.skip(-root.skipMs)
            }
            TransportButton {
                iconName: transport.playing ? "pause" : "play"
                iconSize: Theme.icon.md
                tint: Theme.color.textPrimary
                tip: root._tip(transport.playing ? qsTr("Pause") : qsTr("Play"), "Ctrl+P")
                onClicked: transport.togglePlay()
            }
            TransportButton {
                iconName: "fast-forward"
                enabled: root._canSeek
                tip: root._tip(qsTr("Forward %1 s").arg(Math.round(root.skipMs / 1000)), "Alt+Right")
                onClicked: transport.skip(root.skipMs)
            }
            TransportButton {
                iconName: "square"
                tip: root._tip(qsTr("Stop and rewind"), "Ctrl+Shift+P")
                onClicked: transport.stop()
            }
            TransportButton {
                iconName: "repeat"
                // Lit in the channel accent while looping, so the state is
                // readable without hovering.
                tint:      transport.loop ? root.accent : Theme.color.textTertiary
                tintHover: transport.loop ? root.accent : Theme.color.textPrimary
                tip: transport.loop ? qsTr("Looping. Click to play once")
                                    : qsTr("Plays once. Click to loop")
                onClicked: transport.loop = !transport.loop
            }
        }

        Text {
            visible: root.readOnly
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.readOnlyHint
            color: Theme.color.textTertiary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.microSize
            elide: Text.ElideRight
        }

        Row {
            id: rightGroup
            visible: !root.readOnly
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.space.xs

            // Remaining time. "Ended" once a play-once clip has run out and
            // is holding its last frame, which is the moment an operator
            // most needs to notice.
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: transport.atEnd ? qsTr("Ended")
                    : transport.duration > 0
                        ? "-" + root.fmt(Math.max(0, transport.duration - root._shownMs))
                        : ""
                color: transport.atEnd ? root.accent : Theme.color.textTertiary
                font.family: transport.atEnd ? Theme.font.family : Theme.font.monoFamily
                font.pixelSize: Theme.font.microSize
            }

            TransportButton {
                visible: root.showAudio
                anchors.verticalCenter: parent.verticalCenter
                readonly property bool _silent:
                    MediaPlaybackService.muted || SettingsService.mediaVolume <= 0
                iconName: _silent ? "volume-x"
                        : SettingsService.mediaVolume < 0.5 ? "volume-1" : "volume-2"
                tint: MediaPlaybackService.muted ? root.accent : Theme.color.textSecondary
                tip: root._tip(MediaPlaybackService.muted ? qsTr("Unmute") : qsTr("Mute"), "Ctrl+M")
                onClicked: MediaPlaybackService.muted = !MediaPlaybackService.muted
            }

            // Output volume. Writes SettingsService.mediaVolume (persisted);
            // main.cpp pushes it to every shared player. Global rather than
            // per clip, like a desk fader.
            Item {
                id: volume
                visible: root.showAudio && !root._narrow
                anchors.verticalCenter: parent.verticalCenter
                width: 64
                height: 16
                readonly property real _v: SettingsService.mediaVolume

                Rectangle {
                    id: volTrack
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    height: 4
                    radius: 0
                    color: Theme.color.raised

                    Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: parent.width * volume._v
                        color: MediaPlaybackService.muted ? Theme.color.textTertiary
                                                          : Theme.color.textSecondary
                    }
                    Rectangle {
                        width: 8; height: 8; radius: 0
                        color: Theme.color.textPrimary
                        x: parent.width * volume._v - width / 2
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    anchors.topMargin: -5
                    anchors.bottomMargin: -5
                    preventStealing: true
                    cursorShape: Qt.PointingHandCursor
                    function _set(px) {
                        const f = Math.max(0, Math.min(1, px / Math.max(1, volTrack.width)))
                        SettingsService.mediaVolume = Math.round(f * 100) / 100
                        // Reaching for the fader means "I want to hear it".
                        if (MediaPlaybackService.muted && f > 0)
                            MediaPlaybackService.muted = false
                    }
                    onPressed: function(mouse) { _set(mouse.x) }
                    onPositionChanged: function(mouse) { if (pressed) _set(mouse.x) }
                    onWheel: function(wheel) {
                        const step = wheel.angleDelta.y > 0 ? 0.05 : -0.05
                        SettingsService.mediaVolume =
                            Math.max(0, Math.min(1, Math.round((volume._v + step) * 100) / 100))
                    }
                }
            }
        }
    }
}
