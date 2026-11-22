// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2024-2026 Eyetu Kingsley. Part of Crater, see LICENSE and NOTICE.

import QtQuick
import Crater

// Save the working schedule to a .craterschedule file, or open one
// (ProfileService.exportSchedule / openScheduleFile). The file carries the
// schedule plus the themes, songs, decks, pictures and fonts it uses, so it
// opens complete on another computer.
//
// Opened from the schedule dropdown:
//   AppState.openModal("scheduleFile", { mode: "save" })
//   AppState.openModal("scheduleFile", { mode: "save", path: <picked file> })
//   AppState.openModal("scheduleFile", { mode: "open", path: <picked file> })
// The only choice the save view offers is leaving pictures and videos out,
// so a schedule without any skips it: the dropdown picks the file first and
// the dialog only shows the progress and the result. Open works the same
// way. A cancelled picker never flashes a dialog.
ModalShell {
    id: root

    dialogWidth: 500
    dialogHeight: 380
    title: root._mode === "open" ? qsTr("Open schedule") : qsTr("Save schedule to a file")

    readonly property string _mode: AppState.modalProps.mode || "save"

    // "choose" -> "running" -> "done". Open starts at "running".
    property string _phase: (_mode === "open" || !!AppState.modalProps.path) ? "running" : "choose"
    property bool   _includeMedia: true
    property bool   _ok: false
    property string _message: ""
    property var    _summary: []
    property var    _warnings: []

    readonly property string _scheduleName: ScheduleService.loadedScheduleName || ""
    readonly property int    _itemCount: ScheduleService.currentItems.length
    // The schedule's own pictures, videos and PDFs, read once on open.
    readonly property var    _media: _mode === "save"
                                     ? ProfileService.scheduleMediaSize(ScheduleService.currentItems)
                                     : ({ count: 0, bytes: 0 })

    function _fmtBytes(b) {
        if (b >= 1024 * 1024 * 1024) return qsTr("%1 GB").arg((b / (1024 * 1024 * 1024)).toFixed(1))
        if (b >= 1024 * 1024)        return qsTr("%1 MB").arg((b / (1024 * 1024)).toFixed(1))
        if (b >= 1024)               return qsTr("%1 KB").arg(Math.round(b / 1024))
        return qsTr("%1 bytes").arg(b)
    }

    function _labelFor(key) {
        switch (key) {
        case "songs":         return qsTr("Songs")
        case "themes":        return qsTr("Themes")
        case "fonts":         return qsTr("Fonts")
        case "media":         return qsTr("Pictures and videos")
        case "presentations": return qsTr("Presentations")
        case "schedules":     return qsTr("Schedules")
        }
        return key
    }

    function _save() {
        const path = AppState.chooseScheduleFilePath()
        if (path.length > 0) _saveTo(path)
    }

    function _saveTo(path) {
        // An untitled schedule takes the file's name, so it opens on the
        // other computer under the name it was saved as.
        let name = root._scheduleName
        if (name.length === 0) {
            const base = path.replace(/\\/g, "/").split("/").pop()
            name = base.replace(/\.craterschedule$/i, "")
        }
        if (ProfileService.exportSchedule(path, name, ScheduleService.currentItems, root._includeMedia)) {
            root._phase = "running"
        } else {
            root._ok = false
            root._message = ProfileService.lastError()
            root._phase = "done"
        }
    }

    function _open() {
        if (!ProfileService.openScheduleFile(AppState.modalProps.path || "")) {
            root._ok = false
            root._message = ProfileService.lastError()
            root._phase = "done"
        }
    }

    // Closing mid-run would leave the operator not knowing whether it
    // finished, so the backdrop / Escape / X wait until it is done.
    function requestClose() {
        if (root._phase === "running") return
        AppState.closeModal()
    }
    Component.onCompleted: {
        AppState.modalCloseOwner = root
        if (root._mode === "open") root._open()
        else if (AppState.modalProps.path) root._saveTo(AppState.modalProps.path)
    }

    Connections {
        target: ProfileService
        function onOperationFinished(operation, ok, message, details) {
            if (root._phase !== "running") return
            if (operation === "scheduleExport") {
                root._ok = ok
                root._message = ok ? qsTr("Saved to %1").arg(details.path || "")
                                   : (message || qsTr("Saving the schedule failed."))
                root._warnings = Array.prototype.slice.call((details && details.warnings) || [])
                root._phase = "done"
            } else if (operation === "scheduleOpen") {
                root._ok = ok
                const added   = (details && details.added)   || {}
                const skipped = (details && details.skipped) || {}
                const lines = []
                const keys = ["songs", "themes", "presentations", "media", "fonts"]
                for (let i = 0; i < keys.length; i++) {
                    const a = added[keys[i]] || 0
                    const s = skipped[keys[i]] || 0
                    if (a === 0 && s === 0) continue
                    lines.push(s > 0 ? qsTr("%1: %2 added, %3 already here").arg(root._labelFor(keys[i])).arg(a).arg(s)
                                     : qsTr("%1: %2 added").arg(root._labelFor(keys[i])).arg(a))
                }
                root._summary = lines
                root._warnings = Array.prototype.slice.call((details && details.warnings) || [])
                if (ok) {
                    ScheduleService.load(details.scheduleId)
                    AppState.clearScheduleSelection()
                    root._message = qsTr("%1 is open in the schedule.")
                                        .arg(details.scheduleName || ScheduleService.loadedScheduleName)
                } else {
                    root._message = message || qsTr("Opening the schedule failed.")
                }
                root._phase = "done"
            }
        }
    }

    Item {
        anchors.fill: parent
        anchors.margins: Theme.space.lg

        // ── Choose (save) ───────────────────────────────────────────────
        Column {
            id: chooseCol
            visible: root._phase === "choose"
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: Theme.space.xs

            Text {
                width: parent.width
                elide: Text.ElideRight
                text: root._scheduleName.length > 0 ? root._scheduleName : qsTr("Untitled schedule")
                color: Theme.color.textPrimary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize + 1
                font.weight: Theme.font.weightSemiBold
            }
            Text {
                width: parent.width
                text: root._itemCount === 1 ? qsTr("1 item") : qsTr("%1 items").arg(root._itemCount)
                color: Theme.color.textSecondary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
            }
            Text {
                width: parent.width
                topPadding: Theme.space.sm
                bottomPadding: Theme.space.sm
                text: qsTr("The file carries the songs, themes, presentations and fonts this schedule uses, so it opens complete on another computer.")
                color: Theme.color.textSecondary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                wrapMode: Text.WordWrap
            }
            CheckRow {
                width: chooseCol.width
                visible: root._media.count > 0
                label: qsTr("Include pictures and videos")
                detail: (root._media.count === 1 ? qsTr("1 file") : qsTr("%1 files").arg(root._media.count))
                        + (root._media.bytes > 0 ? " · " + root._fmtBytes(root._media.bytes) : "")
                checked: root._includeMedia
                onToggled: root._includeMedia = !root._includeMedia
            }
            Text {
                width: parent.width
                visible: root._media.count > 0 && !root._includeMedia
                topPadding: Theme.space.xs
                text: qsTr("Left out, they open only where the same files are already in the media library. Pictures a theme or presentation uses are always included.")
                color: Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                wrapMode: Text.WordWrap
            }
        }

        // ── Running ─────────────────────────────────────────────────────
        Column {
            visible: root._phase === "running"
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: Theme.space.sm

            Text {
                text: ProfileService.progressText.length > 0
                      ? ProfileService.progressText
                      : (root._mode === "open" ? qsTr("Opening...") : qsTr("Saving..."))
                color: Theme.color.textSecondary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize
            }
            Rectangle {
                width: parent.width
                height: 4
                radius: Theme.radius.pill
                color: Theme.color.borderSubtle
                Rectangle {
                    height: parent.height
                    radius: parent.radius
                    color: Theme.color.brand
                    width: parent.width * ProfileService.progress
                    Behavior on width { NumberAnimation { duration: Theme.motion.instant } }
                }
            }
        }

        // ── Done ────────────────────────────────────────────────────────
        Column {
            visible: root._phase === "done"
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: Theme.space.sm

            Row {
                spacing: Theme.space.sm
                AppIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: root._ok ? "check" : "alert-triangle"
                    color: root._ok ? Theme.color.success : Theme.color.warning
                    size: Theme.icon.md
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root._mode === "open"
                          ? (root._ok ? qsTr("Schedule opened") : qsTr("Could not open the schedule"))
                          : (root._ok ? qsTr("Schedule saved") : qsTr("Could not save the schedule"))
                    color: Theme.color.textPrimary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize + 1
                    font.weight: Theme.font.weightSemiBold
                }
            }
            Text {
                width: parent.width
                text: root._message
                color: Theme.color.textSecondary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                wrapMode: Text.WrapAnywhere
            }
            Text {
                width: parent.width
                visible: root._summary.length > 0
                text: root._summary.join("\n")
                color: Theme.color.textSecondary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                wrapMode: Text.WordWrap
            }
            Text {
                width: parent.width
                visible: root._warnings.length > 0
                topPadding: Theme.space.sm
                text: (root._mode === "open" ? qsTr("Not brought in:") : qsTr("Left out:")) + "\n" + root._warnings.slice(0, 8).join("\n")
                      + (root._warnings.length > 8 ? "\n" + qsTr("and %1 more").arg(root._warnings.length - 8) : "")
                color: Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                wrapMode: Text.WordWrap
            }
        }

        // ── Actions ─────────────────────────────────────────────────────
        Row {
            anchors.bottom: parent.bottom
            anchors.right: parent.right
            spacing: Theme.space.sm

            GhostButton {
                visible: root._phase === "choose"
                text: qsTr("Cancel")
                onClicked: AppState.closeModal()
            }
            PrimaryButton {
                visible: root._phase === "choose"
                variant: "brand"
                iconName: "download"
                text: qsTr("Save...")
                enabled: root._itemCount > 0 && !ProfileService.busy
                onClicked: root._save()
            }
            PrimaryButton {
                visible: root._phase === "done"
                variant: "brand"
                text: qsTr("Done")
                onClicked: AppState.closeModal()
            }
        }
    }
}
