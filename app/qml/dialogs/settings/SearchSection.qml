import QtQuick
import QtQuick.Layouts

// Search — how the library tabs present FTS search results: the matched-lyric
// snippet on song rows, and per-tab term highlighting (Songs / Scripture /
// Strong's). All default ON, so the out-of-box experience is unchanged; each
// surface can be quieted independently. Backed by SettingsService.
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

            // ── SONGS ────────────────────────────────────────────────────
            SettingsSectionHeader { title: qsTr("Songs"); first: true }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("Show matched lyric"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Show the matched line of lyrics under a song while searching"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
                }
                ToggleSwitch { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    value: SettingsService.showMatchedLyricSnippet
                    onToggled: SettingsService.showMatchedLyricSnippet = !SettingsService.showMatchedLyricSnippet }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("Highlight matches"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Colour the matched words in titles, authors and lyric snippets"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
                }
                ToggleSwitch { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    value: SettingsService.highlightSongMatches
                    onToggled: SettingsService.highlightSongMatches = !SettingsService.highlightSongMatches }
            }

            // ── SCRIPTURE ────────────────────────────────────────────────
            SettingsSectionHeader { title: qsTr("Scripture") }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("Highlight matches"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Colour the matched words in verse search results"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
                }
                ToggleSwitch { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    value: SettingsService.highlightScriptureMatches
                    onToggled: SettingsService.highlightScriptureMatches = !SettingsService.highlightScriptureMatches }
            }

            // ── STRONG'S ─────────────────────────────────────────────────
            SettingsSectionHeader { title: qsTr("Strong's") }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("Highlight matches"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Colour the matched words in dictionary results"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
                }
                ToggleSwitch { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    value: SettingsService.highlightStrongsMatches
                    onToggled: SettingsService.highlightStrongsMatches = !SettingsService.highlightStrongsMatches }
            }

            Item { Layout.fillWidth: true; Layout.preferredHeight: Theme.space.xl }
        }
    }
}
