import QtQuick
import QtQuick.Layouts

// Search — two groups of settings, both about finding things in the library:
//
//   1. The global command palette (Ctrl+K): a cross-library search whose
//      per-result-type primary action (what pressing Enter / clicking a hit
//      does) is configured here. Persisted via
//      SettingsService.setGlobalSearchAction; the palette reads the map live.
//
//   2. How the library tabs present their own FTS results: the matched-lyric
//      snippet on song rows and per-tab term highlighting (Songs / Scripture /
//      Strong's). All default ON, so the out-of-box experience is unchanged;
//      each surface can be quieted independently.
//
// Both groups are backed by SettingsService.
Item {
    id: root

    // Result types shown as rows. `revealOnly` types can't be projected, so
    // they offer no Preview / Go Live choice.
    readonly property var _types: [
        { key: "scripture", label: qsTr("Scripture") },
        { key: "songs",     label: qsTr("Songs") },
        { key: "strongs",   label: qsTr("Strong's") },
        { key: "media",     label: qsTr("Media") },
        { key: "themes",    label: qsTr("Themes"), revealOnly: true }
    ]

    readonly property var _actionOptions: [
        { label: qsTr("Stage to Preview"), value: "preview" },
        { label: qsTr("Reveal in tab"),    value: "reveal" },
        { label: qsTr("Go Live"),          value: "golive" }
    ]

    function _actionLabel(v) {
        for (let i = 0; i < _actionOptions.length; i++)
            if (_actionOptions[i].value === v) return _actionOptions[i].label
        return _actionOptions[1].label   // reveal — the safe fallback
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

            // ── COMMAND PALETTE (Ctrl+K) ─────────────────────────────────
            SettingsSectionHeader { title: qsTr("Command palette"); first: true }

            // Explanatory note.
            Text {
                Layout.fillWidth: true
                Layout.topMargin: Theme.space.xs
                Layout.bottomMargin: Theme.space.md
                wrapMode: Text.WordWrap
                text: qsTr("Press Ctrl+K to search across every library at once. Choose what pressing Enter on a result does, per type — Stage to Preview loads it into the Preview pane without projecting, Reveal jumps to it in its library tab, and Go Live projects it immediately. Each row also offers all actions as buttons, and Ctrl+Enter / Shift+Enter always Go Live / Add to Schedule.")
                color: Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                lineHeight: 1.3
            }

            SettingsSectionHeader { title: qsTr("Default action by type") }

            Repeater {
                model: root._types
                delegate: Item {
                    required property int index
                    required property var modelData
                    Layout.fillWidth: true
                    Layout.preferredHeight: 56

                    Text {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.label
                        color: Theme.color.textPrimary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.bodySize
                        font.weight: Theme.font.weightMedium
                    }

                    // Projectable types get the full picker.
                    Combobox {
                        visible: !modelData.revealOnly
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: 200
                        searchable: false
                        options: root._actionOptions
                        value: root._actionLabel(
                            (SettingsService.globalSearchActions || ({}))[modelData.key] || "reveal")
                        onValueSelected: function(v) {
                            SettingsService.setGlobalSearchAction(modelData.key, v)
                        }
                    }

                    // Themes are never projected — reveal is the only action.
                    Text {
                        visible: !!modelData.revealOnly
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Reveal in tab")
                        color: Theme.color.textTertiary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.bodySize
                    }

                    Rectangle {
                        visible: index < root._types.length - 1
                        anchors.bottom: parent.bottom
                        anchors.left: parent.left
                        anchors.right: parent.right
                        height: 1
                        color: Theme.color.borderSubtle
                    }
                }
            }

            // ── SONGS ────────────────────────────────────────────────────
            SettingsSectionHeader { title: qsTr("Songs") }

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
