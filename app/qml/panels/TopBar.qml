import QtQuick

// Top chrome — left cluster (Schedule dropdown, settings gear, Import)
// and right cluster (Logo, Clear, Go Live). Each button calls into
// AppState; the heavy modal/popover rendering happens in ModalLayer.
Rectangle {
    id: root

    height: Theme.size.topBarHeight
    color: Theme.color.elevated

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

        Item { width: Theme.space.md; height: 1 }

        PillButton {
            anchors.verticalCenter: parent.verticalCenter
            iconName: "arrow-up-right"
            text: qsTr("Import")
            onClicked: AppState.openModal("import", {})
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
        //   • projection closed → "Go Live": pale-cyan filled commit button.
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

            // Go Live needs something staged in Preview — a schedule selection
            // or a library item the operator is staging. End Live is always
            // actionable: the operator must be able to drop the projector
            // regardless of what (if anything) is currently staged.
            enabled: ending
                  || AppState.selectedScheduleIndex >= 0
                  || AppState.libraryPreviewItem !== null

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
                // Go Live raises the projector; End Live lowers it. Both route
                // through AppState so `projectorVisible` stays the single
                // source of truth (see AppState.goLive / endLive).
                onClicked: {
                    if (goLiveBtn.ending) AppState.endLive()
                    else                  AppState.goLive()
                }
            }
        }
    }
}
