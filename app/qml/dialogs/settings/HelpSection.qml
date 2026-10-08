import QtQuick
import QtQuick.Layouts

// Help: the tutorial videos, the docs and a way to report a problem. The
// addresses come from HelpLinks (crater-core) so they live in one file. The
// labels live here, keyed by playlist id, so they get translated.
Item {
    id: root

    readonly property var playlistLabels: ({
        "getting-started": qsTr("Getting started"),
        "scripture":       qsTr("Scripture"),
        "songs":           qsTr("Songs"),
        "media":           qsTr("Media and sermon slides"),
        "planning":        qsTr("Planning the service"),
        "themes":          qsTr("Themes"),
        "screens":         qsTr("Screens and streaming"),
        "settings":        qsTr("Settings and profiles"),
        "shortcuts":       qsTr("Keyboard shortcuts")
    })

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

            SettingsSectionHeader { title: qsTr("Tutorials"); first: true }

            SettingRow {
                title: qsTr("Watch the tutorials")
                description: qsTr("Short videos on every part of Crater, on YouTube")
                GhostButton {
                    iconName: "external-link"
                    text: qsTr("Open channel")
                    onClicked: Qt.openUrlExternally(HelpLinks.channel)
                }
            }

            Repeater {
                model: HelpLinks.playlistIds
                delegate: SettingRow {
                    required property string modelData
                    title: root.playlistLabels[modelData] || modelData
                    GhostButton {
                        iconName: "circle-play"
                        text: qsTr("Watch")
                        onClicked: Qt.openUrlExternally(HelpLinks.playlist(modelData))
                    }
                }
            }

            SettingsSectionHeader { title: qsTr("Docs and support") }

            SettingRow {
                title: qsTr("Read the docs")
                description: qsTr("Guides and reference for every feature")
                GhostButton {
                    iconName: "external-link"
                    text: qsTr("Open docs")
                    onClicked: Qt.openUrlExternally(HelpLinks.docs)
                }
            }

            // The docs and the website share an address today, and two
            // buttons opening the same page would only confuse. The row
            // comes back on its own if they're ever split.
            SettingRow {
                visible: HelpLinks.website !== HelpLinks.docs
                title: qsTr("Website")
                description: HelpLinks.website.replace(/^https:\/\//, "").replace(/\/$/, "")
                GhostButton {
                    iconName: "globe"
                    text: qsTr("Open website")
                    onClicked: Qt.openUrlExternally(HelpLinks.website)
                }
            }

            SettingRow {
                title: qsTr("Report a problem")
                description: qsTr("Send your log file to the Crater team from Diagnostics")
                GhostButton {
                    iconName: "life-buoy"
                    text: qsTr("Go to Diagnostics")
                    onClicked: AppState.settingsSection = "diagnostics"
                }
            }

            Item { Layout.fillWidth: true; Layout.preferredHeight: Theme.space.xl }
        }
    }
}
