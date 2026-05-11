import QtQuick
import QtQuick.Layouts

// Appearance — theme, font size, motion preferences.
// All values are local to this Loader's lifecycle (no persistence yet).
Item {
    id: root

    property string themeMode: "dark"
    property string fontSize: "medium"
    property bool   showCcli: true
    property bool   reduceMotion: false
    property string language: "en-US"

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

            // ── Theme ────────────────────────────────────────────────────
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 56

                Column {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    Text { text: qsTr("Theme"); color: Theme.color.textPrimary;
                           font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize;
                           font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Surface color of the operator console");
                           color: Theme.color.textTertiary; font.family: Theme.font.family;
                           font.pixelSize: Theme.font.smallSize }
                }

                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.space.xs

                    Repeater {
                        model: [
                            { id: "light", label: qsTr("Light") },
                            { id: "dark",  label: qsTr("Dark") },
                            { id: "auto",  label: qsTr("Auto") }
                        ]
                        delegate: Rectangle {
                            width: 64; height: 30
                            radius: Theme.radius.md
                            color: root.themeMode === modelData.id ? Theme.color.brand : Theme.color.overlay

                            Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

                            Text {
                                anchors.centerIn: parent
                                text: modelData.label
                                color: root.themeMode === modelData.id ? Theme.color.brandInk : Theme.color.textPrimary
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.smallSize
                                font.weight: Theme.font.weightMedium
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.themeMode = modelData.id
                            }
                        }
                    }
                }
            }

            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            // ── Font size ────────────────────────────────────────────────
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 56

                Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                       text: qsTr("Font size"); color: Theme.color.textPrimary
                       font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize
                       font.weight: Theme.font.weightMedium }

                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.space.xs

                    Repeater {
                        model: [{id: "small", l: "S"}, {id: "medium", l: "M"}, {id: "large", l: "L"}]
                        delegate: Rectangle {
                            width: 40; height: 30
                            radius: Theme.radius.md
                            color: root.fontSize === modelData.id ? Theme.color.brand : Theme.color.overlay
                            Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
                            Text {
                                anchors.centerIn: parent
                                text: modelData.l
                                color: root.fontSize === modelData.id ? Theme.color.brandInk : Theme.color.textPrimary
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.smallSize
                                font.weight: Theme.font.weightSemiBold
                            }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.fontSize = modelData.id }
                        }
                    }
                }
            }

            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            // ── Toggles ──────────────────────────────────────────────────
            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("Show CCLI badges");  color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Display copyright info next to songs"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
                }
                ToggleSwitch { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    value: root.showCcli; onToggled: root.showCcli = !root.showCcli }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("Reduce motion"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Disable hover/transition animations"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
                }
                ToggleSwitch { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    value: root.reduceMotion; onToggled: root.reduceMotion = !root.reduceMotion }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            // ── Language ─────────────────────────────────────────────────
            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: qsTr("Language"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                SelectChip { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; label: "English (en-US)" }
            }

            Item { Layout.fillWidth: true; Layout.preferredHeight: Theme.space.xl }
        }
    }
}
