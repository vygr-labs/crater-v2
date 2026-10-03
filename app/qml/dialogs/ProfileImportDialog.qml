import QtQuick
import Crater

// Import a .craterprofile (ARCHITECTURE.md §12). Shows what the file holds,
// lets the operator tick the parts to bring in (parts the file does not
// carry are disabled), and choose between a new profile and a merge into
// the current one. ProfileService validated the file before this opened
// (ProfileService.inspectArchive) and validates it again on import.
//
// Opened from Settings > Profiles via:
//   AppState.openModal("profileImport", { path, info })
ModalShell {
    id: root

    dialogWidth: 560
    dialogHeight: 660
    title: qsTr("Import profile")

    readonly property string _path: AppState.modalProps.path || ""
    readonly property var    _info: AppState.modalProps.info || ({})
    readonly property var    _present: _info.parts || ({})
    readonly property var    _counts: _info.counts || ({})

    // "choose" -> "running" -> "done"
    property string _phase: "choose"
    property string _mode: "new"          // "new" | "merge"
    property var    _parts: ({})
    property bool   _ok: false
    property string _message: ""
    property var    _summary: []
    property var    _warnings: []
    property string _newId: ""

    readonly property var _rows: [
        { key: "songs",         label: qsTr("Songs"),         countKey: "songs",         unit: qsTr("%1 songs") },
        { key: "scriptures",    label: qsTr("Scriptures"),    countKey: "scriptures",    unit: qsTr("%1 Bibles") },
        { key: "themes",        label: qsTr("Themes"),        countKey: "themes",        unit: qsTr("%1 themes") },
        { key: "fonts",         label: qsTr("Fonts"),         countKey: "fonts",         unit: qsTr("%1 fonts") },
        { key: "media",         label: qsTr("Media"),         countKey: "media",         unit: qsTr("%1 files") },
        { key: "presentations", label: qsTr("Presentations"), countKey: "presentations", unit: qsTr("%1 presentations") },
        { key: "schedules",     label: qsTr("Schedules"),     countKey: "schedules",     unit: qsTr("%1 schedules") },
        { key: "settings",      label: qsTr("Settings"),      countKey: "settings",      unit: qsTr("%1 preferences") }
    ]

    readonly property bool _anyChecked: {
        for (const k in root._parts) if (root._parts[k] && root._present[k]) return true
        return false
    }

    function _fileName(p) {
        const s = (p || "").replace(/\\/g, "/")
        return s.substring(s.lastIndexOf("/") + 1)
    }
    function _formatBytes(n) {
        if (!n || n < 1024) return (n || 0) + " B"
        if (n < 1024 * 1024) return (n / 1024).toFixed(1) + " KB"
        if (n < 1024 * 1024 * 1024) return (n / 1024 / 1024).toFixed(1) + " MB"
        return (n / 1024 / 1024 / 1024).toFixed(2) + " GB"
    }
    function _labelFor(key) {
        for (let i = 0; i < root._rows.length; i++)
            if (root._rows[i].key === key) return root._rows[i].label
        if (key === "fonts") return qsTr("Fonts")
        if (key === "collections") return qsTr("Collections")
        return key
    }

    function _toggle(key) {
        const next = Object.assign({}, root._parts)
        next[key] = !next[key]
        root._parts = next
    }

    function _import() {
        const parts = {}
        for (const k in root._parts) parts[k] = !!(root._parts[k] && root._present[k])
        const ok = ProfileService.importArchive(root._path, parts, root._mode === "new",
                                                nameInput.text.trim())
        if (ok) {
            root._phase = "running"
        } else {
            root._ok = false
            root._message = ProfileService.lastError()
            root._phase = "done"
        }
    }

    // Same reasoning as the export dialog: leaving mid-import hides whether
    // anything landed, so dismissal waits for the result.
    function requestClose() {
        if (root._phase === "running") return
        AppState.closeModal()
    }

    Component.onCompleted: {
        AppState.modalCloseOwner = root
        const init = {}
        for (let i = 0; i < root._rows.length; i++) {
            const k = root._rows[i].key
            init[k] = !!root._present[k]
        }
        root._parts = init
        nameInput.text = root._info.profileName || ""
    }

    Connections {
        target: ProfileService
        function onOperationFinished(operation, ok, message, details) {
            if (operation !== "import" || root._phase !== "running") return
            root._ok = ok
            root._newId = (details && details.id) || ""
            const added   = (details && details.added)   || {}
            const skipped = (details && details.skipped) || {}
            const lines = []
            const keys = Object.keys(added).concat(Object.keys(skipped))
            const seen = {}
            for (let i = 0; i < keys.length; i++) {
                const k = keys[i]
                if (seen[k]) continue
                seen[k] = true
                const a = added[k] || 0
                const s = skipped[k] || 0
                if (a === 0 && s === 0) continue
                lines.push(s > 0 ? qsTr("%1: %2 added, %3 already here").arg(root._labelFor(k)).arg(a).arg(s)
                                 : qsTr("%1: %2 added").arg(root._labelFor(k)).arg(a))
            }
            root._summary = lines
            root._warnings = Array.prototype.slice.call((details && details.warnings) || [])
            if (!ok) {
                root._message = message || qsTr("The import failed.")
            } else if (details && details.asNewProfile) {
                root._message = qsTr("%1 is ready. Switch to it now, or later from Settings > Profiles.")
                                    .arg(details.name || "")
            } else {
                root._message = qsTr("Everything was added to %1. Restart Crater to see the new items.")
                                    .arg(ProfileService.currentProfileName)
            }
            root._phase = "done"
        }
    }

    Item {
        anchors.fill: parent
        anchors.margins: Theme.space.lg

        // ── Choose ──────────────────────────────────────────────────────
        Flickable {
            id: chooseFlick
            visible: root._phase === "choose"
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: actions.top
            anchors.bottomMargin: Theme.space.md
            clip: true
            contentHeight: chooseCol.implicitHeight
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: chooseCol
                width: chooseFlick.width
                spacing: Theme.space.xs

                Text {
                    width: parent.width
                    elide: Text.ElideRight
                    text: root._info.profileName || root._fileName(root._path)
                    color: Theme.color.textPrimary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize + 1
                    font.weight: Theme.font.weightSemiBold
                }
                Text {
                    width: parent.width
                    elide: Text.ElideMiddle
                    text: {
                        const bits = [root._fileName(root._path), root._formatBytes(root._info.totalBytes)]
                        if (root._info.exportedAt > 0)
                            bits.push(qsTr("exported %1").arg(Qt.formatDateTime(new Date(root._info.exportedAt), "d MMM yyyy")))
                        if (root._info.appVersion)
                            bits.push(qsTr("Crater %1").arg(root._info.appVersion))
                        return bits.join(" · ")
                    }
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                    bottomPadding: Theme.space.sm
                }

                Text {
                    text: qsTr("INCLUDE")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.microSize
                    font.weight: Theme.font.weightSemiBold
                    font.letterSpacing: 1.0
                }

                Repeater {
                    model: root._rows
                    delegate: CheckRow {
                        required property var modelData
                        width: chooseCol.width
                        enabled: !!root._present[modelData.key]
                        label: modelData.label
                        detail: !root._present[modelData.key]
                                    ? qsTr("not in this file")
                                    : (root._counts[modelData.countKey] !== undefined
                                           ? modelData.unit.arg(root._counts[modelData.countKey]) : "")
                        checked: !!root._present[modelData.key] && !!root._parts[modelData.key]
                        onToggled: root._toggle(modelData.key)
                    }
                }

                Item { width: 1; height: Theme.space.md }

                Text {
                    text: qsTr("IMPORT AS")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.microSize
                    font.weight: Theme.font.weightSemiBold
                    font.letterSpacing: 1.0
                }

                // Two radio-style choices. Kept as plain rows so they share
                // CheckRow's height and hover rather than adding a control.
                Repeater {
                    model: [
                        { mode: "new",   title: qsTr("A new profile"),
                          body: qsTr("Nothing in your current profile changes.") },
                        { mode: "merge", title: qsTr("Merge into %1").arg(ProfileService.currentProfileName),
                          body: qsTr("Adds what is missing. Songs, themes, media and Bibles that are already here are not added twice.") }
                    ]
                    delegate: Rectangle {
                        required property var modelData
                        width: chooseCol.width
                        height: modeCol.implicitHeight + Theme.space.md * 2
                        color: modeMa.containsMouse ? Theme.color.overlay : "transparent"

                        Rectangle {
                            id: dot
                            width: 18
                            height: 18
                            radius: 9
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.space.sm
                            anchors.top: parent.top
                            anchors.topMargin: Theme.space.md
                            color: "transparent"
                            border.color: root._mode === modelData.mode ? Theme.color.brand : Theme.color.borderStrong
                            border.width: 1
                            Rectangle {
                                anchors.centerIn: parent
                                width: 10
                                height: 10
                                radius: 5
                                color: Theme.color.brand
                                visible: root._mode === modelData.mode
                            }
                        }
                        Column {
                            id: modeCol
                            anchors.left: dot.right
                            anchors.leftMargin: Theme.space.md
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.space.sm
                            anchors.top: parent.top
                            anchors.topMargin: Theme.space.md
                            spacing: 2
                            Text {
                                width: parent.width
                                elide: Text.ElideRight
                                text: modelData.title
                                color: Theme.color.textPrimary
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.bodySize
                            }
                            Text {
                                width: parent.width
                                text: modelData.body
                                color: Theme.color.textTertiary
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.smallSize
                                wrapMode: Text.WordWrap
                            }
                        }
                        MouseArea {
                            id: modeMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root._mode = modelData.mode
                        }
                    }
                }

                // Name for the new profile.
                Item {
                    width: parent.width
                    height: visible ? 40 + Theme.space.sm : 0
                    visible: root._mode === "new"

                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.leftMargin: Theme.space.sm + 18 + Theme.space.md
                        anchors.bottom: parent.bottom
                        height: 36
                        radius: 0
                        color: Theme.color.canvas
                        border.color: nameInput.activeFocus ? Theme.color.brand : Theme.color.borderStrong
                        border.width: 1

                        TextInput {
                            id: nameInput
                            anchors.fill: parent
                            anchors.leftMargin: Theme.space.md
                            anchors.rightMargin: Theme.space.md
                            verticalAlignment: TextInput.AlignVCenter
                            color: Theme.color.textPrimary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.bodySize
                            selectByMouse: true
                            clip: true
                            maximumLength: 80

                            Text {
                                visible: nameInput.text.length === 0
                                anchors.verticalCenter: parent.verticalCenter
                                text: qsTr("Name for the new profile")
                                color: Theme.color.textTertiary
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.bodySize
                            }
                        }
                    }
                }

                Text {
                    width: parent.width
                    visible: root._mode === "merge" && !!root._parts.settings && !!root._present.settings
                    topPadding: Theme.space.sm
                    text: qsTr("Settings from the file replace this profile's display preferences.")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                    wrapMode: Text.WordWrap
                }
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
                                                             : qsTr("Importing...")
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
        Flickable {
            id: doneFlick
            visible: root._phase === "done"
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: actions.top
            anchors.bottomMargin: Theme.space.md
            clip: true
            contentHeight: doneCol.implicitHeight
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: doneCol
                width: doneFlick.width
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
                        text: root._ok ? qsTr("Import finished") : qsTr("Import did not finish")
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
                    wrapMode: Text.WordWrap
                }
                Text {
                    width: parent.width
                    visible: root._summary.length > 0
                    text: root._summary.join("\n")
                    color: Theme.color.textSecondary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                    wrapMode: Text.WordWrap
                    lineHeight: 1.35
                }
                Text {
                    width: parent.width
                    visible: root._warnings.length > 0
                    topPadding: Theme.space.sm
                    text: qsTr("Skipped:") + "\n" + root._warnings.slice(0, 8).join("\n")
                          + (root._warnings.length > 8 ? "\n" + qsTr("and %1 more").arg(root._warnings.length - 8) : "")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                    wrapMode: Text.WordWrap
                }
            }
        }

        // ── Actions ─────────────────────────────────────────────────────
        Row {
            id: actions
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
                text: qsTr("Import")
                enabled: root._anyChecked && !ProfileService.busy
                         && (root._mode === "merge" || nameInput.text.trim().length > 0)
                onClicked: root._import()
            }

            // After a successful import: a merge needs a restart to show up,
            // a new profile is one switch away. Both restart Crater, which
            // the label says outright.
            GhostButton {
                visible: root._phase === "done"
                text: root._ok ? qsTr("Later") : qsTr("Close")
                onClicked: AppState.closeModal()
            }
            PrimaryButton {
                visible: root._phase === "done" && root._ok && root._newId.length > 0
                variant: "brand"
                text: qsTr("Switch and restart")
                onClicked: ProfileService.switchTo(root._newId)
            }
            PrimaryButton {
                visible: root._phase === "done" && root._ok && root._newId.length === 0
                variant: "brand"
                text: qsTr("Restart now")
                onClicked: ProfileService.restart()
            }
        }
    }
}
