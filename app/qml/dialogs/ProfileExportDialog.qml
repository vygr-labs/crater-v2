import QtQuick
import Crater

// Export the current profile to a .craterprofile file (ARCHITECTURE.md §12).
// The operator ticks the parts to include, picks where to save, and the
// dialog stays open with a progress bar until ProfileService reports back.
//
// Opened from Settings > Profiles via AppState.openModal("profileExport", {}).
ModalShell {
    id: root

    dialogWidth: 540
    dialogHeight: 600
    title: qsTr("Export profile")

    // "choose" -> "running" -> "done"
    property string _phase: "choose"
    property var    _parts: ({ themes: true, fonts: true, media: true, presentations: true,
                               scriptures: true, songs: true, schedules: true,
                               settings: true })

    // What each part holds right now ({ songs: { count, bytes }, ... }),
    // read once when the dialog opens.
    readonly property var _sizes: ProfileService.partSizes()

    function _fmtBytes(b) {
        if (b >= 1024 * 1024 * 1024) return qsTr("%1 GB").arg((b / (1024 * 1024 * 1024)).toFixed(1))
        if (b >= 1024 * 1024)        return qsTr("%1 MB").arg((b / (1024 * 1024)).toFixed(1))
        if (b >= 1024)               return qsTr("%1 KB").arg(Math.round(b / 1024))
        return qsTr("%1 bytes").arg(b)
    }

    function _countText(key, count) {
        const one = count === 1
        const n = count.toLocaleString(Qt.locale(), "f", 0)
        switch (key) {
        case "songs":         return one ? qsTr("1 song")         : qsTr("%1 songs").arg(n)
        case "scriptures":    return one ? qsTr("1 Bible")        : qsTr("%1 Bibles").arg(n)
        case "themes":        return one ? qsTr("1 theme")        : qsTr("%1 themes").arg(n)
        case "fonts":         return one ? qsTr("1 font")         : qsTr("%1 fonts").arg(n)
        case "media":         return one ? qsTr("1 file")         : qsTr("%1 files").arg(n)
        case "presentations": return one ? qsTr("1 presentation") : qsTr("%1 presentations").arg(n)
        case "schedules":     return one ? qsTr("1 schedule")     : qsTr("%1 schedules").arg(n)
        case "settings":      return one ? qsTr("1 preference")   : qsTr("%1 preferences").arg(n)
        }
        return String(n)
    }

    // "1,430 songs · 2.1 MB" for a row's right-hand detail.
    function _sizeText(key) {
        const s = root._sizes[key]
        if (!s) return ""
        let t = root._countText(key, Number(s.count))
        if (s.bytes > 0) t += " · " + root._fmtBytes(s.bytes)
        return t
    }

    // Rough size of the file with the current ticks.
    readonly property real _totalBytes: {
        let sum = 0
        for (const k in root._parts)
            if (root._parts[k] && root._sizes[k]) sum += Number(root._sizes[k].bytes) || 0
        return sum
    }
    property bool   _ok: false
    property string _message: ""
    property var    _warnings: []
    property string _path: ""

    readonly property var _rows: [
        { key: "songs",         label: qsTr("Songs"),         detail: qsTr("with collections") },
        { key: "scriptures",    label: qsTr("Scriptures"),    detail: qsTr("installed Bibles") },
        { key: "themes",        label: qsTr("Themes"),        detail: "" },
        { key: "fonts",         label: qsTr("Fonts"),         detail: "" },
        { key: "media",         label: qsTr("Media"),         detail: qsTr("pictures, videos, PDFs") },
        { key: "presentations", label: qsTr("Presentations"), detail: "" },
        { key: "schedules",     label: qsTr("Schedules"),     detail: "" },
        { key: "settings",      label: qsTr("Settings"),      detail: qsTr("display preferences") }
    ]

    readonly property bool _anyChecked: {
        for (const k in root._parts) if (root._parts[k]) return true
        return false
    }

    // A schedule is a list of pointers into the other libraries. Exported
    // without them it still opens, but items fall back to their saved text.
    readonly property bool _schedulesIncomplete:
        _parts.schedules && !(_parts.songs && _parts.media && _parts.themes && _parts.presentations)

    function _toggle(key) {
        const next = Object.assign({}, root._parts)
        next[key] = !next[key]
        root._parts = next
    }

    function _export() {
        let path = FileDialogService.chooseSaveFile(qsTr("Export profile"),
                                                    ProfileService.suggestedExportName(),
                                                    [qsTr("Crater Profile (*.craterprofile)")])
        if (!path || path.length === 0) return
        if (!path.toLowerCase().endsWith(".craterprofile")) path += ".craterprofile"
        root._path = path
        if (ProfileService.exportProfile(path, root._parts)) {
            root._phase = "running"
        } else {
            root._ok = false
            root._message = ProfileService.lastError()
            root._phase = "done"
        }
    }

    // Closing mid-export would leave the operator with no idea whether the
    // file got written, so the backdrop / Escape / X wait until it is done.
    function requestClose() {
        if (root._phase === "running") return
        AppState.closeModal()
    }
    Component.onCompleted: AppState.modalCloseOwner = root

    Connections {
        target: ProfileService
        function onOperationFinished(operation, ok, message, details) {
            if (operation !== "export" || root._phase !== "running") return
            root._ok = ok
            root._message = ok ? qsTr("Saved to %1").arg(details.path || root._path)
                               : (message || qsTr("The export failed."))
            root._warnings = Array.prototype.slice.call((details && details.warnings) || [])
            root._phase = "done"
        }
    }

    Item {
        anchors.fill: parent
        anchors.margins: Theme.space.lg

        // ── Choose ──────────────────────────────────────────────────────
        Column {
            id: chooseCol
            visible: root._phase === "choose"
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: Theme.space.xs

            Text {
                text: ProfileService.currentProfileName
                color: Theme.color.textPrimary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize + 1
                font.weight: Theme.font.weightSemiBold
            }
            Text {
                width: parent.width
                text: qsTr("Choose what goes in the file. Media and fonts are copied in full, so a large media library makes a large file.")
                color: Theme.color.textSecondary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                wrapMode: Text.WordWrap
                bottomPadding: Theme.space.sm
            }

            Repeater {
                model: root._rows
                delegate: CheckRow {
                    required property var modelData
                    width: chooseCol.width
                    label: modelData.label
                    detail: {
                        const size = root._sizeText(modelData.key)
                        return size.length > 0 ? size : modelData.detail
                    }
                    checked: !!root._parts[modelData.key]
                    onToggled: root._toggle(modelData.key)
                }
            }

            Text {
                width: parent.width
                visible: root._schedulesIncomplete
                topPadding: Theme.space.sm
                text: qsTr("Schedules point at songs, media, themes and presentations. Include those too so the schedules open complete on the other computer.")
                color: Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                wrapMode: Text.WordWrap
            }
            Text {
                width: parent.width
                topPadding: Theme.space.sm
                text: qsTr("About %1 in total").arg(root._fmtBytes(root._totalBytes))
                color: Theme.color.textSecondary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                font.weight: Theme.font.weightMedium
            }
            Text {
                width: parent.width
                visible: !!root._parts.themes && !root._parts.fonts
                topPadding: Theme.space.sm
                text: qsTr("Themes that use your own fonts will show a standard font on the other computer unless Fonts is ticked.")
                color: Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                wrapMode: Text.WordWrap
            }
            Text {
                width: parent.width
                visible: !!root._parts.fonts
                topPadding: Theme.space.sm
                text: qsTr("Font files may be licensed for this computer only. You are responsible for having the right to share any font you export.")
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
                text: ProfileService.progressText.length > 0 ? ProfileService.progressText
                                                             : qsTr("Exporting...")
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
            Text {
                width: parent.width
                text: qsTr("You can keep using Crater while this runs.")
                color: Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                wrapMode: Text.WordWrap
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
                    text: root._ok ? qsTr("Export finished") : qsTr("Export failed")
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
                visible: root._warnings.length > 0
                topPadding: Theme.space.sm
                text: qsTr("Left out:") + "\n" + root._warnings.slice(0, 8).join("\n")
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
                iconName: "upload"
                text: qsTr("Export...")
                enabled: root._anyChecked && !ProfileService.busy
                onClicked: root._export()
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
