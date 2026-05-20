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

            // BrowserCast (removable feature) — operator on/off toggle plus
            // the on-screen URL to open in a TV/phone browser. Sits above the
            // v1.1 disclaimer because, unlike the rest of this section, it is
            // a working feature. Delete this whole block (down to and
            // including the spacer Item that follows it) to remove — see
            // BrowserCastService.h.
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 56
                Column {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    Text { text: qsTr("Cast to TV browser"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Serve the live projection to a TV or phone browser over Wi-Fi"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
                }
                // Bound to BrowserCastService.listening, so if start() fails
                // (e.g. no free port) the switch falls back to off on its own.
                ToggleSwitch {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    value: BrowserCastService.listening
                    onToggled: {
                        if (BrowserCastService.listening) BrowserCastService.stop()
                        else                              BrowserCastService.start()
                    }
                }
            }

            Item { Layout.fillWidth: true; Layout.preferredHeight: Theme.space.sm }

            // URL banner — brand wash + address while casting is on; a muted
            // placeholder while off. CONNECTED lights up when a browser is
            // actively pulling the stream.
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 60
                radius: 0
                color: BrowserCastService.listening ? Theme.color.brandSubtle
                                                     : Theme.color.overlay
                border.color: BrowserCastService.listening ? Theme.color.brand
                                                           : Theme.color.borderSubtle
                border.width: 1

                Row {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Theme.space.md
                    spacing: Theme.space.md

                    AppIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "tv"
                        color: BrowserCastService.listening ? Theme.color.brand
                                                            : Theme.color.textTertiary
                        size: Theme.icon.sm
                    }
                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2

                        Text {
                            text: BrowserCastService.listening
                                  ? qsTr("Open this address in the TV's web browser")
                                  : qsTr("Casting is off")
                            color: Theme.color.textSecondary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.smallSize
                        }
                        Text {
                            text: BrowserCastService.listening
                                  ? BrowserCastService.url
                                  : qsTr("Turn on the toggle above to get an address")
                            color: BrowserCastService.listening ? Theme.color.textPrimary
                                                                : Theme.color.textTertiary
                            font.family: BrowserCastService.listening ? Theme.font.monoFamily
                                                                      : Theme.font.family
                            font.pixelSize: Theme.font.bodySize
                            font.weight: Theme.font.weightSemiBold
                        }
                    }
                }

                // Lights up while a browser is actively pulling the stream.
                Text {
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.space.md
                    anchors.verticalCenter: parent.verticalCenter
                    visible: BrowserCastService.active
                    text: qsTr("CONNECTED")
                    color: Theme.color.brand
                    font.family: Theme.font.monoFamily
                    font.pixelSize: 10
                    font.weight: Theme.font.weightSemiBold
                    font.letterSpacing: 0.8
                }
            }
            Item { Layout.fillWidth: true; Layout.preferredHeight: Theme.space.md }

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
