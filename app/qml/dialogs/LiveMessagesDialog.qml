import QtQuick
import QtQuick.Layouts
import Crater

// Timers and messages for the audience screen (LiveMessages, drawn by
// LiveOverlayLayer). Opened from the top bar's Messages button or
// Ctrl+Shift+M.
//
// What to show is only sent when the operator presses Show, so switching tabs
// or typing never disturbs what is already up. Where it sits, the background
// and the clock format change the overlay straight away: they are adjustments
// to what is on screen, and seeing them land is the point.
//
// The preview is a real LiveOverlayLayer fed from this dialog's fields, so it
// matches what Show will put up.
ModalShell {
    id: root

    dialogWidth: 780
    dialogHeight: 640
    title: qsTr("Timers and messages")

    // The tab being edited, independent of what is on screen. Set once on
    // open (below), not bound, so hiding the overlay does not switch tabs.
    property string pendingMode: "countdown"
    property string cdSubMode: "duration"    // "duration" | "until"
    property string cdEndMode: "hold"        // "hold" | "message"

    readonly property var _modeOrder: ["countdown", "countup", "clock", "message"]

    // The preview's own clock, for the two tabs whose preview moves (a
    // countdown to a time of day and the clock). Gone with the dialog.
    property real now: Date.now()
    Timer {
        interval: 250
        repeat: true
        running: root.pendingMode === "clock"
                 || (root.pendingMode === "countdown" && root.cdSubMode === "until")
        onTriggered: root.now = Date.now()
    }

    readonly property int _durationSeconds: cdMinField.value * 60 + cdSecField.value

    readonly property string _previewText: {
        switch (pendingMode) {
        case "countdown":
            if (cdSubMode === "duration")
                return LiveMessages.formatDuration(_durationSeconds)
            return LiveMessages.formatDuration(Math.ceil(
                (LiveMessages.untilTarget(cdHourField.value, cdMinuteField.value, now) - now) / 1000))
        case "countup": return LiveMessages.formatDuration(0)
        case "clock":   return LiveMessages.clockText(now, LiveMessages.clock24h, LiveMessages.clockShowSeconds)
        case "message": return msgField.text.trim()
        }
        return ""
    }

    readonly property bool _canShow:
        pendingMode === "message"   ? msgField.text.trim().length > 0
      : pendingMode === "countdown" ? (cdSubMode === "until" || _durationSeconds > 0)
                                    : true

    function _show() {
        if (!_canShow) return
        switch (pendingMode) {
        case "countdown": {
            const endMessage = cdEndMode === "message" ? endMsgField.text : ""
            if (cdSubMode === "duration")
                LiveMessages.startCountdown(_durationSeconds, captionField.text, endMessage)
            else
                LiveMessages.startCountdownUntil(cdHourField.value, cdMinuteField.value,
                                                 captionField.text, endMessage)
            break
        }
        case "countup": LiveMessages.startCountup(); break
        case "clock":   LiveMessages.showClock(); break
        case "message": LiveMessages.showMessage(msgField.text.trim()); break
        }
    }

    function _modeLabel(m) {
        switch (m) {
        case "countdown": return qsTr("Countdown")
        case "countup":   return qsTr("Count up")
        case "clock":     return qsTr("Clock")
        case "message":   return qsTr("Message")
        }
        return ""
    }

    // Put the caret in the first field of the tab, so the operator can type
    // straight away and Enter shows it. Deferred a tick so it lands after
    // the Loader has finished building the dialog (see NamingDialog).
    function _focusFirstField() {
        Qt.callLater(function() {
            if (root.pendingMode === "message")
                msgField.focusInput()
            else if (root.pendingMode === "countdown")
                (root.cdSubMode === "duration" ? cdMinField : cdHourField).focusInput()
        })
    }
    onPendingModeChanged: _focusFirstField()
    onCdSubModeChanged: _focusFirstField()

    Component.onCompleted: {
        // Reopening with something up starts from it.
        if (LiveMessages.active) pendingMode = LiveMessages.mode
        if (LiveMessages.active && LiveMessages.mode === "message")
            msgField.text = LiveMessages.message
        if (LiveMessages.active && LiveMessages.mode === "countdown") {
            captionField.text = LiveMessages.caption
            if (LiveMessages.countdownEndMode === "message") {
                root.cdEndMode = "message"
                endMsgField.text = LiveMessages.countdownEndMessage
            }
        }
        _focusFirstField()
    }

    // ── Inline inputs ───────────────────────────────────────────────────
    // A two or three digit number box. Up and Down step it.
    component NumField: Rectangle {
        id: nf
        property int value: initial
        property int maxValue: 59
        property int initial: 0
        signal accepted()
        function focusInput() { nfInput.forceActiveFocus(); nfInput.selectAll() }

        implicitWidth: 72
        implicitHeight: 44
        radius: 0
        color: Theme.color.canvas
        border.color: nfInput.activeFocus ? Theme.color.brand : Theme.color.borderStrong
        border.width: 1

        function _set(v) {
            nf.value = Math.max(0, Math.min(nf.maxValue, v))
            nfInput.text = LiveMessages.pad2(nf.value)
            nfInput.selectAll()
        }

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
            font.features: { "tnum": 1 }
            selectByMouse: true
            activeFocusOnTab: true
            maximumLength: String(nf.maxValue).length
            validator: IntValidator { bottom: 0; top: nf.maxValue }
            text: LiveMessages.pad2(nf.initial)
            onTextChanged: {
                const v = parseInt(text, 10)
                nf.value = isNaN(v) ? 0 : Math.min(v, nf.maxValue)
            }
            onActiveFocusChanged: if (activeFocus) selectAll()
            onEditingFinished: text = LiveMessages.pad2(nf.value)
            onAccepted: nf.accepted()
            Keys.onUpPressed:   nf._set(nf.value + 1)
            Keys.onDownPressed: nf._set(nf.value - 1)
            HoverHandler { cursorShape: Qt.IBeamCursor }
        }
    }

    component TextBox: Rectangle {
        id: tb
        property alias text: tbInput.text
        property string placeholder: ""
        signal accepted()
        function focusInput() { tbInput.forceActiveFocus(); tbInput.selectAll() }

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
            activeFocusOnTab: true
            maximumLength: 200
            clip: true
            onAccepted: tb.accepted()
            HoverHandler { cursorShape: Qt.IBeamCursor }

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

    component Hint: Text {
        Layout.fillWidth: true
        color: Theme.color.textTertiary
        font.family: Theme.font.family
        font.pixelSize: Theme.font.smallSize
        wrapMode: Text.Wrap
    }

    // ── Content ─────────────────────────────────────────────────────────
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.space.lg
        spacing: Theme.space.lg

        SegmentedControl {
            Layout.fillWidth: true
            options: [
                { value: "countdown", label: root._modeLabel("countdown") },
                { value: "countup",   label: root._modeLabel("countup") },
                { value: "clock",     label: root._modeLabel("clock") },
                { value: "message",   label: root._modeLabel("message") }
            ]
            current: root.pendingMode
            onChanged: function(v) { root.pendingMode = v }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Theme.space.xl

            // ── Left: what to show, then where ──────────────────────────
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumWidth: 260
                spacing: Theme.space.md

                StackLayout {
                    Layout.fillWidth: true
                    currentIndex: Math.max(0, root._modeOrder.indexOf(root.pendingMode))

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
                            onChanged: function(v) { root.cdSubMode = v }
                        }

                        RowLayout {
                            visible: root.cdSubMode === "duration"
                            spacing: Theme.space.sm
                            ColumnLayout {
                                spacing: 2
                                FieldLabel { text: qsTr("Minutes") }
                                NumField {
                                    id: cdMinField
                                    initial: 5
                                    maxValue: 999
                                    onAccepted: root._show()
                                }
                            }
                            FieldLabel {
                                text: ":"
                                font.pixelSize: Theme.font.titleSize + 4
                                Layout.alignment: Qt.AlignBottom
                                Layout.bottomMargin: 8
                            }
                            ColumnLayout {
                                spacing: 2
                                FieldLabel { text: qsTr("Seconds") }
                                NumField {
                                    id: cdSecField
                                    initial: 0
                                    maxValue: 59
                                    onAccepted: root._show()
                                }
                            }
                        }

                        ColumnLayout {
                            visible: root.cdSubMode === "until"
                            spacing: Theme.space.xs
                            RowLayout {
                                spacing: Theme.space.sm
                                ColumnLayout {
                                    spacing: 2
                                    FieldLabel { text: qsTr("Hour") }
                                    NumField {
                                        id: cdHourField
                                        initial: 10
                                        maxValue: 23
                                        onAccepted: root._show()
                                    }
                                }
                                FieldLabel {
                                    text: ":"
                                    font.pixelSize: Theme.font.titleSize + 4
                                    Layout.alignment: Qt.AlignBottom
                                    Layout.bottomMargin: 8
                                }
                                ColumnLayout {
                                    spacing: 2
                                    FieldLabel { text: qsTr("Minute") }
                                    NumField {
                                        id: cdMinuteField
                                        initial: 30
                                        maxValue: 59
                                        onAccepted: root._show()
                                    }
                                }
                            }
                            Hint {
                                text: qsTr("24-hour time. If it has already passed today, it counts to tomorrow.")
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            FieldLabel { text: qsTr("Caption (optional)") }
                            TextBox {
                                id: captionField
                                Layout.fillWidth: true
                                placeholder: qsTr("For example, Service begins in")
                                onAccepted: root._show()
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: Theme.space.sm
                            FieldLabel { text: qsTr("At zero") }
                            SegmentedControl {
                                Layout.fillWidth: true
                                options: [
                                    { value: "hold",    label: qsTr("Stay on 00:00") },
                                    { value: "message", label: qsTr("Show a message") }
                                ]
                                current: root.cdEndMode
                                onChanged: function(v) {
                                    root.cdEndMode = v
                                    if (v === "message") endMsgField.focusInput()
                                }
                            }
                            TextBox {
                                id: endMsgField
                                visible: root.cdEndMode === "message"
                                Layout.fillWidth: true
                                placeholder: qsTr("For example, Welcome")
                                onAccepted: root._show()
                            }
                        }
                    }

                    // ── Count up ──
                    ColumnLayout {
                        spacing: Theme.space.md
                        Hint {
                            text: qsTr("Starts at 00:00 when you show it. Pause, resume or reset it here while it is on screen.")
                        }
                        RowLayout {
                            spacing: Theme.space.sm
                            GhostButton {
                                text: LiveMessages.countupRunning ? qsTr("Pause") : qsTr("Resume")
                                iconName: LiveMessages.countupRunning ? "pause" : "play"
                                enabled: LiveMessages.active && LiveMessages.mode === "countup"
                                onClicked: {
                                    if (LiveMessages.countupRunning) LiveMessages.pauseCountup()
                                    else                             LiveMessages.resumeCountup()
                                }
                            }
                            GhostButton {
                                text: qsTr("Reset")
                                iconName: "rotate-ccw"
                                enabled: LiveMessages.active && LiveMessages.mode === "countup"
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
                            FieldLabel { text: qsTr("24-hour time"); Layout.fillWidth: true }
                            ToggleSwitch {
                                value: LiveMessages.clock24h
                                onToggled: LiveMessages.clock24h = !LiveMessages.clock24h
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.space.md
                            FieldLabel { text: qsTr("Show seconds"); Layout.fillWidth: true }
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
                                placeholder: qsTr("Type a message")
                                onAccepted: root._show()
                            }
                        }
                        FieldLabel { text: qsTr("Quick messages") }
                        Flow {
                            Layout.fillWidth: true
                            spacing: Theme.space.sm
                            Repeater {
                                model: LiveMessages.presets
                                delegate: Rectangle {
                                    id: chip
                                    required property var modelData
                                    radius: 0
                                    color: chipMa.containsMouse ? Theme.color.overlay : Theme.color.raised
                                    border.color: Theme.color.borderSubtle
                                    border.width: 1
                                    width: Math.min(chipText.implicitWidth + Theme.space.md * 2, parent.width)
                                    height: 28
                                    Text {
                                        id: chipText
                                        anchors.fill: parent
                                        anchors.leftMargin: Theme.space.md
                                        anchors.rightMargin: Theme.space.md
                                        verticalAlignment: Text.AlignVCenter
                                        text: chip.modelData
                                        color: Theme.color.textPrimary
                                        font.family: Theme.font.family
                                        font.pixelSize: Theme.font.smallSize
                                        elide: Text.ElideRight
                                    }
                                    MouseArea {
                                        id: chipMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            msgField.text = chip.modelData
                                            msgField.focusInput()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Item { Layout.fillHeight: true }

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
                        onChanged: function(v) { LiveMessages.position = v }
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
                        onChanged: function(v) { LiveMessages.background = v }
                    }
                }
            }

            // ── Right: preview ──────────────────────────────────────────
            ColumnLayout {
                Layout.preferredWidth: 280
                Layout.maximumWidth: 280
                Layout.fillHeight: true
                spacing: Theme.space.sm

                FieldLabel { text: qsTr("Preview") }

                // A grey stand-in for the live slide, so None, Dim and Solid
                // read differently.
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: width * 9 / 16
                    color: "#3a3a40"
                    border.color: Theme.color.borderStrong
                    border.width: 1
                    clip: true

                    LiveOverlayLayer {
                        id: previewLayer
                        anchors.fill: parent
                        anchors.margins: 1
                        shown:      true
                        text:       root._previewText
                        caption:    root.pendingMode === "countdown" ? captionField.text : ""
                        isMessage:  root.pendingMode === "message"
                        position:   LiveMessages.position
                        background: LiveMessages.background
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
                        id: statusText
                        Layout.fillWidth: true
                        text: LiveMessages.active
                              ? qsTr("On screen: %1").arg(root._modeLabel(LiveMessages.mode))
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

        // ── Footer ──────────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space.sm

            GhostButton {
                text: qsTr("Hide")
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
                id: showButton
                variant: "live"
                iconName: "cast"
                text: qsTr("Show on screen")
                enabled: root._canShow
                onClicked: root._show()
            }
        }
    }
}
