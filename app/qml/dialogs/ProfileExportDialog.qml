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
    property var    _parts: ({ themes: true, media: true, presentations: true,
                               scriptures: true, songs: true, schedules: true,
                               settings: true })
    property bool   _ok: false
    property string _message: ""
    property var    _warnings: []
    property string _path: ""

    readonly property var _rows: [
        { key: "songs",         label: qsTr("Songs"),         detail: qsTr("with collections") },
        { key: "scriptures",    label: qsTr("Scriptures"),    detail: qsTr("installed Bibles") },
        { key: "themes",        label: qsTr("Themes"),        detail: qsTr("with their fonts") },
        { key: "media",         label: qsTr("Media"),         detail: qsTr("pictures, videos, PDFs") },
        { key: "presentations", label: qsTr("Presentations"), detail: "" },
        { key: "schedules",     label: qsTr("Schedules"),     detail: qsTr("saved schedules") },
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
                    detail: modelData.detail
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
                visible: !!root._parts.themes
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
