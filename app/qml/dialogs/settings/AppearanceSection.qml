import QtQuick
import QtQuick.Layouts

// Appearance — theme, font size, motion preferences.
// Wired rows read/write SettingsService directly (no local mirror). Soon-
// flagged rows keep a local placeholder value so the disabled control
// still renders a sensible selection.
Item {
    id: root

    // Local placeholders for the Soon-flagged rows. The disabled control
    // shows these without ever writing back. Once a light palette / i18n
    // catalog exists, these move to SettingsService too.
    property string themeMode: "dark"
    property string language:  "en-US"

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

            // ── THEME ────────────────────────────────────────────────────
            SettingsSectionHeader { title: qsTr("Theme"); first: true }

            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 56

                Column {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    Text { text: qsTr("Mode"); color: Theme.color.textPrimary;
                           font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize;
                           font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Surface color of the operator console");
                           color: Theme.color.textTertiary; font.family: Theme.font.family;
                           font.pixelSize: Theme.font.smallSize }
                }

                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.space.md

                    Badge {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Soon")
                        background: Theme.color.overlay
                        foreground: Theme.color.textTertiary
                    }
                    SegmentedControl {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 200; height: 30
                        opacity: 0.45
                        enabled: false
                        radius: 0
                        current: root.themeMode
                        options: [
                            { value: "light", label: qsTr("Light") },
                            { value: "dark",  label: qsTr("Dark") },
                            { value: "auto",  label: qsTr("Auto") }
                        ]
                        onChanged: function(v) { root.themeMode = v }
                    }
                }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 56

                Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                       text: qsTr("Font size"); color: Theme.color.textPrimary
                       font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize
                       font.weight: Theme.font.weightMedium }

                SegmentedControl {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 140; height: 30
                    radius: 0
                    current: SettingsService.fontSize
                    options: [
                        { value: "small",  label: qsTr("S") },
                        { value: "medium", label: qsTr("M") },
                        { value: "large",  label: qsTr("L") }
                    ]
                    onChanged: function(v) { SettingsService.fontSize = v }
                }
            }

            // ── PREFERENCES ──────────────────────────────────────────────
            SettingsSectionHeader { title: qsTr("Preferences") }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("Show CCLI badges"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Display copyright info next to songs"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
                }
                ToggleSwitch { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    value: SettingsService.showCcli
                    onToggled: SettingsService.showCcli = !SettingsService.showCcli }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("Reduce motion"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Disable hover and transition animations"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
                }
                ToggleSwitch { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    value: SettingsService.reduceMotion
                    onToggled: SettingsService.reduceMotion = !SettingsService.reduceMotion }
            }

            // ── LOCALE ───────────────────────────────────────────────────
            SettingsSectionHeader { title: qsTr("Locale") }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                       text: qsTr("Language"); color: Theme.color.textPrimary
                       font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize
                       font.weight: Theme.font.weightMedium }

                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.space.md

                    Badge {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Soon")
                        background: Theme.color.overlay
                        foreground: Theme.color.textTertiary
                    }
                    SelectChip {
                        anchors.verticalCenter: parent.verticalCenter
                        label: "English (en-US)"
                        opacity: 0.45
                        enabled: false
                        radius: 0
                    }
                }
            }

            Item { Layout.fillWidth: true; Layout.preferredHeight: Theme.space.xl }
        }
    }
}
