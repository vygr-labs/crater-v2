import QtQuick
import QtQuick.Controls   // ScrollBar attached property on the session-log list
import QtQuick.Layouts
import Crater

// Narration — AI scripture narration (docs/narration.md).
//
// The page leads with the privacy statement rather than burying it, because
// this is the one feature in Crater that opens a microphone in a church
// building, and an operator deciding whether to switch it on deserves the
// facts before the knobs. Everything claimed in that banner is enforced in
// code: the fixed ring buffer in AudioRing, the absence of any network call
// in the subsystem, and the absence of any auto-arm key in SettingsService.
Item {
    id: root

    // ── Microphone list ─────────────────────────────────────────────────
    //
    // inputDevices() is a plain call rather than a property, so nothing tells
    // QML when the set of microphones changes. Bumping this counter is the
    // dependency that forces the list to re-evaluate: on becoming visible (a
    // USB mic plugged in while the dialog was closed) and whenever the
    // selection changes.
    property int _deviceRevision: 0
    onVisibleChanged: if (visible) root._deviceRevision++

    readonly property var _deviceOptions: {
        root._deviceRevision;   // dependency, deliberately unused

        // "System default" is a real choice and not the same as naming the
        // device that happens to be default today: it means "keep following
        // whatever Windows decides", which is what an operator who moves
        // between rooms usually wants.
        const list = [{ label: qsTr("System default"), value: "" }]
        const devices = NarrationService.inputDevices()
        for (let i = 0; i < devices.length; i++) {
            list.push({
                label: devices[i].isDefault
                       ? qsTr("%1 (system default)").arg(devices[i].name)
                       : devices[i].name,
                value: devices[i].id
            })
        }
        return list
    }

    // What the button shows. Three genuinely different states, because a
    // picker that renders a disconnected device exactly like a working one is
    // how an operator ends up staring at a dead level meter.
    readonly property bool _deviceMissing: {
        root._deviceRevision;
        const id = NarrationService.inputDeviceId
        if (id.length === 0) return false
        const opts = root._deviceOptions
        for (let i = 0; i < opts.length; i++)
            if (opts[i].value === id) return false
        return true
    }

    readonly property string _deviceLabel: {
        root._deviceRevision;
        const id = NarrationService.inputDeviceId
        if (id.length === 0) return qsTr("System default")
        if (root._deviceMissing)
            return qsTr("Not connected (using %1)").arg(NarrationService.inputDeviceName)
        const opts = root._deviceOptions
        for (let i = 0; i < opts.length; i++)
            if (opts[i].value === id) return opts[i].label
        return NarrationService.inputDeviceName
    }

    Connections {
        target: NarrationService
        function onInputDeviceChanged() { root._deviceRevision++ }
    }

    Flickable {
        anchors.fill: parent
        contentHeight: layout.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: layout
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Theme.space.xl
            anchors.rightMargin: Theme.space.xl
            anchors.topMargin: Theme.space.xxxl
            spacing: 0

            // ── Build without speech support ─────────────────────────────
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: unavailableText.implicitHeight + Theme.space.lg * 2
                Layout.bottomMargin: Theme.space.lg
                visible: !NarrationService.available
                color: Theme.color.previewSubtle
                border.width: 1
                border.color: Theme.color.preview

                Text {
                    id: unavailableText
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.margins: Theme.space.lg
                    anchors.verticalCenter: parent.verticalCenter
                    wrapMode: Text.WordWrap
                    text: qsTr("This build of Crater was compiled without speech recognition, so narration cannot listen. The detection settings below still apply, and the transcript test at the bottom of this page works without a microphone.")
                    color: Theme.color.textPrimary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                }
            }

            // ── Privacy ──────────────────────────────────────────────────
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: privacyCol.implicitHeight + Theme.space.lg * 2
                color: Theme.color.raised
                border.width: 1
                border.color: Theme.color.borderSubtle

                Column {
                    id: privacyCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.margins: Theme.space.lg
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.space.xs

                    Text {
                        text: qsTr("What happens to the audio")
                        color: Theme.color.textPrimary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.bodySize
                        font.weight: Theme.font.weightSemiBold
                    }
                    Text {
                        width: privacyCol.width
                        wrapMode: Text.WordWrap
                        text: qsTr("The microphone opens only when you press Listen, and closes when you press Stop. Audio is held in a 30-second buffer in memory and is never written to disk. Nothing is sent anywhere: speech recognition runs entirely on this machine and this feature makes no network requests at all. Transcripts are discarded when you stop listening.")
                        color: Theme.color.textSecondary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                        lineHeight: 1.35
                    }
                }
            }

            // ── SPEECH MODEL ─────────────────────────────────────────────
            SettingsSectionHeader { title: qsTr("Speech model") }

            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 64
                Column {
                    anchors.left: parent.left
                    anchors.right: modelBtn.left
                    anchors.rightMargin: Theme.space.lg
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    Text {
                        text: qsTr("Model file")
                        color: Theme.color.textPrimary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.bodySize
                        font.weight: Theme.font.weightMedium
                    }
                    Text {
                        width: parent.width
                        elide: Text.ElideMiddle
                        // Named rather than described: an operator who has set
                        // this needs to confirm WHICH model, and one who
                        // hasn't needs to know a download is required. Crater
                        // never fetches it — nothing in this subsystem talks
                        // to the network, by design.
                        text: SettingsService.narrationModelPath.length > 0
                              ? SettingsService.narrationModelPath
                              : qsTr("Not set. Download a whisper.cpp model (ggml-small.en.bin is a good default) and choose it here.")
                        color: NarrationService.modelReady ? Theme.color.textTertiary
                                                           : Theme.color.warning
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                    }
                    // What is actually loaded, once it is. Two models behave
                    // visibly differently from one — suggestions appear early
                    // and are then corrected — and without this the operator
                    // has no way to tell the fast configuration from the slow
                    // one except by how long they wait.
                    //
                    // Only while armed: engineName is the engine that is
                    // running, not the one that would run.
                    Text {
                        width: parent.width
                        visible: NarrationService.engineName.length > 0
                                 && NarrationService.listening
                        elide: Text.ElideMiddle
                        text: NarrationService.engineName
                        color: Theme.color.textTertiary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                    }
                }
                GhostButton {
                    id: modelBtn
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    iconName: "folder"
                    text: qsTr("Choose")
                    onClicked: {
                        const p = FileDialogService.chooseOpenFile(
                            qsTr("Choose a speech model"),
                            ["Whisper model (*.bin)", "All files (*)"])
                        if (p && p.length > 0)
                            SettingsService.narrationModelPath = p
                    }
                }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            // ── MICROPHONE ───────────────────────────────────────────────
            //
            // The system default is frequently the wrong microphone: the
            // machine running a service usually also has a webcam and a
            // laptop lid array, and Windows picks between them on its own
            // logic rather than on which one is pointed at the preacher.
            SettingsSectionHeader { title: qsTr("Microphone") }

            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 64
                Column {
                    anchors.left: parent.left
                    anchors.right: deviceCombo.left
                    anchors.rightMargin: Theme.space.lg
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    Text {
                        text: qsTr("Input device")
                        color: Theme.color.textPrimary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.bodySize
                        font.weight: Theme.font.weightMedium
                    }
                    Text {
                        width: parent.width
                        wrapMode: Text.WordWrap
                        // While listening this says so explicitly, because
                        // changing the device mid-service reopens the
                        // microphone and the operator should know that before
                        // they touch it rather than after.
                        text: root._deviceMissing
                              ? qsTr("The microphone you chose is not connected. Falling back to the system default.")
                              : NarrationService.listening
                                ? qsTr("Changing this reopens the microphone straight away.")
                                : qsTr("Used the next time you press Listen.")
                        color: root._deviceMissing ? Theme.color.warning : Theme.color.textTertiary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                    }
                }
                Combobox {
                    id: deviceCombo
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 260
                    searchable: false
                    enabled: NarrationService.available
                    options: root._deviceOptions
                    value: root._deviceLabel
                    onValueSelected: function(v) { NarrationService.setInputDevice(v) }
                }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            // Paraphrase detection is a separate asset pair (an embedding
            // model and a vector index) that lives beside the speech model
            // and is discovered, not configured. Surfaced so its absence is
            // visible rather than looking like the feature simply never
            // notices paraphrases.
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 64
                Column {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    Text {
                        text: qsTr("Paraphrase detection")
                        color: Theme.color.textPrimary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.bodySize
                        font.weight: Theme.font.weightMedium
                    }
                    Text {
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: qsTr("Catches a verse the preacher rephrases rather than quotes. Needs an embedding model and a verse index in the same folder as the speech model; without them the other two detection paths still work normally.")
                        color: Theme.color.textTertiary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                    }
                }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 56
                Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Microphone")
                    color: Theme.color.textPrimary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize
                    font.weight: Theme.font.weightMedium
                }
                Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    // Read-only for now: capture uses the system default input,
                    // which is what a fixed installation's mixer feed already
                    // is. A picker lands with the device list this reads from.
                    text: {
                        const devs = NarrationService.inputDevices()
                        for (let i = 0; i < devs.length; ++i)
                            if (devs[i].isDefault) return devs[i].name
                        return devs.length > 0 ? devs[0].name : qsTr("None detected")
                    }
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                }
            }

            // ── TRUST ────────────────────────────────────────────────────
            SettingsSectionHeader { title: qsTr("Trust") }

            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 72
                Column {
                    anchors.left: parent.left
                    anchors.right: modeRow.left
                    anchors.rightMargin: Theme.space.lg
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    Text {
                        text: qsTr("What Crater does with what it hears")
                        color: Theme.color.textPrimary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.bodySize
                        font.weight: Theme.font.weightMedium
                    }
                    Text {
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: NarrationService.mode === "suggest"
                              ? qsTr("Suggest: every reference lands in the queue and nothing moves until you click it.")
                              : NarrationService.mode === "auto"
                              ? qsTr("Auto: a spoken book, chapter and verse goes live on its own after a short cancel window. Everything less certain still only stages to Preview.")
                              : qsTr("Stage: references go to the Preview pane and wait for your Enter. Nothing reaches the audience screen on its own.")
                        color: Theme.color.textTertiary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                    }
                }

                Row {
                    id: modeRow
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
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
                            readonly property bool active: SettingsService.narrationMode === modeChip.modelData.key

                            height: 30
                            width: chipText.implicitWidth + Theme.space.lg * 2
                            color: modeChip.active ? Theme.color.brandSubtle
                                 : chipMa.containsMouse ? Theme.color.overlay
                                                        : "transparent"
                            border.width: 1
                            border.color: modeChip.active ? Theme.color.brand
                                                          : Theme.color.borderSubtle

                            Text {
                                id: chipText
                                anchors.centerIn: parent
                                text: modeChip.modelData.label
                                color: modeChip.active ? Theme.color.brandHover
                                                       : Theme.color.textSecondary
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.smallSize
                                font.weight: modeChip.active ? Theme.font.weightSemiBold
                                                             : Theme.font.weightMedium
                            }
                            MouseArea {
                                id: chipMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: SettingsService.narrationMode = modeChip.modelData.key
                            }
                        }
                    }
                }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 64
                // Only meaningful in Auto, and dimmed rather than hidden in the
                // other modes so an operator considering Auto can see the
                // safeguard exists before committing to it.
                opacity: SettingsService.narrationMode === "auto" ? 1.0 : 0.5

                Column {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    Text {
                        text: qsTr("Cancel window before going live")
                        color: Theme.color.textPrimary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.bodySize
                        font.weight: Theme.font.weightMedium
                    }
                    Text {
                        text: qsTr("How long you have to stop a verse Auto mode is about to project")
                        color: Theme.color.textTertiary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                    }
                }

                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.space.sm

                    Repeater {
                        model: [1000, 1500, 2500, 4000]
                        delegate: Rectangle {
                            id: graceChip
                            required property int modelData
                            readonly property bool active: SettingsService.narrationGraceMs === graceChip.modelData

                            height: 30
                            width: graceText.implicitWidth + Theme.space.md * 2
                            color: graceChip.active ? Theme.color.brandSubtle
                                 : graceMa.containsMouse ? Theme.color.overlay
                                                         : "transparent"
                            border.width: 1
                            border.color: graceChip.active ? Theme.color.brand
                                                           : Theme.color.borderSubtle

                            Text {
                                id: graceText
                                anchors.centerIn: parent
                                text: (graceChip.modelData / 1000).toFixed(graceChip.modelData % 1000 === 0 ? 0 : 1) + qsTr("s")
                                color: graceChip.active ? Theme.color.brandHover
                                                        : Theme.color.textSecondary
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.smallSize
                            }
                            MouseArea {
                                id: graceMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: SettingsService.narrationGraceMs = graceChip.modelData
                            }
                        }
                    }
                }
            }

            // ── TEST ─────────────────────────────────────────────────────
            SettingsSectionHeader { title: qsTr("Test without a microphone") }

            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 84

                Column {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.space.sm

                    Text {
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: NarrationService.listening
                              ? qsTr("Type what a preacher might say and see what Crater would do with it. Runs the real detectors and the real trust rules.")
                              : qsTr("Type what a preacher might say and see what Crater would do with it. Runs the real detectors and the real trust rules, and never opens the microphone. Paraphrase detection is skipped unless narration is already listening, because loading its model would stall this dialog.")
                        color: Theme.color.textTertiary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                    }

                    Row {
                        width: parent.width
                        spacing: Theme.space.sm

                        Rectangle {
                            width: parent.width - testBtn.width - Theme.space.sm
                            height: 34
                            color: Theme.color.canvas
                            border.width: 1
                            border.color: testInput.activeFocus ? Theme.color.brand
                                                                : Theme.color.borderStrong

                            TextInput {
                                id: testInput
                                anchors.fill: parent
                                anchors.leftMargin: Theme.space.md
                                anchors.rightMargin: Theme.space.md
                                verticalAlignment: TextInput.AlignVCenter
                                color: Theme.color.textPrimary
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.bodySize
                                selectByMouse: true
                                clip: true
                                onAccepted: root._runTest()

                                Text {
                                    anchors.fill: parent
                                    verticalAlignment: Text.AlignVCenter
                                    visible: testInput.text.length === 0
                                    text: qsTr("Turn with me to first Corinthians chapter thirteen verse four")
                                    color: Theme.color.textDisabled
                                    font: testInput.font
                                    elide: Text.ElideRight
                                }
                            }
                        }

                        GhostButton {
                            id: testBtn
                            iconName: "play"
                            text: qsTr("Run")
                            onClicked: root._runTest()
                        }
                    }
                }
            }

            // ── SESSION LOG ──────────────────────────────────────────────
            // Everything Crater heard and what it did about it, including the
            // detections it deliberately suppressed. This is the evidence a
            // church needs before moving from Suggest to Stage to Auto
            // (docs/narration.md §5) — "here is last Sunday, and here is what
            // it would have done" is an argument; a vendor's accuracy claim
            // is not.
            //
            // Survives disarm on purpose, so it can be read after the service
            // rather than only during it. References and trigger spans only;
            // the transcript itself is never retained (§8).
            SettingsSectionHeader { title: qsTr("Session log") }

            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 40
                Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: NarrationService.sessionLog.length === 0
                          ? qsTr("Nothing heard yet this session.")
                          : qsTr("%1 detections").arg(NarrationService.sessionLog.length)
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                }
                GhostButton {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    visible: NarrationService.sessionLog.length > 0
                    iconName: "trash"
                    text: qsTr("Clear")
                    onClicked: NarrationService.clearLog()
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 190
                visible: NarrationService.sessionLog.length > 0
                color: Theme.color.canvas
                border.width: 1
                border.color: Theme.color.borderSubtle

                ListView {
                    id: logList
                    anchors.fill: parent
                    anchors.margins: 1
                    clip: true
                    // Newest first: during a service the last thing said is
                    // the thing being asked about.
                    verticalLayoutDirection: ListView.BottomToTop
                    model: NarrationService.sessionLog

                    delegate: Item {
                        id: logRow
                        required property var modelData
                        width: logList.width
                        height: 34

                        // What the trust gate decided, and what became of it.
                        // Colour carries the distinction that matters most:
                        // did this reach the congregation, or not?
                        readonly property color actionColor:
                            modelData.action === "live"       ? Theme.color.live
                          : modelData.action === "staged"     ? Theme.color.preview
                          : modelData.action === "cancelled"  ? Theme.color.warning
                          : modelData.action === "superseded" ? Theme.color.textTertiary
                          : modelData.action === "queued"     ? Theme.color.textSecondary
                                                              : Theme.color.textDisabled

                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.space.md
                            anchors.verticalCenter: parent.verticalCenter
                            width: 118
                            elide: Text.ElideRight
                            text: logRow.modelData.reference
                            color: Theme.color.textPrimary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.smallSize
                            font.weight: Theme.font.weightMedium
                        }

                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.space.md + 122
                            anchors.verticalCenter: parent.verticalCenter
                            width: 74
                            text: logRow.modelData.tier + " " + logRow.modelData.kind.charAt(0)
                            color: Theme.color.textTertiary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.smallSize
                        }

                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.space.md + 200
                            anchors.right: actionLabel.left
                            anchors.rightMargin: Theme.space.sm
                            anchors.verticalCenter: parent.verticalCenter
                            elide: Text.ElideRight
                            // The words that triggered it. An operator asking
                            // "why did it think that?" is asking about this
                            // column.
                            text: logRow.modelData.heardText
                            color: Theme.color.textDisabled
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.smallSize
                        }

                        Text {
                            id: actionLabel
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.space.md
                            anchors.verticalCenter: parent.verticalCenter
                            text: logRow.modelData.action
                            color: logRow.actionColor
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.smallSize
                            font.weight: Theme.font.weightMedium
                        }

                        Rectangle {
                            anchors.bottom: parent.bottom
                            anchors.left: parent.left
                            anchors.right: parent.right
                            height: 1
                            color: Theme.color.borderSubtle
                            opacity: 0.5
                        }
                    }

                    ScrollBar.vertical: AppScrollBar { }
                }
            }

            Item { Layout.fillWidth: true; Layout.preferredHeight: Theme.space.xl }
        }
    }

    function _runTest() {
        if (testInput.text.trim().length === 0) return
        NarrationService.injectTranscript(testInput.text)
        testInput.text = ""
        // Detections land in NarrationService.heard, which the narration bar
        // renders the moment the dialog closes.
    }
}
