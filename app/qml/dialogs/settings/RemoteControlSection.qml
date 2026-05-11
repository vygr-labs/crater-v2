import QtQuick
import QtQuick.Layouts

// Remote Control — phone-based remote (planned for v1.1).
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
            anchors.topMargin: Theme.space.lg
            spacing: 0

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("Enable remote control"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Allow a phone or tablet to control playback over Wi-Fi"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
                }
                ToggleSwitch { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; value: root.featureEnabled; onToggled: root.featureEnabled = !root.featureEnabled }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: qsTr("Port"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                Rectangle {
                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    width: 100; height: 30
                    radius: Theme.radius.md
                    color: Theme.color.canvas
                    border.color: portInput.activeFocus ? Theme.color.brand : Theme.color.borderStrong
                    border.width: 1
                    Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }

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
                        selectByMouse: true
                        validator: IntValidator { bottom: 1; top: 65535 }
                        enabled: root.featureEnabled
                        onTextChanged: root.port = text
                    }
                }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("Require password"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Devices must enter a code before they can pair"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
                }
                ToggleSwitch { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; value: root.requirePassword; onToggled: root.requirePassword = !root.requirePassword }
            }

            Item { Layout.fillWidth: true; Layout.preferredHeight: Theme.space.xl }

            // Footer note — flag that this section is feature-flagged for v1.1.
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 36
                radius: Theme.radius.md
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
                        size: 13
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Remote control ships in v1.1 — settings here are preview only.")
                        color: Theme.color.textSecondary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                    }
                }
            }
        }
    }
}
