import QtQuick
import QtQuick.Layouts

// Timers & Messages — the operator control surface for the live overlay
// (LiveMessages singleton, rendered by LiveOverlayLayer on the projection +
// NDI). Opened from the TopBar "Timer" button or Ctrl+M.
//
// Apply model:
//   • Style (position / background) and the clock format flags write straight
//     to the singleton, so they retune the LIVE overlay instantly — they're
//     overlay-wide "look" knobs where immediate feedback is the point.
//   • Content (the message text, the countdown target, count-up, captions) is
//     PENDING here and pushed only by "Show on screen", so browsing tabs or
//     editing a field never disturbs what's currently live. Re-Show is the
//     deliberate commit (and, for a duration countdown, a fresh start).
//
// The preview box embeds a real LiveOverlayLayer bound to the pending config,
// so what the operator sees is pixel-identical to the audience output.
ModalShell {
    id: root

    dialogWidth: 800
    dialogHeight: 616
    title: qsTr("Timers & Messages")

    // Which mode tab is being edited (independent of what's live).
    property string pendingMode: "countdown"
    property string cdSubMode: "duration"    // "duration" | "until"
    property string cdEndMode: "hold"        // "hold" | "message"

    Component.onCompleted: {
        // Reopen onto whatever's live so the dialog reflects the current state.
        if (LiveMessages.active) root.pendingMode = LiveMessages.mode
    }

    readonly property var _modeOrder: ["countdown", "countup", "clock", "message"]
    function _modeIndex(m) {
        var i = _modeOrder.indexOf(m)
        return i < 0 ? 0 : i
    }

    // Absolute target the countdown preview (and Show) counts down to, from the
    // pending duration or wall-clock fields. Re-evaluates as the fields change.
    readonly property double _previewCountdownTarget: {
        if (root.cdSubMode === "duration")
            return Date.now() + (cdMinField.value * 60 + cdSecField.value) * 1000
        var now = new Date()
        var t = new Date(now.getFullYear(), now.getMonth(), now.getDate(),
                         cdHourField.value, cdMinuteField.value, 0, 0)
        if (t.getTime() <= now.getTime()) t = new Date(t.getTime() + 24 * 3600 * 1000)
        return t.getTime()
    }

    function _show() {
        switch (root.pendingMode) {
        case "countdown":
            LiveMessages.countdownEndMode = root.cdEndMode
            LiveMessages.countdownEndMessage = endMsgField.text
            if (root.cdSubMode === "duration")
                LiveMessages.startCountdownDuration(cdMinField.value * 60 + cdSecField.value,
                                                    captionField.text)
            else
                LiveMessages.startCountdownUntil(cdHourField.value, cdMinuteField.value,
                                                 captionField.text)
            break
        case "countup":
            LiveMessages.startCountup()
            break
        case "clock":
            LiveMessages.showClock()
            break
        case "message":
            LiveMessages.showMessage(msgField.text)
            break
        }
    }

    // ── Reusable inline inputs ──────────────────────────────────────────
    component NumField: Rectangle {
        id: nf
        property int value: 0
        property int maxValue: 59
        property int initial: 0
        implicitWidth: 66
        implicitHeight: 44
        radius: 0
        color: Theme.color.canvas
        border.color: nfInput.activeFocus ? Theme.color.brand : Theme.color.borderStrong
        border.width: 1
        TextInput {
            id: nfInput
            anchors.fill: parent
            anchors.margins: 4
            horizontalAlignment: TextInput.AlignHCenter
            verticalAlignment: TextInput.AlignVCenter
            color: Theme.color.textPrimary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.titleSize + 4
            font.weight: Theme.font.weightSemiBold
            selectByMouse: true
            validator: IntValidator { bottom: 0; top: nf.maxValue }
            text: LiveMessages.pad2(nf.initial)
            Component.onCompleted: nf.value = nf.initial
            onTextChanged: {
                var v = parseInt(text, 10)
                if (isNaN(v)) v = 0
                if (v > nf.maxValue) v = nf.maxValue
                nf.value = v
            }
            onActiveFocusChanged: if (activeFocus) selectAll()
            onEditingFinished: text = LiveMessages.pad2(nf.value)
        }
    }

    component TextBox: Rectangle {
        id: tb
        property alias text: tbInput.text
        property string placeholder: ""
        implicitHeight: 40
        radius: 0
        color: Theme.color.canvas
        border.color: tbInput.activeFocus ? Theme.color.brand : Theme.color.borderStrong
        border.width: 1
        Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }
        TextInput {
            id: tbInput
            anchors.fill: parent
            anchors.leftMargin: Theme.space.md
            anchors.rightMargin: Theme.space.md
            verticalAlignment: TextInput.AlignVCenter
            color: Theme.color.textPrimary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.bodySize
            selectByMouse: true
            clip: true
            Text {
                visible: tbInput.text.length === 0
                anchors.verticalCenter: parent.verticalCenter
                text: tb.placeholder
                color: Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize
            }
        }
    }

    component FieldLabel: Text {
        color: Theme.color.textSecondary
        font.family: Theme.font.family
        font.pixelSize: Theme.font.smallSize
        font.weight: Theme.font.weightMedium
    }

    // ── Content ─────────────────────────────────────────────────────────
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.space.lg
        spacing: Theme.space.lg

        // Mode picker
        SegmentedControl {
            Layout.fillWidth: true
            options: [
                { value: "countdown", label: qsTr("Countdown") },
                { value: "countup",   label: qsTr("Count-up") },
                { value: "clock",     label: qsTr("Clock") },
                { value: "message",   label: qsTr("Message") }
            ]
            current: root.pendingMode
            onChanged: root.pendingMode = v
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Theme.space.xl

            // ── Left: mode-specific inputs ──────────────────────────────
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: Theme.space.md

                StackLayout {
                    Layout.fillWidth: true
                    currentIndex: root._modeIndex(root.pendingMode)

                    // ── Countdown ──
                    ColumnLayout {
                        spacing: Theme.space.md

                        SegmentedControl {
                            Layout.fillWidth: true
                            options: [
                                { value: "duration", label: qsTr("Duration") },
                                { value: "until",    label: qsTr("Until a time") }
                            ]
                            current: root.cdSubMode
                            onChanged: root.cdSubMode = v
                        }

                        // Duration mm:ss
                        RowLayout {
                            visible: root.cdSubMode === "duration"
                            spacing: Theme.space.sm
                            ColumnLayout {
                                spacing: 2
                                FieldLabel { text: qsTr("Minutes") }
                                NumField { id: cdMinField; initial: 5; maxValue: 999 }
                            }
                            Text {
                                text: ":"
                                color: Theme.color.textSecondary
                                font.pixelSize: Theme.font.titleSize + 4
                                Layout.alignment: Qt.AlignBottom
                                Layout.bottomMargin: 8
                            }
                            ColumnLayout {
                                spacing: 2
                                FieldLabel { text: qsTr("Seconds") }
                                NumField { id: cdSecField; initial: 0; maxValue: 59 }
                            }
                        }

                        // Until HH:MM (24-hour)
                        RowLayout {
                            visible: root.cdSubMode === "until"
                            spacing: Theme.space.sm
                            ColumnLayout {
                                spacing: 2
                                FieldLabel { text: qsTr("Hour (0–23)") }
                                NumField { id: cdHourField; initial: 10; maxValue: 23 }
                            }
                            Text {
                                text: ":"
                                color: Theme.color.textSecondary
                                font.pixelSize: Theme.font.titleSize + 4
                                Layout.alignment: Qt.AlignBottom
                                Layout.bottomMargin: 8
                            }
                            ColumnLayout {
                                spacing: 2
                                FieldLabel { text: qsTr("Minute") }
                                NumField { id: cdMinuteField; initial: 30; maxValue: 59 }
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            FieldLabel { text: qsTr("Caption (optional)") }
                            TextBox {
                                id: captionField
                                Layout.fillWidth: true
                                placeholder: qsTr("e.g. Service begins")
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: Theme.space.sm
                            FieldLabel { text: qsTr("When it reaches zero") }
                            SegmentedControl {
                                Layout.fillWidth: true
                                options: [
                                    { value: "hold",    label: qsTr("Hold at 00:00") },
                                    { value: "message", label: qsTr("Show a message") }
                                ]
                                current: root.cdEndMode
                                onChanged: root.cdEndMode = v
                            }
                            TextBox {
                                id: endMsgField
                                visible: root.cdEndMode === "message"
                                Layout.fillWidth: true
                                placeholder: qsTr("e.g. Welcome")
                            }
                        }
                    }

                    // ── Count-up ──
                    ColumnLayout {
                        spacing: Theme.space.md
                        Text {
                            Layout.fillWidth: true
                            text: qsTr("A stopwatch that starts at 00:00 when shown. Use the controls below once it's live.")
                            color: Theme.color.textSecondary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.bodySize
                            wrapMode: Text.Wrap
                        }
                        RowLayout {
                            spacing: Theme.space.sm
                            GhostButton {
                                text: LiveMessages.countupRunning ? qsTr("Pause") : qsTr("Resume")
                                iconName: LiveMessages.countupRunning ? "square" : "play"
                                enabled: LiveMessages.mode === "countup"
                                onClicked: {
                                    if (LiveMessages.countupRunning) LiveMessages.pauseCountup()
                                    else                             LiveMessages.resumeCountup()
                                }
                            }
                            GhostButton {
                                text: qsTr("Reset")
                                iconName: "rotate-ccw"
                                enabled: LiveMessages.mode === "countup"
                                onClicked: LiveMessages.resetCountup()
                            }
                        }
                    }

                    // ── Clock ──
                    ColumnLayout {
                        spacing: Theme.space.md
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.space.md
                            FieldLabel {
                                text: qsTr("24-hour time")
                                Layout.fillWidth: true
                            }
                            ToggleSwitch {
                                value: LiveMessages.clock24h
                                onToggled: LiveMessages.clock24h = !LiveMessages.clock24h
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.space.md
                            FieldLabel {
                                text: qsTr("Show seconds")
                                Layout.fillWidth: true
                            }
                            ToggleSwitch {
                                value: LiveMessages.clockShowSeconds
                                onToggled: LiveMessages.clockShowSeconds = !LiveMessages.clockShowSeconds
                            }
                        }
                    }

                    // ── Message ──
                    ColumnLayout {
                        spacing: Theme.space.md
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            FieldLabel { text: qsTr("Message") }
                            TextBox {
                                id: msgField
                                Layout.fillWidth: true
                                placeholder: qsTr("Type a message…")
                            }
                        }
                        FieldLabel { text: qsTr("Quick messages") }
                        Flow {
                            Layout.fillWidth: true
                            spacing: Theme.space.sm
                            Repeater {
                                model: LiveMessages.presets
                                delegate: Rectangle {
                                    required property var modelData
                                    radius: 0
                                    color: presetMa.containsMouse ? Theme.color.overlay
                                                                  : Theme.color.raised
                                    border.color: Theme.color.borderSubtle
                                    border.width: 1
                                    implicitWidth: presetText.implicitWidth + Theme.space.md * 2
                                    implicitHeight: 28
                                    Text {
                                        id: presetText
                                        anchors.centerIn: parent
                                        text: parent.modelData
                                        color: Theme.color.textPrimary
                                        font.family: Theme.font.family
                                        font.pixelSize: Theme.font.smallSize
                                        elide: Text.ElideRight
                                    }
                                    MouseArea {
                                        id: presetMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: msgField.text = parent.modelData
                                    }
                                }
                            }
                        }
                    }
                }

                Item { Layout.fillHeight: true }   // push style block toward bottom

                // ── Style (applies live) ────────────────────────────────
                Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    FieldLabel { text: qsTr("Position") }
                    SegmentedControl {
                        Layout.fillWidth: true
                        options: [
                            { value: "top",    label: qsTr("Top") },
                            { value: "center", label: qsTr("Center") },
                            { value: "bottom", label: qsTr("Bottom") }
                        ]
                        current: LiveMessages.position
                        onChanged: LiveMessages.position = v
                    }
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    FieldLabel { text: qsTr("Background") }
                    SegmentedControl {
                        Layout.fillWidth: true
                        options: [
                            { value: "none",  label: qsTr("None") },
                            { value: "dim",   label: qsTr("Dim") },
                            { value: "solid", label: qsTr("Solid") }
                        ]
                        current: LiveMessages.background
                        onChanged: LiveMessages.background = v
                    }
                }
            }

            // ── Right: live preview ─────────────────────────────────────
            ColumnLayout {
                Layout.preferredWidth: 300
                Layout.fillHeight: true
                spacing: Theme.space.sm

                FieldLabel { text: qsTr("Preview") }

                // 16:9 screen mock. A mid-dark fill stands in for live content
                // so "None" / "Dim" / "Solid" backdrops read differently.
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: width * 9 / 16
                    color: "#26262b"
                    border.color: Theme.color.borderStrong
                    border.width: 1
                    clip: true

                    LiveOverlayLayer {
                        anchors.fill: parent
                        mode:                root.pendingMode
                        message:             msgField.text
                        countdownTargetMs:   root._previewCountdownTarget
                        caption:             captionField.text
                        countdownEndMode:    root.cdEndMode
                        countdownEndMessage: endMsgField.text
                        // count-up preview is a static 00:00 (defaults)
                        countupStartMs:      0
                        countupAccumMs:      0
                        countupRunning:      false
                        clock24h:            LiveMessages.clock24h
                        clockShowSeconds:    LiveMessages.clockShowSeconds
                        position:            LiveMessages.position
                        background:          LiveMessages.background
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.space.sm
                    Rectangle {
                        Layout.preferredWidth: 8
                        Layout.preferredHeight: 8
                        Layout.alignment: Qt.AlignVCenter
                        radius: 4
                        color: LiveMessages.active ? Theme.color.live : Theme.color.textDisabled
                    }
                    Text {
                        Layout.fillWidth: true
                        text: LiveMessages.active
                              ? qsTr("On screen — %1").arg(root._liveLabel(LiveMessages.mode))
                              : qsTr("Nothing on screen")
                        color: LiveMessages.active ? Theme.color.textPrimary : Theme.color.textTertiary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                        elide: Text.ElideRight
                    }
                }

                Item { Layout.fillHeight: true }
            }
        }

        // ── Footer actions ──────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space.sm

            GhostButton {
                text: qsTr("Hide overlay")
                iconName: "eye-off"
                enabled: LiveMessages.active
                onClicked: LiveMessages.hide()
            }

            Item { Layout.fillWidth: true }

            GhostButton {
                text: qsTr("Close")
                onClicked: AppState.closeModal()
            }
            PrimaryButton {
                variant: "live"
                iconName: "cast"
                text: qsTr("Show on screen")
                // A message needs text; timers/clock are always valid.
                enabled: root.pendingMode !== "message" || msgField.text.trim().length > 0
                onClicked: root._show()
            }
        }
    }

    function _liveLabel(m) {
        switch (m) {
        case "countdown": return qsTr("Countdown")
        case "countup":   return qsTr("Count-up")
        case "clock":     return qsTr("Clock")
        case "message":   return qsTr("Message")
        }
        return ""
    }
}
