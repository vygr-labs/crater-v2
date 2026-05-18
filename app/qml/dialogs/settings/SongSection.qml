import QtQuick
import QtQuick.Layouts

// Song — author/CCLI display, auto-advance, default theme.
// Default-theme picker has no popover yet, and auto-advance has no
// timer infrastructure — both carry the "Soon" badge.
Item {
    id: root

    // Local placeholders for Soon-flagged rows. Show author + Show CCLI
    // read/write SettingsService directly.
    property bool   autoAdvance: false
    property string defaultTheme: "Classic Dark"

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

            // ── DISPLAY ──────────────────────────────────────────────────
            SettingsSectionHeader { title: qsTr("Display"); first: true }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                       text: qsTr("Show author"); color: Theme.color.textPrimary
                       font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize
                       font.weight: Theme.font.weightMedium }
                ToggleSwitch { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    value: SettingsService.showSongAuthor
                    onToggled: SettingsService.showSongAuthor = !SettingsService.showSongAuthor }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("Show CCLI number"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Display copyright tag below song title"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
                }
                ToggleSwitch { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    value: SettingsService.showSongCcli
                    onToggled: SettingsService.showSongCcli = !SettingsService.showSongCcli }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("Default theme"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Applied to new songs when no theme is set"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
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
                    SelectChip {
                        anchors.verticalCenter: parent.verticalCenter
                        label: root.defaultTheme
                        opacity: 0.45
                        enabled: false
                        radius: 0
                    }
                }
            }

            // ── PLAYBACK ─────────────────────────────────────────────────
            SettingsSectionHeader { title: qsTr("Playback") }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("Auto-advance slides"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Move to next slide automatically after a delay"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
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
                    ToggleSwitch {
                        anchors.verticalCenter: parent.verticalCenter
                        value: root.autoAdvance
                        opacity: 0.45
                        enabled: false
                        onToggled: { }
                    }
                }
            }

            Item { Layout.fillWidth: true; Layout.preferredHeight: Theme.space.xl }
        }
    }
}
