import QtQuick
import QtQuick.Controls   // ToolTip, for the transcript span behind a chip
import Crater

// The narration strip: hot-microphone indicator, level meter, trust mode,
// and the queue of references Crater heard the preacher say.
//
// It also does the routing. NarrationService reports coordinates and a trust
// decision; turning that into a projection item needs the operator's active
// translation and the shared ScriptureItems builder, both of which are QML
// concerns. So the service decides WHAT and this file decides HOW IT LOOKS
// and WHERE IT GOES — which is also why crater-core never learns what a
// preview pane is.
//
// Collapsed to zero height whenever there is nothing to say, so a console
// with narration switched off is pixel-identical to one built before this
// feature existed.
//
// The hot indicator is not decoration. docs/narration.md §8 requires an open
// microphone to be obvious from across the room, so this is a full-width
// red-washed bar with a pulsing dot rather than a small glyph in a corner.
// Anyone walking past the operator's desk can tell the room is being heard.
Rectangle {
    id: root

    // Set false while the console itself is hidden (Main.qml's projector-only
    // and theme-editor states). Kept as an input rather than letting Main.qml
    // assign `visible` directly, so the bar's own "is there anything to say?"
    // binding stays intact.
    property bool consoleActive: true

    readonly property bool _listening: NarrationService.listening
    readonly property bool _loading:   NarrationService.engineState === "loading"
    readonly property bool _errored:   NarrationService.engineState === "error"
                                       && NarrationService.statusMessage.length > 0

    // heardCount keeps the bar up after a disarm that left suggestions
    // outstanding, and is what makes the transcript test in
    // Settings > Narration visible without ever opening a microphone.
    visible: consoleActive
             && (_listening || _loading || _errored
                 || NarrationService.heardCount > 0 || _pending !== null)
    height: visible ? 46 : 0

    color: _listening ? Theme.color.liveSubtle : Theme.color.elevated

    Behavior on height { NumberAnimation { duration: Theme.motion.instant } }

    // ── Translation + item resolution ───────────────────────────────────
    // Detection returns verse coordinates, never text. Which translation the
    // congregation actually sees is the operator's choice and follows the
    // Scripture tab's active version (docs/narration.md §11) — so a preacher
    // quoting the ESV still puts the operator's KJV on the screen.
    readonly property string _code:
        (AppState.activeLibraryGroup.scripture || "").toUpperCase()
        || SettingsService.defaultScriptureVersion

    function _versesFor(entry) {
        const out = []
        if (!entry || !entry.book || entry.chapter <= 0) return out
        const last = Math.max(entry.verseStart, entry.verseEnd)
        for (let n = entry.verseStart; n <= last; ++n) {
            const v = BibleService.verse(_code, entry.book, entry.chapter, n)
            if (v && v.text && v.text.length > 0) out.push(v)
        }
        return out
    }

    function _itemFor(entry) {
        const verses = _versesFor(entry)
        if (verses.length === 0) return null
        return verses.length === 1 ? ScriptureItems.fromVerse(verses[0], _code)
                                   : ScriptureItems.fromVerses(verses, _code)
    }

    // Stage a heard reference into the Preview pane. It waits there for the
    // operator's Enter; nothing about staging touches the audience screen.
    function stage(entry) {
        const item = _itemFor(entry)
        if (!item) return false
        AppState.pushLibraryPreview(item, 0)
        return true
    }

    // ── Auto mode's grace period (docs/narration.md §5) ─────────────────
    //
    // The difference between "the machine did something wrong" and "the
    // machine proposed something wrong and a human had a beat to stop it".
    // Cheap to build, and it is the thing that lets a church actually run in
    // Auto rather than admiring the idea of it.
    //
    // The pending reference is staged into Preview immediately, so the
    // operator can see exactly what is about to go out while the clock runs.
    property var _pending: null
    property int _pendingRemainingMs: 0

    readonly property real _graceProgress:
        SettingsService.narrationGraceMs > 0
            ? 1.0 - (_pendingRemainingMs / SettingsService.narrationGraceMs)
            : 0

    function _cancelPending(reason) {
        if (!_pending) return
        NarrationService.amendLog(_pending.id, reason)
        _pending = null
        _pendingRemainingMs = 0
        graceTimer.stop()
    }

    function _commitPending() {
        const entry = _pending
        _pending = null
        _pendingRemainingMs = 0
        graceTimer.stop()
        if (!entry) return

        const item = _itemFor(entry)
        if (!item) {
            // The verse did not resolve in the operator's translation. Better
            // to say nothing went out than to log a projection that did not
            // happen.
            NarrationService.amendLog(entry.id, "cancelled")
            return
        }
        AppState.pushLibraryLive(item, 0)
        NarrationService.dismiss(entry.id)
    }

    Timer {
        id: graceTimer
        // 50 ms so the countdown reads smoothly without waking the UI thread
        // every frame for something the operator only glances at.
        interval: 50
        repeat: true
        running: root._pending !== null
        onTriggered: {
            root._pendingRemainingMs -= interval
            if (root._pendingRemainingMs <= 0) root._commitPending()
        }
    }

    Connections {
        target: NarrationService

        // Stage tier — the reference goes to Preview and waits for the
        // operator's Enter. This is the default mode's whole behaviour.
        function onReferenceStaged(ref) { root.stage(ref) }

        // Suggest tier — nothing moves. The entry is already in
        // NarrationService.heard, which the chip row below renders.
        function onReferenceDetected(ref) { }

        // Auto tier — start the cancel window.
        function onReferenceAutoLive(ref) {
            // A second detection during the window means the preacher moved
            // on, and the newer reference is the one they are talking about.
            // Marked superseded rather than cancelled so the log distinguishes
            // "the operator stopped this" from "the sermon overtook it".
            if (root._pending) root._cancelPending("superseded")

            root.stage(ref)                       // show what is about to go out
            root._pending = ref
            root._pendingRemainingMs = SettingsService.narrationGraceMs
        }

        // Losing the microphone mid-countdown must not project on the way
        // out. Whatever was pending was based on audio that has stopped.
        function onListeningChanged() {
            if (!NarrationService.listening) root._cancelPending("cancelled")
        }
    }

    // ── Grace countdown overlay ─────────────────────────────────────────
    // Takes over the whole bar while it runs. Splitting the operator's
    // attention between a countdown and a queue of chips at the moment
    // something is about to reach the congregation would be the wrong call.
    Rectangle {
        id: graceOverlay
        anchors.fill: parent
        anchors.bottomMargin: 1
        visible: root._pending !== null
        z: 10
        color: Theme.color.liveSubtle

        // Fills left to right as the window runs out. A shrinking bar reads
        // as "time left" without anyone having to parse a number.
        Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: parent.width * Math.max(0, Math.min(1, root._graceProgress))
            color: Qt.rgba(177/255, 54/255, 52/255, 0.28)
        }

        Row {
            anchors.left: parent.left
            anchors.leftMargin: Theme.space.lg
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.space.md

            AppIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "play"
                color: Theme.color.live
                size: Theme.icon.md
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root._pending
                      ? qsTr("Going live: %1").arg(root._pending.reference)
                      : ""
                color: Theme.color.textPrimary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize
                font.weight: Theme.font.weightSemiBold
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("%1s").arg((Math.max(0, root._pendingRemainingMs) / 1000).toFixed(1))
                color: Theme.color.live
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize
                font.weight: Theme.font.weightSemiBold
            }
        }

        // Deliberately oversized. §5 calls for a large, unmissable cancel
        // affordance, and a 20 px icon button is neither.
        Rectangle {
            id: cancelBtn
            anchors.right: parent.right
            anchors.rightMargin: Theme.space.lg
            anchors.verticalCenter: parent.verticalCenter
            height: 34
            width: cancelRow.implicitWidth + Theme.space.xl * 2
            color: cancelMa.containsMouse ? Theme.color.live
                                          : Qt.rgba(177/255, 54/255, 52/255, 0.35)
            border.width: 1
            border.color: Theme.color.live
            Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

            Row {
                id: cancelRow
                anchors.centerIn: parent
                spacing: Theme.space.sm

                AppIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "x"
                    color: Theme.color.textPrimary
                    size: Theme.icon.sm
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Cancel")
                    color: Theme.color.textPrimary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize
                    font.weight: Theme.font.weightSemiBold
                }
            }

            MouseArea {
                id: cancelMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root._cancelPending("cancelled")
            }
        }
    }

    // Bottom hairline, matching TopBar's.
    Rectangle {
        anchors.bottom: parent.bottom
        anchors.left:   parent.left
        anchors.right:  parent.right
        height: 1
        color: root._listening ? Theme.color.live : Theme.color.borderSubtle
    }

    // ── Left: state + level ─────────────────────────────────────────────
    Row {
        id: leftCluster
        anchors.left: parent.left
        anchors.leftMargin: Theme.space.lg
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.space.md

        // Pulsing dot. Slow enough (1.2 s) to read as "recording" rather than
        // an alarm the operator learns to tune out.
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: 10
            height: 10
            radius: 5
            visible: root._listening
            color: Theme.color.live

            SequentialAnimation on opacity {
                running: root._listening
                loops: Animation.Infinite
                NumberAnimation { from: 1.0; to: 0.25; duration: 1200; easing.type: Easing.InOutQuad }
                NumberAnimation { from: 0.25; to: 1.0; duration: 1200; easing.type: Easing.InOutQuad }
            }
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root._listening ? qsTr("MIC LIVE")
                : root._loading   ? qsTr("Starting narration...")
                                  : qsTr("Narration")
            color: root._listening ? Theme.color.live : Theme.color.textSecondary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.smallSize
            font.weight: Theme.font.weightSemiBold
            font.letterSpacing: root._listening ? 0.8 : 0
        }

        // Level meter. Doubles as the "is this microphone actually alive?"
        // answer — a dead input and a preacher who has not cited anything
        // look identical without it.
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            visible: root._listening
            width: 90
            height: 6
            color: Theme.color.raised

            Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: parent.width * Math.max(0, Math.min(1, NarrationService.inputLevel))
                // Green while the gate considers this speech, dim otherwise.
                // The operator can see the gate opening and closing, which is
                // what makes a mis-tuned threshold diagnosable instead of
                // mysterious.
                color: NarrationService.hearingSpeech ? Theme.color.goLive
                                                      : Theme.color.textDisabled
                Behavior on width { NumberAnimation { duration: 60 } }
            }
        }

        // Recognition fell behind and utterances were dropped rather than
        // queued (see kMaxInFlight in NarrationService.cpp). Surfaced because
        // silence from a starved recognizer is indistinguishable from a
        // preacher who simply is not citing scripture.
        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: root._listening && NarrationService.droppedUtterances > 0
            text: qsTr("%1 missed").arg(NarrationService.droppedUtterances)
            color: Theme.color.warning
            font.family: Theme.font.family
            font.pixelSize: Theme.font.smallSize
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: root._errored
            text: NarrationService.statusMessage
            color: Theme.color.warning
            font.family: Theme.font.family
            font.pixelSize: Theme.font.smallSize
            elide: Text.ElideRight
            width: Math.min(implicitWidth, 420)
        }
    }

    // ── Right: mode + stop ──────────────────────────────────────────────
    Row {
        id: rightCluster
        anchors.right: parent.right
        anchors.rightMargin: Theme.space.lg
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.space.sm

        // Trust mode. Three chips rather than a dropdown: this is the control
        // that decides whether the machine can drive the audience screen, and
        // it should never be one click away from being changed by accident,
        // nor hidden behind a menu the operator has to go looking for.
        Row {
            anchors.verticalCenter: parent.verticalCenter
            visible: root._listening
            spacing: 0

            Repeater {
                model: [
                    { key: "suggest", label: qsTr("Suggest") },
                    { key: "stage",   label: qsTr("Stage") },
                    { key: "auto",    label: qsTr("Auto") }
                ]

                delegate: Rectangle {
                    id: modeChip
                    required property var modelData
                    readonly property bool active: NarrationService.mode === modeChip.modelData.key

                    height: 26
                    width: modeLabel.implicitWidth + Theme.space.md * 2
                    color: modeChip.active ? Theme.color.brandSubtle
                         : modeMa.containsMouse ? Theme.color.overlay
                                                : "transparent"
                    border.width: 1
                    border.color: modeChip.active ? Theme.color.brand : Theme.color.borderSubtle

                    Text {
                        id: modeLabel
                        anchors.centerIn: parent
                        text: modeChip.modelData.label
                        color: modeChip.active ? Theme.color.brandHover : Theme.color.textSecondary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                        font.weight: modeChip.active ? Theme.font.weightSemiBold
                                                     : Theme.font.weightMedium
                    }

                    MouseArea {
                        id: modeMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: NarrationService.mode = modeChip.modelData.key
                    }
                }
            }
        }

        GhostButton {
            anchors.verticalCenter: parent.verticalCenter
            visible: NarrationService.heardCount > 0
            iconName: "x"
            text: qsTr("Clear queue")
            onClicked: NarrationService.dismissAll()
        }

        // Disarm. Always reachable while the microphone is open, and it is the
        // only control on this bar that is present in every state.
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            visible: root._listening || root._loading
            height: 28
            width: stopRow.implicitWidth + Theme.space.lg * 2
            color: stopMa.containsMouse ? Qt.rgba(177/255, 54/255, 52/255, 0.16)
                                        : "transparent"
            border.width: 1
            border.color: Theme.color.live

            Row {
                id: stopRow
                anchors.centerIn: parent
                spacing: Theme.space.xs

                AppIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "mic-off"
                    color: Theme.color.live
                    size: Theme.icon.sm
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Stop listening")
                    color: Theme.color.live
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                    font.weight: Theme.font.weightSemiBold
                }
            }

            MouseArea {
                id: stopMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: NarrationService.disarm()
            }
        }
    }

    // ── Centre: the heard queue ─────────────────────────────────────────
    // Horizontal because it lives in a 46 px strip, newest first because a
    // sermon moves forward and the operator cares about what was just said.
    ListView {
        id: heardRow

        anchors.left: leftCluster.right
        anchors.right: rightCluster.left
        anchors.leftMargin: Theme.space.xl
        anchors.rightMargin: Theme.space.lg
        anchors.verticalCenter: parent.verticalCenter
        height: 30

        orientation: ListView.Horizontal
        spacing: Theme.space.sm
        clip: true
        model: NarrationService.heard

        delegate: Rectangle {
            id: chip
            required property var modelData

            // Tier is evidence quality, not a score (docs/narration.md §5),
            // and the colour says which kind of evidence it is:
            //   certain  — the preacher spoke the address; green
            //   high     — inferred from context or a verbatim quote; gold
            //   possible — a semantic guess that can never fire; grey
            readonly property color tierColor:
                chip.modelData.tier === "certain"  ? Theme.color.goLive
              : chip.modelData.tier === "high"     ? Theme.color.preview
                                                   : Theme.color.textTertiary

            height: 30
            width: chipRow.implicitWidth + Theme.space.md * 2
            color: chipMa.containsMouse ? Theme.color.overlay : Theme.color.elevated
            border.width: 1
            border.color: chip.tierColor

            Row {
                id: chipRow
                anchors.centerIn: parent
                spacing: Theme.space.sm

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 6; height: 6; radius: 3
                    color: chip.tierColor
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: chip.modelData.reference
                    color: Theme.color.textPrimary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                    font.weight: Theme.font.weightMedium
                }

                // What the trust gate already did with it, so a staged entry
                // reads differently from one merely offered.
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: chip.modelData.action === "staged" || chip.modelData.action === "live"
                    text: chip.modelData.action === "live" ? qsTr("live") : qsTr("staged")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                }

                AppIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "x"
                    color: dismissMa.containsMouse ? Theme.color.textPrimary
                                                   : Theme.color.textTertiary
                    size: Theme.icon.xs

                    MouseArea {
                        id: dismissMa
                        anchors.fill: parent
                        anchors.margins: -4
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: NarrationService.dismiss(chip.modelData.id)
                    }
                }
            }

            // Click anywhere else on the chip to stage it. One click from
            // "Crater heard this" to "it is in Preview" is the entire point
            // of Suggest mode — an operator who has to go find the verse
            // themselves has not been helped.
            MouseArea {
                id: chipMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton
                onClicked: {
                    if (root.stage(chip.modelData))
                        NarrationService.dismiss(chip.modelData.id)
                }
                // Let the dismiss glyph win where they overlap.
                z: -1
            }

            // The transcript span that triggered this detection. An operator
            // asking "why did it think that?" gets the answer on hover rather
            // than having to open a log.
            ToolTip.visible: chipMa.containsMouse && chip.modelData.heardText.length > 0
            ToolTip.delay: 600
            ToolTip.text: chip.modelData.heardText
        }
    }
}
