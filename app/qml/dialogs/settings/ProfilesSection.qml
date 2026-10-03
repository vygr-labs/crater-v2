import QtQuick
import QtQuick.Layouts

// Profiles — separate sets of songs, themes, media, presentations,
// schedules, Bibles and content preferences (ARCHITECTURE.md §12). Every
// action maps to one ProfileService call; this file only decides what to
// show and when to ask first.
//
// Naming, renaming and deleting happen inline in this pane rather than in
// the shared naming / confirm modals. There is one modal slot, so opening
// either would close Settings, and the result of an async create or delete
// would land on a pane that no longer exists. Switching does use the shared
// confirm modal: it restarts Crater, so losing the Settings pane is moot.
Item {
    id: root

    // Inline name editor: "" (closed) | "create" | "duplicate" | "rename".
    property string _editMode: ""
    property string _editId: ""
    property string _editSubject: ""

    // One-line outcome of the last action, shown under the list.
    property string _status: ""
    property bool   _statusIsError: false

    property string _deleteId: ""

    function _setStatus(text, isError) {
        root._status = text || ""
        root._statusIsError = !!isError
    }

    function _formatDate(ms) {
        if (!ms || ms <= 0) return ""
        return Qt.formatDateTime(new Date(ms), "d MMM yyyy")
    }

    function _startEdit(mode, id, subject, seed) {
        root._editMode = mode
        root._editId = id || ""
        root._editSubject = subject || ""
        nameInput.text = seed || ""
        Qt.callLater(function() {
            nameInput.forceActiveFocus()
            if (nameInput.text.length > 0) nameInput.selectAll()
        })
    }

    function _cancelEdit() {
        root._editMode = ""
        nameInput.text = ""
    }

    function _commitEdit() {
        const name = nameInput.text.trim()
        if (name.length === 0) return
        let ok = false
        if (root._editMode === "rename") {
            ok = ProfileService.renameProfile(root._editId, name)
            if (ok) root._setStatus(qsTr("Renamed to %1.").arg(name), false)
        } else {
            ok = ProfileService.createProfile(name, root._editMode === "duplicate")
        }
        if (!ok) {
            root._setStatus(ProfileService.lastError(), true)
            return
        }
        root._cancelEdit()
    }

    // Switching restarts Crater, so it always asks, and says what the room
    // will see. Only the id is captured: the callback outlives this pane.
    function _confirmSwitch(id, name) {
        AppState.openModal("confirm", {
            title:       qsTr("Switch to %1?").arg(name),
            body:        qsTr("Crater will close and reopen with the songs, themes, media, Bibles and preferences of %1. Anything on the projection screen goes dark until Crater is back.").arg(name),
            confirmText: qsTr("Switch and restart"),
            destructive: false,
            onConfirm:   function() { ProfileService.switchTo(id) }
        })
    }

    function _confirmDelete(id, name) {
        root._deleteId = id
        deleteConfirm.title = qsTr("Delete %1?").arg(name)
        deleteConfirm.openConfirm()
    }

    function _startImport() {
        const path = FileDialogService.chooseOpenFile(qsTr("Import profile"),
                                                      [qsTr("Crater Profile (*.craterprofile)")])
        if (!path || path.length === 0) return
        const info = ProfileService.inspectArchive(path)
        if (!info.ok) {
            root._setStatus(info.error || qsTr("This file could not be opened."), true)
            return
        }
        AppState.openModal("profileImport", { path: path, info: info })
    }

    Connections {
        target: ProfileService
        function onOperationFinished(operation, ok, message, details) {
            const name = (details && details.name) || ""
            if (operation === "create") {
                root._setStatus(ok ? qsTr("Created %1. Switch to it when you are ready.").arg(name)
                                   : qsTr("Could not create the profile. %1").arg(message), !ok)
            } else if (operation === "delete") {
                root._setStatus(ok ? qsTr("Deleted %1.").arg(name)
                                   : qsTr("Could not delete the profile. %1").arg(message), !ok)
            }
        }
    }

    Flickable {
        anchors.fill: parent
        contentHeight: layout.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: layout
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Theme.space.xl
            anchors.rightMargin: Theme.space.xl
            spacing: 0

            SettingsSectionHeader { title: qsTr("Profiles"); first: true }

            Text {
                Layout.fillWidth: true
                Layout.bottomMargin: Theme.space.md
                text: qsTr("Each profile keeps its own songs, themes, media, presentations, schedules, Bibles and display preferences. Screens, NDI and the look of this window are shared by every profile.")
                color: Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                wrapMode: Text.WordWrap
                lineHeight: 1.35
            }

            // ── Profile list ─────────────────────────────────────────────
            Repeater {
                model: ProfileService.profiles

                delegate: Item {
                    id: row
                    required property var modelData
                    Layout.fillWidth: true
                    Layout.preferredHeight: 56

                    readonly property bool _current: modelData.isCurrent
                    readonly property bool _default: modelData.isDefault

                    AppIcon {
                        id: rowIcon
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        name: "user"
                        color: row._current ? Theme.color.brand : Theme.color.textSecondary
                        size: Theme.icon.md
                    }

                    Column {
                        anchors.left: rowIcon.right
                        anchors.leftMargin: Theme.space.md
                        anchors.right: rowActions.left
                        anchors.rightMargin: Theme.space.md
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2

                        Row {
                            spacing: Theme.space.sm
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: row.modelData.name
                                color: Theme.color.textPrimary
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.bodySize
                                font.weight: Theme.font.weightMedium
                            }
                            Badge {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: row._current
                                text: qsTr("In use")
                                background: Theme.color.brandSubtle
                                foreground: Theme.color.brand
                            }
                        }
                        Text {
                            width: parent.width
                            elide: Text.ElideRight
                            text: {
                                const parts = []
                                if (row._default) parts.push(qsTr("Default profile"))
                                const used = root._formatDate(row.modelData.lastUsedAt)
                                if (used.length > 0) parts.push(qsTr("Last used %1").arg(used))
                                else parts.push(qsTr("Not used yet"))
                                return parts.join(" · ")
                            }
                            color: Theme.color.textTertiary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.smallSize
                        }
                    }

                    Row {
                        id: rowActions
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.space.xs

                        GhostButton {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: !row._current
                            enabled: !ProfileService.busy
                            text: qsTr("Switch")
                            onClicked: root._confirmSwitch(row.modelData.id, row.modelData.name)
                        }
                        IconButton {
                            anchors.verticalCenter: parent.verticalCenter
                            iconName: "pencil"
                            enabled: !ProfileService.busy
                            onClicked: root._startEdit("rename", row.modelData.id,
                                                       row.modelData.name, row.modelData.name)
                        }
                        IconButton {
                            anchors.verticalCenter: parent.verticalCenter
                            iconName: "trash-2"
                            // Default holds the original data folder and the
                            // one in use has its files open: neither goes.
                            visible: !row._default && !row._current
                            enabled: !ProfileService.busy
                            onClicked: root._confirmDelete(row.modelData.id, row.modelData.name)
                        }
                    }

                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: 1
                        color: Theme.color.borderSubtle
                    }
                }
            }

            // ── Inline name editor ───────────────────────────────────────
            Item {
                Layout.fillWidth: true
                Layout.topMargin: Theme.space.md
                Layout.preferredHeight: root._editMode !== "" ? editCol.implicitHeight : 0
                visible: root._editMode !== ""

                Column {
                    id: editCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    spacing: Theme.space.sm

                    Text {
                        text: root._editMode === "rename"
                                  ? qsTr("Rename %1").arg(root._editSubject)
                            : root._editMode === "duplicate"
                                  ? qsTr("Name for the copy of %1").arg(ProfileService.currentProfileName)
                                  : qsTr("Name for the new profile")
                        color: Theme.color.textPrimary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.bodySize
                        font.weight: Theme.font.weightMedium
                    }

                    Row {
                        width: parent.width
                        spacing: Theme.space.sm

                        Rectangle {
                            width: parent.width - commitButton.width - cancelEditButton.width
                                   - Theme.space.sm * 2
                            height: 34
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
                                onAccepted: root._commitEdit()
                                Keys.onEscapePressed: function(event) {
                                    root._cancelEdit()
                                    event.accepted = true
                                }

                                Text {
                                    visible: nameInput.text.length === 0
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: qsTr("For example Sunday service or Youth")
                                    color: Theme.color.textTertiary
                                    font.family: Theme.font.family
                                    font.pixelSize: Theme.font.bodySize
                                }
                            }
                        }

                        PrimaryButton {
                            id: commitButton
                            variant: "brand"
                            text: root._editMode === "rename" ? qsTr("Rename")
                                : root._editMode === "duplicate" ? qsTr("Duplicate")
                                : qsTr("Create")
                            enabled: nameInput.text.trim().length > 0 && !ProfileService.busy
                            onClicked: root._commitEdit()
                        }
                        GhostButton {
                            id: cancelEditButton
                            text: qsTr("Cancel")
                            onClicked: root._cancelEdit()
                        }
                    }
                }
            }

            // ── Create ───────────────────────────────────────────────────
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Theme.space.md
                spacing: Theme.space.sm

                GhostButton {
                    iconName: "plus"
                    text: qsTr("New profile")
                    enabled: !ProfileService.busy
                    onClicked: root._startEdit("create", "", "", "")
                }
                GhostButton {
                    iconName: "copy"
                    text: qsTr("Duplicate current")
                    enabled: !ProfileService.busy
                    onClicked: root._startEdit("duplicate", "", "",
                                               qsTr("%1 copy").arg(ProfileService.currentProfileName))
                }
                Item { Layout.fillWidth: true }
            }

            Text {
                Layout.fillWidth: true
                Layout.topMargin: Theme.space.sm
                text: qsTr("A new profile starts like a fresh install, with the built-in themes and the bundled Bibles. A duplicate copies everything in the current profile.")
                color: Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.microSize
                wrapMode: Text.WordWrap
                lineHeight: 1.35
            }

            // ── Progress + last outcome ──────────────────────────────────
            Item {
                Layout.fillWidth: true
                Layout.topMargin: visible ? Theme.space.md : 0
                Layout.preferredHeight: visible ? 36 : 0
                visible: ProfileService.busy

                Text {
                    id: busyLabel
                    anchors.left: parent.left
                    anchors.top: parent.top
                    text: ProfileService.progressText.length > 0 ? ProfileService.progressText
                                                                 : qsTr("Working...")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.microSize
                }
                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: busyLabel.bottom
                    anchors.topMargin: Theme.space.sm
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

            Text {
                Layout.fillWidth: true
                Layout.topMargin: Theme.space.sm
                visible: root._status.length > 0
                text: root._status
                color: root._statusIsError ? Theme.color.warning : Theme.color.textSecondary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                wrapMode: Text.WordWrap
            }

            // ── Share and back up ────────────────────────────────────────
            SettingsSectionHeader { title: qsTr("Export and import") }

            Text {
                Layout.fillWidth: true
                Layout.bottomMargin: Theme.space.md
                text: qsTr("A profile file carries the parts you choose, with every picture, video and font it uses. Import one as a new profile, or merge it into this one without creating duplicates.")
                color: Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                wrapMode: Text.WordWrap
                lineHeight: 1.35
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.space.sm

                GhostButton {
                    iconName: "upload"
                    text: qsTr("Export %1...").arg(ProfileService.currentProfileName)
                    enabled: !ProfileService.busy
                    onClicked: AppState.openModal("profileExport", {})
                }
                GhostButton {
                    iconName: "download"
                    text: qsTr("Import profile...")
                    enabled: !ProfileService.busy
                    onClicked: root._startImport()
                }
                Item { Layout.fillWidth: true }
            }

            // ── Startup ──────────────────────────────────────────────────
            SettingsSectionHeader { title: qsTr("Startup") }

            SettingRow {
                title: qsTr("Ask which profile to use")
                description: qsTr("When Crater opens and more than one profile exists. Otherwise it opens the profile used last.")
                ToggleSwitch {
                    value: ProfileService.askAtStartup
                    onToggled: ProfileService.askAtStartup = !ProfileService.askAtStartup
                }
            }

            Item { Layout.fillWidth: true; Layout.preferredHeight: Theme.space.xxl }
        }
    }

    // Deleting is permanent, so it asks in place (red, like every other
    // destructive confirm) and names what goes with the profile.
    ConfirmationOverlay {
        id: deleteConfirm
        anchors.fill: parent
        body: qsTr("This permanently removes the profile with its songs, themes, media, presentations, schedules, Bibles and preferences. Export it first if you might need it again.")
        confirmLabel: qsTr("Delete profile")
        onConfirmed: {
            if (!ProfileService.deleteProfile(root._deleteId))
                root._setStatus(ProfileService.lastError(), true)
            root._deleteId = ""
        }
        onCancelled: root._deleteId = ""
    }
}
