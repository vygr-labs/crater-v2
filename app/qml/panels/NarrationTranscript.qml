import QtQuick
import QtQuick.Controls
import Crater

// What the microphone heard (docs/narration.md §8).
//
// ── Why this exists ──────────────────────────────────────────────────────
//
// NarrationBar reports the END of the pipeline: a chip appears when a verse
// was identified. Everything upstream of that is invisible, and there are four
// distinct ways for it to produce nothing:
//
//   the microphone is open but deaf      level meter flat
//   the voice gate never closes an utterance   utterances stays 0
//   the recognizer returns empty strings       utterances climbs, no lines
//   the detectors declined what was said       lines appear, no chips
//
// Without this strip all four look identical — a red bar that says "Listening"
// and does nothing — and the operator's only report can be "it isn't working".
// With it, the fault names itself.
//
// ── Why showing transcripts is allowed ───────────────────────────────────
//
// §8 scopes transcripts to the session and forbids them reaching disk. It
// never required hiding them from the person who is standing there listening
// to the same words. NarrationService holds them in memory, capped, and clears
// them on BOTH arm and disarm, so nothing here outlives the microphone.
Rectangle {
    id: root

    // Set by Main.qml. Same input NarrationBar takes, for the same reason: the
    // console is not the only screen this window shows.
    property bool consoleActive: true

    readonly property bool   _listening: NarrationService.listening
    readonly property var    _lines: NarrationService.transcript
    // The sentence in progress. Updated about once a second while someone is
    // speaking, replaced by the finished text when they pause.
    readonly property string _partial: NarrationService.partialText

    // Visible while listening, and afterwards for as long as there is
    // something to read. It disappears on disarm because the service clears
    // the transcript, which is the behaviour §8 asks for rather than an
    // animation.
    visible: consoleActive && (_listening || _lines.length > 0 || _partial.length > 0)
    height: visible ? 34 : 0
    color: Theme.color.elevated

    Behavior on height { NumberAnimation { duration: Theme.motion.instant } }

    Rectangle {
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 1
        color: Theme.color.borderSubtle
    }

    // ── Status, when there is nothing to show yet ────────────────────────
    //
    // Deliberately specific about WHICH stage is silent. "Listening" alone is
    // the message that made this strip necessary in the first place.
    Text {
        anchors.left: parent.left
        anchors.leftMargin: Theme.space.lg
        anchors.right: partialLabel.left
        anchors.rightMargin: Theme.space.lg
        anchors.verticalCenter: parent.verticalCenter
        visible: root._lines.length === 0 && root._partial.length === 0
        elide: Text.ElideRight
        text: !root._listening
              ? qsTr("Not listening.")
              : NarrationService.utterancesHeard > 0
                ? qsTr("Heard %n phrase(s), but speech recognition returned nothing. The model may be wrong for this audio.",
                       "", NarrationService.utterancesHeard)
                : NarrationService.hearingSpeech
                  ? qsTr("Hearing you. Waiting for you to pause before transcribing.")
                  : qsTr("No speech detected yet. Check the level meter is moving as you talk.")
        color: Theme.color.textTertiary
        font.family: Theme.font.family
        font.pixelSize: Theme.font.smallSize
        font.italic: true
    }

    // ── The transcript itself ────────────────────────────────────────────
    //
    // One line, scrolling horizontally, newest at the right. A sermon does not
    // fit on a strip and an operator is not reading it back — they are
    // checking that the words arriving resemble the words being said.
    // ── The sentence being spoken right now ─────────────────────────────
    //
    // Sits at the right, where the newest words are, and is styled apart from
    // the finished text because it is a hypothesis: it will be revised while
    // the speaker is still talking and replaced outright when they pause.
    //
    // Elides from the LEFT so the most recent words stay on screen. A live
    // caption that keeps the beginning of the phrase and hides the end is
    // showing the operator the part they have already heard.
    Text {
        id: partialLabel
        anchors.right: countLabel.left
        anchors.rightMargin: Theme.space.lg
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(implicitWidth, root.width * 0.55)
        text: root._partial
        elide: Text.ElideLeft
        color: Theme.color.textPrimary
        font.family: Theme.font.family
        font.pixelSize: Theme.font.smallSize
    }

    ListView {
        id: lineView
        anchors.left: parent.left
        anchors.leftMargin: Theme.space.lg
        anchors.right: partialLabel.left
        anchors.rightMargin: root._partial.length > 0 ? Theme.space.lg : 0
        anchors.verticalCenter: parent.verticalCenter
        height: 22
        visible: root._lines.length > 0

        orientation: ListView.Horizontal
        spacing: Theme.space.md
        clip: true
        model: root._lines

        // Follow the newest line. positionViewAtEnd rather than a binding on
        // contentX: the delegates are variable width, so the end position is
        // not known until they are laid out.
        onCountChanged: Qt.callLater(positionViewAtEnd)

        delegate: Row {
            id: lineRow
            required property var modelData
            anchors.verticalCenter: parent ? parent.verticalCenter : undefined
            spacing: Theme.space.md

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: lineRow.modelData.text
                color: Theme.color.textSecondary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
            }
            // A separator rather than a timestamp: the operator is scanning
            // for words, and a clock reading beside every phrase is noise they
            // have to look past.
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 3; height: 3; radius: 1.5
                color: Theme.color.borderStrong
            }
        }
    }

    // ── Counter ──────────────────────────────────────────────────────────
    //
    // The number that separates "the gate never opened" from "the recognizer
    // gave nothing back", which is the first fork in every diagnosis here.
    Text {
        id: countLabel
        anchors.right: parent.right
        anchors.rightMargin: Theme.space.lg
        anchors.verticalCenter: parent.verticalCenter
        visible: root._listening || root._lines.length > 0
        text: NarrationService.droppedUtterances > 0
              ? qsTr("%1 heard, %2 dropped").arg(NarrationService.utterancesHeard)
                                            .arg(NarrationService.droppedUtterances)
              : qsTr("%1 heard").arg(NarrationService.utterancesHeard)
        color: NarrationService.droppedUtterances > 0 ? Theme.color.warning
                                                      : Theme.color.textTertiary
        font.family: Theme.font.family
        font.pixelSize: Theme.font.smallSize
    }
}
