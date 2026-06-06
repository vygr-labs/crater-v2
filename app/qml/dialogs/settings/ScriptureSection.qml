import QtQuick
import QtQuick.Layouts

// Scripture — default Bible version, verse number display, Strong's tab.
// Highlight-current-verse and footer-line rows are aspirational (no
// rendering site yet) and carry the "Soon" badge.
Item {
    id: root

    // Local placeholders for the Soon-flagged rows below. The wired rows
    // (defaultScriptureVersion, showVerseNumbers, showStrongsTab) read/write
    // SettingsService directly.
    property bool   highlightCurrentVerse: true
    property bool   showBookChapterFooter: false

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

            // ── READING ──────────────────────────────────────────────────
            SettingsSectionHeader { title: qsTr("Reading"); first: true }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("Default version"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Version preselected when opening Scripture"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
                }
                Combobox {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 180
                    searchable: false
                    // One option per installed translation, shown by code
                    // ("KJV", "NIV") — the same vocabulary the scripture
                    // sidebar uses. Evaluated when Settings opens; importing a
                    // translation while this dialog is open won't refresh the
                    // list (matches the sidebar, which also reads
                    // translations() non-reactively).
                    options: BibleService.translations().map(function(t) { return t.code })
                    value: SettingsService.defaultScriptureVersion
                    onValueSelected: function(code) {
                        // Persist for next launch AND apply immediately — flip
                        // the scripture tab to the chosen version now (same path
                        // as a sidebar translation switch). Without the live
                        // apply, the change would silently wait for a restart
                        // and read as broken.
                        SettingsService.defaultScriptureVersion = code
                        AppState.setLibraryGroup("scripture", code.toLowerCase())
                    }
                }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                       text: qsTr("Show verse numbers"); color: Theme.color.textPrimary
                       font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize
                       font.weight: Theme.font.weightMedium }
                ToggleSwitch { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    value: SettingsService.showVerseNumbers
                    onToggled: SettingsService.showVerseNumbers = !SettingsService.showVerseNumbers }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("Highlight current verse"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Brighten the verse on display"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
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
                        value: root.highlightCurrentVerse
                        opacity: 0.45
                        enabled: false
                        onToggled: { }
                    }
                }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("Show book:chapter in footer"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Render a reference line at the bottom of the slide"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
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
                        value: root.showBookChapterFooter
                        opacity: 0.45
                        enabled: false
                        onToggled: { }
                    }
                }
            }

            // ── TABS ─────────────────────────────────────────────────────
            SettingsSectionHeader { title: qsTr("Tabs") }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("Show Strong's tab"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Greek/Hebrew concordance lookup"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
                }
                ToggleSwitch { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    value: SettingsService.showStrongsTab
                    onToggled: SettingsService.showStrongsTab = !SettingsService.showStrongsTab }
            }

            Item { Layout.fillWidth: true; Layout.preferredHeight: Theme.space.xl }
        }
    }
}
