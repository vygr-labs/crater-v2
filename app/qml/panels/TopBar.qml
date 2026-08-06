import QtQuick

// Top chrome — left cluster (Schedule dropdown, settings gear, NDI
// blank chip, NDI overdue alert) and right cluster (Logo, Clear,
// Go Live). Each button calls into AppState; the heavy modal/popover
// rendering happens in ModalLayer.
Rectangle {
    id: root

    height: Theme.size.topBarHeight
    color: Theme.color.elevated

    // ── NDI "still on" reminder state ───────────────────────────────────
    // Tracks how long the broadcast has been visible (NdiService.sending
    // AND !NdiService.blank). The overdue chip below binds to this so the
    // operator gets a passive nudge when an NDI image has been on screen
    // long enough that it's probably forgotten rather than intentional.
    //
    // Threshold: 5 minutes. Most single-slide segments (song stanza,
    // scripture, transition card) clear within that window. A sermon
    // outline can absolutely sit longer than 5 min, in which case the
    // chip becomes background and the operator ignores or clicks it.
    // Tuned via the readonly property below — change here, not in a
    // settings dialog (this is a one-knob deliberate nudge, not a
    // configurable preference).
    //
    // The "now" timestamp is refreshed by a 10 s Timer rather than
    // bound to Date.now() in the elapsed binding. Reason: a binding on
    // Date.now() would only re-evaluate when an explicit dep changed —
    // there's no way for the engine to know "the clock advanced". The
    // Timer is the explicit dep; ticking it sets _nowMs and every
    // binding that reads _nowMs re-runs. 10 s cadence is invisibly
    // late for a 5 min threshold and saves ~30k Date.now() reads/min
    // vs ticking every frame.
    property double _ndiVisibleSinceMs: 0
    property double _nowMs: Date.now()
    readonly property int _ndiOverdueThresholdMs: 5 * 60 * 1000

    readonly property bool _ndiOverdue:
        _ndiVisibleSinceMs > 0
        && (_nowMs - _ndiVisibleSinceMs) >= _ndiOverdueThresholdMs
    readonly property int _ndiVisibleMinutes:
        _ndiVisibleSinceMs > 0
            ? Math.floor((_nowMs - _ndiVisibleSinceMs) / 60000)
            : 0

    // Imperative recompute on either of the two trigger inputs flipping.
    // Captures the start-of-visibility timestamp once, then leaves it
    // alone until visibility ends — that way the elapsed binding is
    // monotonic and doesn't reset to 0 on every blank-change tick.
    function _recomputeNdiSince() {
        const visible = NdiService.sending && !NdiService.blank
        if (visible && _ndiVisibleSinceMs === 0) {
            _ndiVisibleSinceMs = Date.now()
            _nowMs = _ndiVisibleSinceMs   // immediate sync, no 10 s wait
        } else if (!visible) {
            _ndiVisibleSinceMs = 0
        }
    }

    Component.onCompleted: _recomputeNdiSince()

    Connections {
        target: NdiService
        function onSendingChanged() { root._recomputeNdiSince() }
        function onBlankChanged()   { root._recomputeNdiSince() }
    }

    Timer {
        // Only runs while we're actually counting — stops the moment
        // visibility ends so the topbar isn't burning a 10 s wakeup
        // forever once NDI is off.
        interval: 10 * 1000
        repeat: true
        running: root._ndiVisibleSinceMs > 0
        onTriggered: root._nowMs = Date.now()
    }

    // Bottom hairline
    Rectangle {
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 1
        color: Theme.color.borderSubtle
    }

    // ── Left cluster ────────────────────────────────────────────────────
    Row {
        anchors.left: parent.left
        anchors.leftMargin: Theme.space.lg
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.space.sm

        PillButton {
            id: schedulePill
            anchors.verticalCenter: parent.verticalCenter
            iconName: "file-text"
            text: qsTr("Schedule")
            hasChevron: true
            active: AppState.activeModal === "scheduleDropdown"
            onClicked: {
                // Map button-bottom-left to window coords so ModalLayer
                // (anchored to the window content item) can position itself
                // correctly regardless of the TopBar's offset.
                const p = schedulePill.mapToItem(null, 0, schedulePill.height + 4)
                AppState.openModal("scheduleDropdown", { anchorX: p.x, anchorY: p.y })
            }
        }

        // Settings gear — inline bordered square chip matching the adjacent
        // PillButtons / GhostButtons. Kept inline rather than reusing
        // IconButton because that atom is shared across 14 surfaces (editor
        // toolbars, dialogs, tile menus) and changing its default chrome
        // would ripple far beyond the topbar.
        Rectangle {
            id: settingsChip
            anchors.verticalCenter: parent.verticalCenter
            height: 34
            width:  34
            color: settingsMa.containsMouse ? Theme.color.overlay
                                            : "transparent"
            border.color: Theme.color.borderStrong
            border.width: 1
            Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

            AppIcon {
                anchors.centerIn: parent
                name: "settings"
                color: Theme.color.textSecondary
                size: Theme.icon.md
            }
            MouseArea {
                id: settingsMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: AppState.openModal("settings", {})
            }
        }

        // NDI blank / restore — explicit opacity-0 toggle for the broadcast
        // scene. Lives next to Settings because both are "occasional output
        // controls"; chrome matches settingsChip (34px tall, borderStrong
        // rest, overlay hover) but is a width-fit pill with an inline
        // label, giving the operator a more findable target than a bare
        // icon in a busy cluster. Active state lights up in live-red —
        // same idiom as Clear in the right cluster.
        //
        // Label orientation: action-first ("Hide NDI" / "Show NDI") rather
        // than state-first. The accompanying eye / eye-off icon still
        // describes the CURRENT state (same rule as Clear), but the words
        // a tense operator reads under pressure should describe what a
        // click will DO — that's the whole point of widening this control
        // from a glyph to a labelled pill.
        //
        // Visible only when the NDI runtime is loaded — the existing NDI
        // status pill in the right cluster uses the same gate, so the two
        // appear and disappear together.
        Rectangle {
            id: ndiBlankChip
            visible: NdiService.available
            anchors.verticalCenter: parent.verticalCenter
            height: 34
            width:  ndiBlankRow.implicitWidth + Theme.space.lg * 2

            // Three-state palette:
            //   • blank          → live-red (broadcast is being suppressed; same
            //                       red family as the Clear control)
            //   • streaming, not blank → mixer cyan border + icon + text only;
            //                             background stays neutral so the chip
            //                             doesn't visually compete with the
            //                             right-cluster NDI status pill which
            //                             is the actual "on the wire" indicator
            //   • idle           → neutral chrome matching settingsChip
            // Order matters: `blank` wins over `sending` so the suppression
            // signal is unambiguous even mid-broadcast.
            readonly property bool _streaming: NdiService.sending && !NdiService.blank
            color: NdiService.blank      ? Theme.color.liveSubtle
                 : ndiBlankMa.containsMouse ? Theme.color.overlay
                                            : "transparent"
            border.color: NdiService.blank ? Theme.color.live
                       : _streaming        ? Theme.color.brandHover
                                            : Theme.color.borderStrong
            border.width: 1
            Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
            Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }

            Row {
                id: ndiBlankRow
                anchors.centerIn: parent
                spacing: Theme.space.sm

                AppIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: NdiService.blank ? "eye-off" : "eye"
                    color: NdiService.blank   ? Theme.color.live
                         : ndiBlankChip._streaming ? Theme.color.brandHover
                                                    : Theme.color.textSecondary
                    size: Theme.icon.sm
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: NdiService.blank ? qsTr("Show NDI") : qsTr("Hide NDI")
                    color: NdiService.blank   ? Theme.color.live
                         : ndiBlankChip._streaming ? Theme.color.brandHover
                                                    : Theme.color.textPrimary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                    font.weight: Theme.font.weightMedium
                }
            }
            MouseArea {
                id: ndiBlankMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: NdiService.blank = !NdiService.blank
            }
        }

        // Narration arm / disarm (docs/narration.md). The ONLY route by which
        // Crater's microphone opens: §8 forbids arming on app start, schedule
        // load, or go-live, and there is deliberately no setting that changes
        // that. If this control has not been clicked, the room is not being
        // heard.
        //
        // Hidden entirely in builds without speech support rather than shown
        // disabled — a permanently dead control in the top bar is noise, and
        // the Settings > Narration page explains the absence for anyone who
        // goes looking.
        //
        // While armed this chip is only the secondary indicator; the primary
        // one is the full-width red NarrationBar directly below, which is what
        // §8's "obvious from across the room" requirement actually needs.
        Rectangle {
            id: micChip
            visible: NarrationService.available
            anchors.verticalCenter: parent.verticalCenter
            height: 34
            width:  micRow.implicitWidth + Theme.space.lg * 2

            readonly property bool _hot:  NarrationService.listening
            readonly property bool _busy: NarrationService.engineState === "loading"

            color: _hot ? Theme.color.liveSubtle
                 : micMa.containsMouse ? Theme.color.overlay
                                       : "transparent"
            border.color: _hot ? Theme.color.live : Theme.color.borderStrong
            border.width: 1
            Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
            Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }

            Row {
                id: micRow
                anchors.centerIn: parent
                spacing: Theme.space.sm

                AppIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: micChip._hot ? "mic" : "mic-off"
                    color: micChip._hot ? Theme.color.live : Theme.color.textSecondary
                    size: Theme.icon.sm
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    // Action-first, matching the NDI chip beside it: the words
                    // describe what a click will DO, the glyph describes the
                    // current state.
                    text: micChip._hot  ? qsTr("Stop Listening")
                        : micChip._busy ? qsTr("Starting...")
                                        : qsTr("Listen")
                    color: micChip._hot ? Theme.color.live : Theme.color.textPrimary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                    font.weight: Theme.font.weightMedium
                }
            }
            MouseArea {
                id: micMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    if (micChip._hot || micChip._busy) {
                        NarrationService.disarm()
                        return
                    }
                    // arm() returns false with a reason in statusMessage —
                    // no model configured, no microphone, or a build without
                    // speech support. Send the operator where the fix is
                    // rather than leaving them to hunt for it.
                    if (!NarrationService.arm()) {
                        AppState.settingsSection = "narration"
                        AppState.openModal("settings", {})
                    }
                }
            }
        }

        // NDI overdue alert — appears when the broadcast has been visible
        // (NdiService.sending AND !NdiService.blank) past
        // _ndiOverdueThresholdMs. Reads as a red-tinted pill — same
        // family as the LIVE indicator in LivePanel — and is itself
        // clickable: a click sets NdiService.blank = true, which both
        // dims the broadcast AND removes the alert as a side effect (the
        // visibility binding tracks !blank). So the same control is both
        // the warning and the remedy. The minute readout updates with
        // the 10 s Timer's tick; operators don't need second precision
        // for a "you've been on ≥ 5 min" reminder.
        Rectangle {
            id: ndiOverdueAlert
            visible: root._ndiOverdue
            anchors.verticalCenter: parent.verticalCenter
            height: 28
            width:  alertRow.implicitWidth + Theme.space.md * 2
            radius: 0
            color: Theme.color.liveSubtle
            border.color: Theme.color.live
            border.width: 1

            // Subtle pulse to draw the eye without thrashing — the
            // operator should notice the chip on first sweep, not have
            // it disco-strobing in their peripheral vision through a
            // whole sermon.
            SequentialAnimation on opacity {
                running: ndiOverdueAlert.visible
                loops: Animation.Infinite
                NumberAnimation { from: 1.0; to: 0.6; duration: 1400; easing.type: Easing.InOutQuad }
                NumberAnimation { from: 0.6; to: 1.0; duration: 1400; easing.type: Easing.InOutQuad }
            }

            Row {
                id: alertRow
                anchors.centerIn: parent
                spacing: Theme.space.xs

                AppIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "alert-triangle"
                    color: Theme.color.live
                    size: Theme.icon.sm
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("NDI on %1 min — clear?").arg(root._ndiVisibleMinutes)
                    color: Theme.color.textPrimary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                    font.weight: Theme.font.weightMedium
                }
            }

            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: NdiService.blank = true
            }
        }
    }

    // ── Right cluster ───────────────────────────────────────────────────
    Row {
        anchors.right: parent.right
        anchors.rightMargin: Theme.space.lg
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.space.sm

        // NDI status chip. Only present when the NDI runtime is available
        // (Tools/Runtime installed). Clicking toggles broadcast. The icon
        // colour cascades through three states:
        //   • on-air (PGM)  → live red — somebody has us on their program output
        //   • on-preview    → champagne — somebody has us in their preview slot
        //   • broadcasting  → brand green — sending but nobody's looking yet
        //   • idle          → text secondary — runtime ready, not sending
        // Tooltip caption mirrors the dialog's diagnostic so the operator
        // can hover for the full state without opening Settings.
        GhostButton {
            anchors.verticalCenter: parent.verticalCenter
            iconName: "radio"
            text: qsTr("NDI")
            visible: NdiService.available
            active: NdiService.sending
            iconColor: NdiService.onProgram ? Theme.color.live
                     : NdiService.onPreview ? Theme.color.preview
                     : NdiService.sending    ? Theme.color.brand
                                             : Theme.color.textSecondary
            onClicked: {
                if (NdiService.sending) NdiService.stop()
                else                    NdiService.start()
            }
        }

        GhostButton {
            anchors.verticalCenter: parent.verticalCenter
            iconName: "image"
            text: qsTr("Logo")
            active: AppState.showLogo
            onClicked: AppState.toggleLogo()
        }

        GhostButton {
            anchors.verticalCenter: parent.verticalCenter
            iconName: "eye-off"
            text: qsTr("Clear")
            active: AppState.isClear
            onClicked: AppState.clearLive()
        }

        // Go Live / End Live — the console's primary action. Inlined rather
        // than the shared PrimaryButton: that atom is a solid-accent fill
        // reused across dialogs and empty states, and this control wants a
        // one-off pale-cyan tonal surface plus a second, outlined-red "End
        // Live" face. Same reasoning as the settings chip above — a bespoke
        // topbar control gets a bespoke definition rather than bending a
        // widely-shared atom.
        //
        // Two faces, driven by OutputService.projectionOpen (the authoritative
        // "is the audience window up?" signal — see ProjectionWindow.qml):
        //   • projection closed → "Go Live": pale-cyan filled button that OPENS
        //                          the audience window. It does NOT push preview
        //                          to live — committing content is Enter / a
        //                          double-click (see AppState.openProjector).
        //   • projection open   → "End Live": transparent fill, red outline,
        //                          red label; clicking lowers the projector.
        Rectangle {
            id: goLiveBtn
            anchors.verticalCenter: parent.verticalCenter
            height: 36
            width: goLiveRow.implicitWidth + Theme.space.xl * 2
            radius: 0   // squared — app-wide button shape (see PrimaryButton)

            // True once the audience projection window is actually up — the
            // button then flips to its "End Live" face. Kept as one control
            // (not two) so it holds a stable slot in the right cluster and
            // the operator's "the live button lives here" muscle memory
            // survives both states.
            readonly property bool ending: OutputService.projectionOpen

            // Always actionable. Go Live just opens the audience window
            // (content is committed separately via Enter / double-click), so
            // there's no "stage something first" gate; End Live must always be
            // able to drop the projector. The button therefore never disables.
            enabled: true

            // Two surfaces. Go Live: pale-cyan tonal fill — hover lifts toward
            // white, press sinks a shade, disabled darkens flat and leans on
            // `opacity`. End Live: transparent at rest, with a faint red wash
            // on hover/press so the outlined button still feels pressable
            // (rgba == Theme.color.live at low alpha — same idiom as LivePanel).
            color: ending
                 ? (goLiveMa.pressed       ? Qt.rgba(177/255, 54/255, 52/255, 0.20)
                  : goLiveMa.containsMouse ? Qt.rgba(177/255, 54/255, 52/255, 0.12)
                                           : "transparent")
                 : (!enabled               ? Qt.darker("#DCEAEB", 1.6)
                  : goLiveMa.pressed       ? "#C6DCDD"
                  : goLiveMa.containsMouse ? "#ECF3F4"
                                           : "#DCEAEB")
            opacity: enabled ? 1.0 : 0.55

            // Red outline only on the End Live face; Go Live's filled surface
            // carries its own edge, so its border stays 0-width (invisible).
            border.width: ending ? 1 : 0
            border.color: Theme.color.live

            Behavior on color   { ColorAnimation  { duration: Theme.motion.instant } }
            Behavior on opacity { NumberAnimation { duration: Theme.motion.instant } }

            Row {
                id: goLiveRow
                anchors.centerIn: parent
                spacing: Theme.space.sm

                AppIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    // `x` doubles as the app's "kill the output" glyph (it's
                    // the LivePanel "Clear output" icon), so it reads cleanly
                    // on End Live; `play` is the Go Live "start" symbol.
                    name: goLiveBtn.ending ? "x" : "play"
                    // Go Live: deep cyan (brandPressed) on the pale fill —
                    // ~6:1, comfortably past the AA contrast floor. End Live:
                    // live red, matching the outline.
                    color: goLiveBtn.ending ? Theme.color.live
                                            : Theme.color.brandPressed
                    size: Theme.icon.sm
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: goLiveBtn.ending ? qsTr("End Live") : qsTr("Go Live")
                    color: goLiveBtn.ending ? Theme.color.live
                                            : Theme.color.brandPressed
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize
                    font.weight: Theme.font.weightSemiBold
                    font.letterSpacing: 0.3
                }
            }

            MouseArea {
                id: goLiveMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: goLiveBtn.enabled ? Qt.PointingHandCursor
                                               : Qt.ArrowCursor
                // Go Live opens the audience window WITHOUT pushing preview to
                // live (that's Enter / double-click); End Live lowers it. Both
                // route through AppState so `projectorVisible` stays the single
                // source of truth (see AppState.openProjector / endLive).
                onClicked: {
                    if (goLiveBtn.ending) AppState.endLive()
                    else                  AppState.openProjector()
                }
            }
        }
    }
}
