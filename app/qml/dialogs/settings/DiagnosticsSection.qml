import QtQuick
import QtQuick.Layouts

// Diagnostics — lets the operator hand the developers a log file when
// something goes wrong. The log upload is user-initiated: nothing leaves the
// machine without the explicit button press below. The one automatic report,
// sent only after a launch that failed before the console appeared, has its
// own switch at the bottom (ARCHITECTURE.md §11). Wired to LogReportService.
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

            Item { Layout.fillWidth: true; Layout.preferredHeight: Theme.space.xl }
        }
    }
}
