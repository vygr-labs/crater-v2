import QtQuick
import QtQuick.Layouts

// Remote Control — phone-based remote (planned for v1.1).
// Entire section is preview-only; the banner at the top signals that,
// and the controls below are dimmed + disabled until v1.1 lands.
Item {
    id: root

    property bool   featureEnabled: false
    property bool   requirePassword: true
    property string port: "8080"

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

            // ── Section disclaimer ───────────────────────────────────────
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 40
                radius: 0
                color: Theme.color.brandSubtle
                border.color: Theme.color.brand
                border.width: 1

                Row {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.space.md
                    anchors.rightMargin: Theme.space.md
                    spacing: Theme.space.sm

                    AppIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "info"
                        color: Theme.color.brand
                        size: Theme.icon.sm
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Remote control ships in v1.1 — controls below are a preview.")
                        color: Theme.color.textSecondary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                    }
                }
            }

            // ── CONNECTION ───────────────────────────────────────────────
            SettingsSectionHeader { title: qsTr("Connection") }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("Enable remote control"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Allow a phone or tablet to control playback over Wi-Fi"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
                }
                ToggleSwitch {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    value: root.featureEnabled
                    opacity: 0.45
                    enabled: false
                    onToggled: { }
                }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                       text: qsTr("Port"); color: Theme.color.textPrimary
                       font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize
                       font.weight: Theme.font.weightMedium }
                Rectangle {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 100; height: 30
                    radius: 0
                    color: Theme.color.canvas
                    border.color: Theme.color.borderStrong
                    border.width: 1
                    opacity: 0.45

                    TextInput {
                        id: portInput
                        anchors.fill: parent
                        anchors.leftMargin: Theme.space.md
                        anchors.rightMargin: Theme.space.md
                        verticalAlignment: TextInput.AlignVCenter
                        text: root.port
                        color: Theme.color.textPrimary
                        font.family: Theme.font.monoFamily
                        font.pixelSize: Theme.font.smallSize
                        enabled: false
                        readOnly: true
                    }
                }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("Require password"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Devices must enter a code before they can pair"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
                }
                ToggleSwitch {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    value: root.requirePassword
                    opacity: 0.45
                    enabled: false
                    onToggled: { }
                }
            }

            Item { Layout.fillWidth: true; Layout.preferredHeight: Theme.space.xl }
        }
    }
}
