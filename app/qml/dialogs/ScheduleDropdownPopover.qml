import QtQuick

// Schedule dropdown — opens under the TopBar's "Schedule" pill button.
// Lists ScheduleService.savedSchedules + actions to save the current
// working schedule, load a saved one, delete one, or start fresh.
//
// Extends PopoverMenu so the visual chrome (backdrop, click-outside,
// item rows) is shared with right-click context menus.
PopoverMenu {
    id: root

    active: true
    anchorX: AppState.modalProps.anchorX || 0
    anchorY: AppState.modalProps.anchorY || 0
    menuWidth: 340

    // Human-readable relative time. Bigger increments collapse into a date so
    // the dropdown doesn't end up with "47 days ago"-style entries.
    function relTime(ms) {
        if (!ms) return ""
        const diff = Date.now() - ms
        if (diff < 60000)         return qsTr("Just now")
        if (diff < 3600000)       { const m = Math.floor(diff / 60000);   return m === 1 ? qsTr("1 minute ago") : qsTr("%1 minutes ago").arg(m) }
        if (diff < 86400000)      { const h = Math.floor(diff / 3600000); return h === 1 ? qsTr("1 hour ago")   : qsTr("%1 hours ago").arg(h) }
        if (diff < 604800000)     { const d = Math.floor(diff / 86400000); return d === 1 ? qsTr("Yesterday")    : qsTr("%1 days ago").arg(d) }
        return Qt.formatDate(new Date(ms), "yyyy-MM-dd")
    }

    // Build the menu items reactively: any change to ScheduleService.savedSchedules
    // (e.g., after a Save As / Delete) re-evaluates this binding via NOTIFY.
    model: {
        const saved = ScheduleService.savedSchedules
        let items = []
        for (let i = 0; i < saved.length; i++) {
            const s = saved[i]
            const sid = s.id   // capture for the action closure
            items.push({
                label:    s.name,
                iconName: "file-text",
                detail:   s.itemCount + (s.itemCount === 1 ? " item · " : " items · ") + relTime(s.modifiedAt),
                action:   function() { ScheduleService.load(sid) }
            })
        }
        if (saved.length === 0) {
            items.push({ label: qsTr("No saved schedules"), iconName: "" })
        }
        items.push({ separator: true })
        items.push({
            label:    qsTr("Save current as…"),
            iconName: "save",
            action:   function() {
                AppState.openModal("naming", {
                    title:       qsTr("Save schedule"),
                    placeholder: qsTr("e.g., Sunday AM — June 5"),
                    confirmText: qsTr("Save"),
                    onConfirm: function(name) {
                        if (name && name.length > 0) ScheduleService.saveAs(name)
                    }
                })
            }
        })
        items.push({
            label:    qsTr("New empty schedule"),
            iconName: "plus",
            action:   function() {
                ScheduleService.clearAll()
                AppState.selectScheduleItem(-1)
                AppState.liveScheduleIndex = -1
                AppState.libraryLiveActive = false
                AppState.clearLibraryPreview()
            }
        })
        return items
    }

    // Propagate close (backdrop click) to AppState so the Loader deactivates
    onActiveChanged: if (!active) AppState.closeModal()
}
