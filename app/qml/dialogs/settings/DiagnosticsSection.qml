// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2024-2026 Eyetu Kingsley. Part of Crater, see LICENSE and NOTICE.

import QtQuick
import QtQuick.Layouts

// Diagnostics — lets the operator hand the developers a log file when
// something goes wrong. The log upload is user-initiated: nothing leaves the
// machine without the explicit button press below. The one automatic report,
// sent only after a launch that failed before the console appeared, has its
// own switch, and so do the opt-in usage numbers (ARCHITECTURE.md §11).
// Wired to LogReportService and UsageService.
Item {
    id: root

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

            SettingsSectionHeader { title: qsTr("Send logs"); first: true }

            // This paragraph is the consent surface — it states plainly what
            // the upload contains. The operator reads it, then presses the
            // explicit button below; that press is the opt-in.
            Text {
                Layout.fillWidth: true
                text: qsTr("If something isn't working right, send your log file to the Crater team. It helps them track down the cause. The log lists file names and paths from your media library and a record of recent app activity. It contains no passwords.")
                color: Theme.color.textSecondary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                wrapMode: Text.WordWrap
                lineHeight: 1.4
            }

            Item { Layout.fillWidth: true; Layout.preferredHeight: Theme.space.lg }

            // ── Optional note ────────────────────────────────────────────
            Text {
                text: qsTr("What went wrong? (optional)")
                color: Theme.color.textPrimary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                font.weight: Theme.font.weightMedium
            }
            Item { Layout.fillWidth: true; Layout.preferredHeight: Theme.space.xs }
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 68
                radius: 0
                color: Theme.color.canvas
                border.color: noteInput.activeFocus ? Theme.color.brand
                                                    : Theme.color.borderStrong
                border.width: 1

                TextEdit {
                    id: noteInput
                    anchors.fill: parent
                    anchors.margins: Theme.space.sm
                    color: Theme.color.textPrimary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                    wrapMode: TextEdit.Wrap
                    selectByMouse: true
                    HoverHandler { cursorShape: Qt.IBeamCursor }
                }
            }

            Item { Layout.fillWidth: true; Layout.preferredHeight: Theme.space.lg }

            // ── Action ───────────────────────────────────────────────────
            PrimaryButton {
                Layout.alignment: Qt.AlignLeft
                variant: "brand"
                text: LogReportService.status === LogReportService.Sending
                      ? qsTr("Sending...")
                      : qsTr("Send logs to developer")
                enabled: LogReportService.logAvailable
                      && LogReportService.status !== LogReportService.Sending
                onClicked: LogReportService.sendLogs(noteInput.text)
            }

            // ── Outcome ──────────────────────────────────────────────────
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Theme.space.md
                visible: LogReportService.status === LogReportService.Sent
                      || LogReportService.status === LogReportService.Failed
                spacing: Theme.space.sm

                AppIcon {
                    Layout.alignment: Qt.AlignTop
                    name: LogReportService.status === LogReportService.Sent
                          ? "check" : "alert-triangle"
                    color: LogReportService.status === LogReportService.Sent
                           ? Theme.color.brand : Theme.color.live
                    size: Theme.icon.sm
                }
                Text {
                    Layout.fillWidth: true
                    text: LogReportService.status === LogReportService.Sent
                          ? qsTr("Logs sent. Thank you, the team has what they need.")
                          : qsTr("Couldn't send the logs: %1").arg(LogReportService.lastError)
                    color: LogReportService.status === LogReportService.Sent
                           ? Theme.color.textSecondary : Theme.color.live
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                    wrapMode: Text.WordWrap
                    lineHeight: 1.4
                }
            }

            // Shown only if there is genuinely no log file to send.
            Text {
                Layout.fillWidth: true
                Layout.topMargin: Theme.space.md
                visible: !LogReportService.logAvailable
                text: qsTr("No log file has been created yet, so there is nothing to send.")
                color: Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
            }

            SettingsSectionHeader { title: qsTr("Startup problems") }

            SettingRow {
                title: qsTr("Report when Crater fails to start")
                description: qsTr("If Crater closes before its window appears, the next launch sends the startup record and recent log to the Crater team. Nothing is sent when Crater starts normally.")
                ToggleSwitch {
                    value: SettingsService.reportStartupFailures
                    onToggled: SettingsService.reportStartupFailures = !SettingsService.reportStartupFailures
                }
            }

            // Off until switched on here (ARCHITECTURE.md §11). The
            // description is the consent surface, so it names everything a
            // report holds. Wired to UsageService.
            SettingsSectionHeader { title: qsTr("Usage numbers") }

            SettingRow {
                title: qsTr("Share anonymous usage")
                description: qsTr("Helps the Crater team see how many churches use it and what to work on. Sends a random ID made for this, your Crater version, your operating system and its version, the processor type, your computer's language and region setting, how often Crater opens, and how often songs, verses and media go live. The website also works out your country from the connection, and keeps no IP address. Never song titles, verses, file names or anything that says who you are.")
                ToggleSwitch {
                    value: UsageService.share
                    onToggled: UsageService.share = !UsageService.share
                }
            }

            Text {
                Layout.fillWidth: true
                visible: UsageService.share
                text: {
                    const when = UsageService.lastSent
                    return (!when || isNaN(when.getTime()))
                        ? qsTr("Nothing sent yet.")
                        : qsTr("Last sent %1").arg(Qt.formatDateTime(when, "d MMM yyyy, h:mm ap"))
                }
                color: Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.microSize
            }

            // What the console draws with. Crater moves off the default by
            // itself after a launch that can't start its display, or a
            // crash in the graphics driver during a service (StartupGuard.h),
            // and this is where the operator sees that and undoes it. The
            // change holds for the running session, so a reset only says
            // what the next launch will do.
            SettingsSectionHeader { title: qsTr("Graphics") }

            SettingRow {
                id: graphicsRow
                readonly property string mode: GraphicsStatus.mode
                readonly property bool onDefault: mode === "direct3d"
                title: {
                    if (GraphicsStatus.chosenByHand) return qsTr("Set by an environment variable")
                    switch (mode) {
                    case "opengl":   return qsTr("OpenGL")
                    case "warp":     return qsTr("Direct3D software rendering")
                    case "software": return qsTr("Software rendering")
                    }
                    return Qt.platform.os === "windows" ? qsTr("Direct3D")
                                                        : qsTr("Default")
                }
                description: {
                    if (GraphicsStatus.chosenByHand)
                        return qsTr("QSG_RHI_BACKEND or QT_QUICK_BACKEND picks how Crater draws on this computer. Crater leaves that choice alone.")
                    if (GraphicsStatus.resetPending)
                        return qsTr("Crater goes back to the default the next time it opens.")
                    switch (mode) {
                    case "opengl":
                        return qsTr("Crater switched to OpenGL after the graphics driver crashed during a service%1. Switch back if the driver was updated or the crash had another cause.")
                            .arg(GraphicsStatus.driverCrash.length > 0
                                 ? " (" + GraphicsStatus.driverCrash.split("+")[0] + ")" : "")
                    case "warp":
                        return qsTr("Crater could not start its display on the graphics card, so it draws on the processor. Video may play less smoothly.")
                    case "software":
                        return qsTr("Crater could not start its display on the graphics card, so it uses its simplest renderer. Video and effects may play less smoothly.")
                    }
                    return qsTr("Crater draws with the graphics card, the default.")
                }
                GhostButton {
                    visible: !graphicsRow.onDefault && !GraphicsStatus.chosenByHand
                             && !GraphicsStatus.resetPending
                    text: qsTr("Switch back to the default")
                    onClicked: GraphicsStatus.resetToDefault()
                }
            }

            Item { Layout.fillWidth: true; Layout.preferredHeight: Theme.space.xl }
        }
    }
}
