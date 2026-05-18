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

        IconButton {
            anchors.verticalCenter: parent.verticalCenter
            iconName: "settings"
            iconSize: Theme.icon.md
            onClicked: AppState.openModal("settings", {})
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

        PrimaryButton {
            anchors.verticalCenter: parent.verticalCenter
            variant: "live"
            iconName: "play"
            text: qsTr("Go Live")
            // Enabled when something is queued in Preview — either a schedule
            // selection or a library item the operator is staging.
            enabled: AppState.selectedScheduleIndex >= 0
                  || AppState.libraryPreviewItem !== null
            onClicked: AppState.goLive()
        }
    }
}
