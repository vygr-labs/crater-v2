import QtQuick
import QtQuick.Controls   // ScrollBar attached property on the release-notes box
import QtQuick.Layouts

// Updates — the operator's whole view of the in-app updater
// (docs/auto-update.md). Every control here maps to exactly one
// UpdateService call; this file holds no update logic of its own beyond
// deciding which of the service's states to show.
//
// One rule the layout encodes deliberately: the install button is never
// what your eye lands on first. Checking and downloading are safe at any
// moment, installing closes Crater in front of a room, so it is the only
// control that takes the brand colour and the only one behind a confirm.
Item {
    id: root

    // UpdateService.State is a C++ Q_ENUM, reachable through the singleton
    // the same way DiagnosticsSection reads LogReportService.Sending.
    readonly property int  _state: UpdateService.state
    readonly property bool _offering: root._state === UpdateService.UpdateAvailable
                                   || root._state === UpdateService.Downloading
                                   || root._state === UpdateService.ReadyToInstall

    function _sizeLabel(bytes) {
        if (bytes <= 0) return ""
        return (bytes / (1024 * 1024)).toFixed(1) + " MB"
    }

    function _lastCheckedLabel() {
        const when = UpdateService.lastChecked
        if (!when || isNaN(when.getTime())) return qsTr("Never checked")
        return qsTr("Last checked %1").arg(Qt.formatDateTime(when, "d MMM yyyy, h:mm ap"))
    }

    function _statusLabel() {
        switch (root._state) {
        case UpdateService.Checking:
            return qsTr("Checking for updates...")
        case UpdateService.UpToDate:
            return UpdateService.skippedVersion !== ""
                   ? qsTr("Up to date. You skipped version %1.").arg(UpdateService.skippedVersion)
                   : qsTr("Crater is up to date.")
        case UpdateService.UpdateAvailable:
            return qsTr("Version %1 is available.").arg(UpdateService.availableVersion)
        case UpdateService.Downloading:
            return qsTr("Downloading version %1...").arg(UpdateService.availableVersion)
        case UpdateService.ReadyToInstall:
            return qsTr("Version %1 is downloaded and ready.").arg(UpdateService.availableVersion)
        case UpdateService.Failed:
            return UpdateService.lastError
        default:
            return qsTr("Crater has not checked for updates yet.")
        }
    }

    // Installing quits Crater on Windows, so it goes through the shared
    // confirm modal rather than firing on the press. The operator may well
    // be mid-service and have a screen full of congregation.
    function _confirmInstall() {
        AppState.openModal("confirm", {
            title:       qsTr("Install update now?"),
            body:        qsTr("Crater will close, install version %1, and reopen. Anything on the projection screen will disappear while it runs.")
                             .arg(UpdateService.availableVersion),
            confirmText: qsTr("Close and install"),
            onConfirm:   function() { UpdateService.installUpdate() }
        })
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
            anchors.topMargin: Theme.space.xxxl
            spacing: 0

            SettingsSectionHeader { title: qsTr("Version"); first: true }

            // ── Installed version + current status ───────────────────────
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 56

                Column {
                    anchors.left: parent.left
                    anchors.right: checkButton.left
                    anchors.rightMargin: Theme.space.md
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    Text {
                        text: qsTr("Crater %1").arg(UpdateService.currentVersion)
                        color: Theme.color.textPrimary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.bodySize
                        font.weight: Theme.font.weightMedium
                    }
                    Text {
                        width: parent.width
                        text: root._statusLabel()
                        // The failure message is the only status that earns a
                        // colour; everything else is ordinary secondary text
                        // so a routine "up to date" never reads as an alert.
                        color: root._state === UpdateService.Failed ? Theme.color.warning
                                                                    : Theme.color.textTertiary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                        wrapMode: Text.WordWrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                    }
                }

                GhostButton {
                    id: checkButton
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    iconName: "refresh-cw"
                    text: qsTr("Check now")
                    enabled: !UpdateService.busy
                    onClicked: UpdateService.checkForUpdates()
                }
            }

            Text {
                Layout.fillWidth: true
                text: root._lastCheckedLabel()
                color: Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.microSize
            }

            // ── What's in the release ────────────────────────────────────
            // Shown only while an update is actually on offer, so the
            // section stays a two-line "you're current" page the rest of
            // the time.
            SettingsSectionHeader {
                title: qsTr("What's new")
                visible: root._offering && UpdateService.releaseNotes !== ""
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 132
                visible: root._offering && UpdateService.releaseNotes !== ""
                color: Theme.color.canvas
                border.color: Theme.color.borderSubtle
                border.width: 1
                radius: 0

                Flickable {
                    id: notesFlick
                    anchors.fill: parent
                    anchors.margins: Theme.space.sm
                    contentHeight: notesText.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    Text {
                        id: notesText
                        width: notesFlick.width
                        text: UpdateService.releaseNotes
                        // PlainText on purpose. These notes are authored
                        // outside the app, and rendering them as rich text
                        // would let a release body decide how part of
                        // Crater's own UI draws itself. GitHub's generated
                        // notes are a bulleted list, which reads fine raw.
                        textFormat: Text.PlainText
                        color: Theme.color.textSecondary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                        wrapMode: Text.WordWrap
                        lineHeight: 1.35
                    }

                    ScrollBar.vertical: AppScrollBar { }
                }
            }

            // ── Download progress ────────────────────────────────────────
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: visible ? 44 : 0
                visible: root._state === UpdateService.Downloading

                Text {
                    id: progressLabel
                    anchors.left: parent.left
                    anchors.top: parent.top
                    text: UpdateService.totalBytes > 0
                          ? qsTr("%1 of %2").arg(root._sizeLabel(UpdateService.receivedBytes))
                                            .arg(root._sizeLabel(UpdateService.totalBytes))
                          : qsTr("Starting download...")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.microSize
                }

                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: progressLabel.bottom
                    anchors.topMargin: Theme.space.sm
                    height: 4
                    color: Theme.color.borderSubtle
                    radius: Theme.radius.pill

                    Rectangle {
                        height: parent.height
                        radius: parent.radius
                        color: Theme.color.brand
                        // A negative progress means the server sent no
                        // content length. Rather than fake an indeterminate
                        // animation, the bar simply stays empty and the
                        // byte count above carries the information.
                        width: UpdateService.downloadProgress >= 0
                               ? parent.width * UpdateService.downloadProgress
                               : 0
                        Behavior on width { NumberAnimation { duration: Theme.motion.instant } }
                    }
                }
            }

            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: root._offering ? Theme.space.lg : 0
            }

            // ── Actions ──────────────────────────────────────────────────
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.space.sm
                visible: root._offering

                PrimaryButton {
                    variant: "brand"
                    iconName: "download"
                    visible: root._state === UpdateService.UpdateAvailable
                    text: UpdateService.downloadSize > 0
                          ? qsTr("Download (%1)").arg(root._sizeLabel(UpdateService.downloadSize))
                          : qsTr("Download update")
                    onClicked: UpdateService.downloadUpdate()
                }

                GhostButton {
                    visible: root._state === UpdateService.Downloading
                    text: qsTr("Cancel")
                    onClicked: UpdateService.cancelDownload()
                }

                PrimaryButton {
                    variant: "brand"
                    iconName: "check"
                    visible: root._state === UpdateService.ReadyToInstall
                             && UpdateService.installMode === "run"
                    text: qsTr("Install and restart")
                    onClicked: root._confirmInstall()
                }

                // macOS cannot replace a running bundle, so the wording
                // promises what actually happens instead of a restart.
                PrimaryButton {
                    variant: "brand"
                    iconName: "external-link"
                    visible: root._state === UpdateService.ReadyToInstall
                             && UpdateService.installMode === "reveal"
                    text: qsTr("Open the disk image")
                    onClicked: UpdateService.installUpdate()
                }

                GhostButton {
                    text: qsTr("Release page")
                    iconName: "external-link"
                    onClicked: UpdateService.openReleasePage()
                }

                Item { Layout.fillWidth: true }

                GhostButton {
                    visible: root._state !== UpdateService.Downloading
                    text: qsTr("Skip this version")
                    onClicked: UpdateService.skipAvailableVersion()
                }
            }

            // Undo a skip. Only reachable once something has been skipped,
            // and re-runs the check on the spot — an undo that leaves the
            // offer hidden until tomorrow reads as a bug.
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: visible ? 44 : 0
                visible: UpdateService.skippedVersion !== ""

                Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Version %1 is being skipped.").arg(UpdateService.skippedVersion)
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                }
                GhostButton {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Stop skipping")
                    onClicked: UpdateService.clearSkippedVersion()
                }
            }

            // ── Preferences ──────────────────────────────────────────────
            SettingsSectionHeader { title: qsTr("Automatic checks") }

            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 56

                Column {
                    anchors.left: parent.left
                    anchors.right: autoToggle.left
                    anchors.rightMargin: Theme.space.md
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    Text {
                        text: qsTr("Check for updates automatically")
                        color: Theme.color.textPrimary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.bodySize
                        font.weight: Theme.font.weightMedium
                    }
                    Text {
                        width: parent.width
                        text: qsTr("Looks once a day, shortly after Crater opens. Nothing downloads or installs on its own.")
                        color: Theme.color.textTertiary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                        wrapMode: Text.WordWrap
                    }
                }

                ToggleSwitch {
                    id: autoToggle
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    value: UpdateService.autoCheck
                    onToggled: UpdateService.autoCheck = !UpdateService.autoCheck
                }
            }

            // The honest footnote. Crater ships unsigned, so the checksum
            // is the whole integrity story and the operator deserves to
            // know it rather than discovering it from a SmartScreen prompt.
            Text {
                Layout.fillWidth: true
                Layout.topMargin: Theme.space.md
                Layout.bottomMargin: Theme.space.xxl
                text: qsTr("Updates come from Crater's official release page. Every download is checked against the release's published SHA-256 before Crater will run it, and a download that does not match is deleted.")
                color: Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.microSize
                wrapMode: Text.WordWrap
                lineHeight: 1.4
            }
        }
    }
}
