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
            iconSize: 14
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

        GhostButton {
            anchors.verticalCenter: parent.verticalCenter
            iconName: "list-ordered"
            iconColor: Theme.color.brand
            text: qsTr("Logo")
            active: AppState.showLogo
            onClicked: AppState.toggleLogo()
        }

        GhostButton {
            anchors.verticalCenter: parent.verticalCenter
            iconName: "menu"
            text: qsTr("Clear")
            onClicked: AppState.clearLive()
        }

        PrimaryButton {
            anchors.verticalCenter: parent.verticalCenter
            variant: "live"
            iconName: "play"
            text: qsTr("Go Live")
            enabled: AppState.selectedScheduleIndex >= 0
            onClicked: AppState.goLive()
        }
    }
}
