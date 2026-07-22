import QtQuick
import QtQuick.Layouts

// Appearance — theme, font size, motion preferences.
// Wired rows read/write SettingsService directly (no local mirror). The
// Theme picker writes SettingsService.themeMode (an id in Theme.themes, or
// "auto"); Theme.qml swaps the active palette live off that value. The
// Language row is still Soon-flagged (no i18n catalog yet) and keeps a
// local placeholder so its disabled control renders a sensible selection.
Item {
    id: root

    // Placeholder for the still-Soon Language row — the disabled control
    // shows this without ever writing back. Moves to SettingsService once an
    // i18n catalog exists.
    property string language:  "en-US"

    // Theme options the swatch picker renders: every registered palette plus
    // an "Auto" entry that follows the OS light/dark scheme.
    readonly property var themeOptions: {
        var arr = []
        for (var i = 0; i < Theme.themes.length; i++)
            arr.push({ id: Theme.themes[i].id, name: Theme.themes[i].name, auto: false })
        arr.push({ id: "auto", name: qsTr("Auto"), auto: true })
        return arr
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

            // ── THEME ────────────────────────────────────────────────────
            SettingsSectionHeader { title: qsTr("Theme"); first: true }

            // Theme picker — one swatch per registered palette + Auto. Each
            // swatch previews that palette's own colors (via Theme.paletteFor,
            // not the active Theme.color) so you see what you're switching to.
            // Clicking writes SettingsService.themeMode; Theme.qml re-points
            // Theme.color at the chosen palette and the whole console recolors
            // live. Operator console only — projected slides use their own
            // .craterheme themes and are unaffected.
            ColumnLayout {
                Layout.fillWidth: true
                Layout.topMargin: Theme.space.lg
                Layout.bottomMargin: Theme.space.lg
                spacing: Theme.space.md

                Column {
                    spacing: 2
                    Text { text: qsTr("Theme"); color: Theme.color.textPrimary
                           font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize
                           font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Color scheme of the operator console (does not affect projected output)")
                           color: Theme.color.textTertiary; font.family: Theme.font.family
                           font.pixelSize: Theme.font.smallSize }
                }

                Flow {
                    Layout.fillWidth: true
                    spacing: Theme.space.md

                    Repeater {
                        model: root.themeOptions
                        delegate: Column {
                            id: sw
                            required property var modelData
                            readonly property bool selected: SettingsService.themeMode === modelData.id
                            readonly property QtObject pal: Theme.paletteFor(modelData.id)
                            width: 104
                            spacing: Theme.space.xs

                            // Preview card
                            Rectangle {
                                width: parent.width; height: 64
                                radius: Theme.radius.sm
                                clip: true
                                color: modelData.auto ? "transparent" : sw.pal.canvas
                                border.width: sw.selected ? 2 : 1
                                border.color: sw.selected ? Theme.color.brand : Theme.color.borderSubtle

                                Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }

                                // Auto: split light | dark to signal "follows OS"
                                Row {
                                    visible: modelData.auto
                                    anchors.fill: parent
                                    anchors.margins: 1
                                    Rectangle { width: parent.width / 2; height: parent.height
                                                color: Theme.paletteFor("light").canvas }
                                    Rectangle { width: parent.width / 2; height: parent.height
                                                color: Theme.paletteFor("dark").canvas }
                                }

                                // Concrete theme: faux panel + brand dot + text lines
                                Column {
                                    visible: !modelData.auto
                                    anchors.fill: parent
                                    anchors.margins: 8
                                    spacing: 5

                                    Rectangle {
                                        width: parent.width; height: 16; radius: 3
                                        color: sw.pal.elevated
                                        border.width: 1; border.color: sw.pal.borderSubtle
                                        Row {
                                            anchors.left: parent.left; anchors.leftMargin: 4
                                            anchors.verticalCenter: parent.verticalCenter
                                            spacing: 3
                                            Rectangle { width: 6; height: 6; radius: 3; color: sw.pal.brand
                                                        anchors.verticalCenter: parent.verticalCenter }
                                            Rectangle { width: 30; height: 4; radius: 2; color: sw.pal.textSecondary
                                                        anchors.verticalCenter: parent.verticalCenter }
                                        }
                                    }
                                    Rectangle { width: parent.width * 0.85; height: 4; radius: 2; color: sw.pal.textPrimary }
                                    Rectangle { width: parent.width * 0.6;  height: 4; radius: 2; color: sw.pal.textTertiary }
                                }

                                // Auto glyph badge
                                AppIcon {
                                    visible: modelData.auto
                                    anchors.centerIn: parent
                                    name: "monitor"
                                    size: Theme.icon.md
                                    color: Theme.color.textSecondary
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: SettingsService.themeMode = sw.modelData.id
                                }
                            }

                            // Label + selected check
                            Row {
                                spacing: 4
                                AppIcon {
                                    visible: sw.selected
                                    anchors.verticalCenter: parent.verticalCenter
                                    name: "check"; size: Theme.icon.xs; color: Theme.color.brand
                                }
                                Text {
                                    text: sw.modelData.name
                                    color: sw.selected ? Theme.color.textPrimary : Theme.color.textSecondary
                                    font.family: Theme.font.family
                                    font.pixelSize: Theme.font.smallSize
                                    font.weight: sw.selected ? Theme.font.weightSemiBold : Theme.font.weightRegular
                                }
                            }
                        }
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
