import QtQuick

// Schedule dropdown — opens under the TopBar's "Schedule" pill button.
// Lists saved schedules + a "Save current as…" entry that opens NamingDialog.
//
// Extends PopoverMenu so the visual chrome (backdrop, click-outside,
// item rows) is shared with right-click context menus.
PopoverMenu {
    id: root

    active: true
    anchorX: AppState.modalProps.anchorX || 0
    anchorY: AppState.modalProps.anchorY || 0
    menuWidth: 340

    // Build the menu items reactively: any change to savedSchedules
    // (e.g., user adds one via Save As) refreshes the list.
    model: {
        const count = AppState.savedSchedules.count
        let items = []
        for (let i = 0; i < count; i++) {
            const s = AppState.savedSchedules.get(i)
            items.push({
                label: s.name,
                iconName: "file-text",
                detail: s.modified,
                action: function() { console.log("[schedule] load: " + s.name) }
            })
        }
        if (count === 0) {
            items.push({ label: qsTr("No saved schedules"), iconName: "" })
        }
        items.push({ separator: true })
        items.push({
            label: qsTr("Save current as…"),
            iconName: "save",
            action: function() {
                AppState.openModal("naming", {
                    title:       qsTr("Save schedule"),
                    placeholder: qsTr("e.g., Sunday AM — June 5"),
                    confirmText: qsTr("Save"),
                    onConfirm: function(name) {
                        AppState.savedSchedules.insert(0, {
                            name:     name,
                            items:    AppState.scheduleItems.count,
                            modified: qsTr("Just now")
                        })
                    }
                })
            }
        })
        items.push({
            label: qsTr("New empty schedule"),
            iconName: "plus",
            action: function() {
                // Clear schedule items but keep mock songs / library
                while (AppState.scheduleItems.count > 0) {
                    AppState.scheduleItems.remove(0)
                }
                AppState.selectScheduleItem(-1)
                AppState.liveScheduleIndex = -1
            }
        })
        return items
    }

    // Propagate close (backdrop click) to AppState so the Loader deactivates
    onActiveChanged: if (!active) AppState.closeModal()
}
