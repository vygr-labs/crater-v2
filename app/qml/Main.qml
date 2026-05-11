import QtQuick
import QtQuick.Window
import QtQuick.Controls.Basic
import QtQuick.Layouts

ApplicationWindow {
    id: root

    width: 1440
    height: 900
    minimumWidth: 1080
    minimumHeight: 680
    visible: true
    title: qsTr("Crater")
    color: Theme.color.canvas

    // ─────────────────────────────────────────────────────────────────────
    // Top bar
    // ─────────────────────────────────────────────────────────────────────
    Rectangle {
        id: topBar

        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: Theme.size.topBarHeight
        color: Theme.color.elevated

        Rectangle {
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: 1
            color: Theme.color.borderSubtle
        }

        // Left cluster: Schedule dropdown + cog + Import
        Row {
            anchors.left: parent.left
            anchors.leftMargin: Theme.space.lg
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.space.sm

            // Schedule dropdown
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                height: 34
                width: scheduleDropdownRow.implicitWidth + Theme.space.lg * 2
                radius: Theme.radius.md
                color: scheduleDropdownMa.containsMouse ? Theme.color.overlay : "transparent"

                Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

                Row {
                    id: scheduleDropdownRow
                    anchors.centerIn: parent
                    spacing: Theme.space.sm

                    AppIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "file-text"
                        color: Theme.color.textSecondary
                        size: 15
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Schedule")
                        color: Theme.color.textPrimary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.bodySize
                        font.weight: Theme.font.weightMedium
                    }
                    AppIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "chevron-down"
                        color: Theme.color.textTertiary
                        size: 12
                    }
                }
                MouseArea {
                    id: scheduleDropdownMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                }
            }

            IconButton {
                anchors.verticalCenter: parent.verticalCenter
                iconName: "settings"
                iconSize: 14
            }

            Item { width: Theme.space.md; height: 1 }

            // Import button
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                height: 34
                width: importRow.implicitWidth + Theme.space.lg * 2
                radius: Theme.radius.md
                color: importMa.containsMouse ? Theme.color.overlay : "transparent"

                Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

                Row {
                    id: importRow
                    anchors.centerIn: parent
                    spacing: Theme.space.sm

                    AppIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "arrow-up-right"
                        color: Theme.color.textSecondary
                        size: 14
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Import")
                        color: Theme.color.textPrimary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.bodySize
                        font.weight: Theme.font.weightMedium
                    }
                }
                MouseArea {
                    id: importMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                }
            }
        }

        // Right cluster: Logo + Clear + Go Live
        Row {
            anchors.right: parent.right
            anchors.rightMargin: Theme.space.lg
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.space.sm

            // Logo button (ghost)
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                height: 34
                width: logoRow.implicitWidth + Theme.space.lg * 2
                radius: Theme.radius.md
                color: logoMa.containsMouse ? Theme.color.overlay : "transparent"
                border.color: Theme.color.borderStrong
                border.width: 1

                Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

                Row {
                    id: logoRow
                    anchors.centerIn: parent
                    spacing: Theme.space.sm

                    AppIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "list-ordered"
                        color: Theme.color.brand
                        size: 14
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Logo")
                        color: Theme.color.textPrimary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.bodySize
                        font.weight: Theme.font.weightMedium
                    }
                }
                MouseArea {
                    id: logoMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                }
            }

            // Clear button (ghost)
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                height: 34
                width: clearRow.implicitWidth + Theme.space.lg * 2
                radius: Theme.radius.md
                color: clearMa.containsMouse ? Theme.color.overlay : "transparent"
                border.color: Theme.color.borderStrong
                border.width: 1

                Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

                Row {
                    id: clearRow
                    anchors.centerIn: parent
                    spacing: Theme.space.sm

                    AppIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "menu"
                        color: Theme.color.textSecondary
                        size: 14
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Clear")
                        color: Theme.color.textPrimary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.bodySize
                        font.weight: Theme.font.weightMedium
                    }
                }
                MouseArea {
                    id: clearMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                }
            }

            // Go Live (primary)
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                height: 34
                width: goLiveRow.implicitWidth + Theme.space.lg * 2
                radius: Theme.radius.md
                color: goLiveMa.pressed       ? Theme.color.goLivePressed
                     : goLiveMa.containsMouse ? Theme.color.goLiveHover
                                              : Theme.color.goLive

                Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

                Row {
                    id: goLiveRow
                    anchors.centerIn: parent
                    spacing: Theme.space.sm

                    AppIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "play"
                        color: Theme.color.goLiveInk
                        size: 13
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Go Live")
                        color: Theme.color.goLiveInk
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.bodySize
                        font.weight: Theme.font.weightSemiBold
                        font.letterSpacing: 0.3
                    }
                }
                MouseArea {
                    id: goLiveMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // Main work surface
    // ─────────────────────────────────────────────────────────────────────
    Item {
        id: mainArea

        anchors.top: topBar.bottom
        anchors.bottom: footerBar.top
        anchors.left: parent.left
        anchors.right: parent.right

        property real topRowRatio: 0.58

        // ── TOP ROW: Schedule | Preview | Live
        Item {
            id: topRow

            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: parent.height * mainArea.topRowRatio

            // Schedule pane
            Rectangle {
                id: schedulePane

                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                width: parent.width * 0.30
                color: "transparent"

                Item {
                    id: scheduleHeader
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: 40

                    Row {
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.space.lg
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.space.sm
                        AppIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: "menu"
                            color: Theme.color.textSecondary
                            size: 14
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: qsTr("Schedule")
                            color: Theme.color.textPrimary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.bodySize
                            font.weight: Theme.font.weightMedium
                        }
                    }

                    IconButton {
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.space.md
                        anchors.verticalCenter: parent.verticalCenter
                        iconName: "grid"
                        iconSize: 13
                    }

                    Rectangle {
                        anchors.bottom: parent.bottom
                        anchors.left: parent.left
                        anchors.right: parent.right
                        height: 1
                        color: Theme.color.borderSubtle
                    }
                }

                Item {
                    anchors.top: scheduleHeader.bottom
                    anchors.bottom: parent.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right

                    ColumnLayout {
                        anchors.centerIn: parent
                        spacing: Theme.space.sm

                        AppIcon {
                            Layout.alignment: Qt.AlignHCenter
                            Layout.bottomMargin: Theme.space.xs
                            name: "music"
                            color: Theme.color.textTertiary
                            size: 32
                            opacity: 0.7
                        }
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: qsTr("No items in schedule")
                            color: Theme.color.textSecondary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.bodySize + 2
                            font.weight: Theme.font.weightMedium
                        }
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: qsTr("Add songs, scriptures, or media from the tabs below")
                            color: Theme.color.textTertiary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.smallSize
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.WordWrap
                            Layout.maximumWidth: 280
                        }
                    }
                }

                Rectangle {
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: 1
                    color: Theme.color.borderSubtle
                }
            }

            // Preview pane
            Rectangle {
                id: previewPane

                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.left: schedulePane.right
                anchors.right: livePane.left
                color: "transparent"

                Item {
                    id: previewHeader
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: 40

                    Row {
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.space.lg
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.space.sm

                        AppIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: "eye"
                            color: Theme.color.preview
                            size: 14
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: qsTr("Preview")
                            color: Theme.color.textPrimary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.bodySize
                            font.weight: Theme.font.weightMedium
                        }
                    }

                    IconButton {
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.space.md
                        anchors.verticalCenter: parent.verticalCenter
                        iconName: "settings"
                        iconSize: 13
                    }

                    Rectangle {
                        anchors.bottom: parent.bottom
                        anchors.left: parent.left
                        anchors.right: parent.right
                        height: 1
                        color: Theme.color.borderSubtle
                    }
                }

                Item {
                    anchors.top: previewHeader.bottom
                    anchors.bottom: previewMonitorWrap.top
                    anchors.left: parent.left
                    anchors.right: parent.right

                    ColumnLayout {
                        anchors.centerIn: parent
                        spacing: Theme.space.sm

                        AppIcon {
                            Layout.alignment: Qt.AlignHCenter
                            Layout.bottomMargin: Theme.space.xs
                            name: "eye"
                            color: Theme.color.textTertiary
                            size: 32
                            opacity: 0.7
                        }
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: qsTr("No item selected")
                            color: Theme.color.textSecondary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.bodySize + 2
                            font.weight: Theme.font.weightMedium
                        }
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: qsTr("Select an item from the schedule to preview")
                            color: Theme.color.textTertiary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.smallSize
                        }
                    }
                }

                Item {
                    id: previewMonitorWrap
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: Theme.space.lg
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 280
                    height: 158

                    Rectangle {
                        anchors.fill: parent
                        radius: Theme.radius.md
                        color: "#000000"
                        border.color: Theme.color.borderStrong
                        border.width: 1

                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: 1
                            radius: parent.radius - 1
                            gradient: Gradient {
                                GradientStop { position: 0.0; color: "#0d0d12" }
                                GradientStop { position: 1.0; color: "#050508" }
                            }
                        }

                        Text {
                            anchors.centerIn: parent
                            text: qsTr("No preview")
                            color: Theme.color.textTertiary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.smallSize
                        }
                    }
                }

                Rectangle {
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: 1
                    color: Theme.color.borderSubtle
                }
            }

            // Live pane
            Rectangle {
                id: livePane

                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.right: parent.right
                width: parent.width * 0.36
                color: "transparent"

                Item {
                    id: liveHeader
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: 40

                    // Proper LIVE pill — rounded badge with text inside
                    Rectangle {
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.space.lg
                        anchors.verticalCenter: parent.verticalCenter
                        height: 22
                        width: liveLabel.implicitWidth + Theme.space.md * 2 + liveDot.width + Theme.space.xs
                        radius: 4
                        color: Theme.color.live

                        Row {
                            anchors.centerIn: parent
                            spacing: Theme.space.xs

                            Rectangle {
                                id: liveDot
                                anchors.verticalCenter: parent.verticalCenter
                                width: 6; height: 6; radius: 3
                                color: "#ffffff"
                            }
                            Text {
                                id: liveLabel
                                anchors.verticalCenter: parent.verticalCenter
                                text: qsTr("LIVE")
                                color: "#ffffff"
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.smallSize
                                font.weight: Theme.font.weightSemiBold
                                font.letterSpacing: 1.0
                            }
                        }
                    }

                    IconButton {
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.space.md
                        anchors.verticalCenter: parent.verticalCenter
                        iconName: "settings"
                        iconSize: 13
                    }

                    Rectangle {
                        anchors.bottom: parent.bottom
                        anchors.left: parent.left
                        anchors.right: parent.right
                        height: 1
                        color: Theme.color.borderSubtle
                    }
                }

                Item {
                    anchors.top: liveHeader.bottom
                    anchors.bottom: liveMonitorWrap.top
                    anchors.left: parent.left
                    anchors.right: parent.right

                    ColumnLayout {
                        anchors.centerIn: parent
                        spacing: Theme.space.sm

                        AppIcon {
                            Layout.alignment: Qt.AlignHCenter
                            Layout.bottomMargin: Theme.space.xs
                            name: "radio"
                            color: Theme.color.textTertiary
                            size: 32
                            opacity: 0.7
                        }
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: qsTr("Nothing live")
                            color: Theme.color.textSecondary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.bodySize + 2
                            font.weight: Theme.font.weightMedium
                        }
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: qsTr("Double-click a preview item to go live")
                            color: Theme.color.textTertiary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.smallSize
                        }
                    }
                }

                Item {
                    id: liveMonitorWrap
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: Theme.space.lg
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 320
                    height: 180

                    Rectangle {
                        anchors.fill: parent
                        radius: Theme.radius.md
                        color: "#000000"
                        border.color: Theme.color.borderStrong
                        border.width: 1

                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: 1
                            radius: parent.radius - 1
                            gradient: Gradient {
                                GradientStop { position: 0.0; color: "#0d0d12" }
                                GradientStop { position: 1.0; color: "#050508" }
                            }
                        }
                    }
                }
            }
        }

        Rectangle {
            id: midDivider
            anchors.top: topRow.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: 1
            color: Theme.color.borderSubtle
        }

        // ── BOTTOM SECTION
        Item {
            id: bottomRow

            anchors.top: midDivider.bottom
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right

            // Tab bar
            Item {
                id: tabBar
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                height: 42

                Row {
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.space.md
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    Repeater {
                        model: [
                            { l: qsTr("Songs"),     icon: "music",     active: true  },
                            { l: qsTr("Scripture"), icon: "book-open", active: false },
                            { l: qsTr("Strong's"),  icon: "",          active: false, customGlyph: "S" },
                            { l: qsTr("Media"),     icon: "film",      active: false },
                            { l: qsTr("Themes"),    icon: "palette",   active: false }
                        ]

                        delegate: Item {
                            width: tabRow.implicitWidth + Theme.space.lg * 2
                            height: tabBar.height

                            Row {
                                id: tabRow
                                anchors.centerIn: parent
                                spacing: Theme.space.sm

                                AppIcon {
                                    visible: modelData.icon.length > 0
                                    anchors.verticalCenter: parent.verticalCenter
                                    name: modelData.icon
                                    color: modelData.active     ? Theme.color.brand
                                         : tabMa.containsMouse  ? Theme.color.textPrimary
                                                                : Theme.color.textTertiary
                                    size: 13

                                    Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
                                }
                                Text {
                                    visible: !modelData.icon || modelData.icon.length === 0
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: modelData.customGlyph || ""
                                    color: modelData.active     ? Theme.color.brand
                                         : tabMa.containsMouse  ? Theme.color.textPrimary
                                                                : Theme.color.textTertiary
                                    font.family: Theme.font.family
                                    font.pixelSize: 14
                                    font.weight: Theme.font.weightSemiBold
                                    font.italic: true
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: modelData.l
                                    color: modelData.active     ? Theme.color.textPrimary
                                         : tabMa.containsMouse  ? Theme.color.textSecondary
                                                                : Theme.color.textTertiary
                                    font.family: Theme.font.family
                                    font.pixelSize: Theme.font.bodySize
                                    font.weight: modelData.active ? Theme.font.weightSemiBold
                                                                  : Theme.font.weightRegular

                                    Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
                                }
                            }

                            Rectangle {
                                visible: modelData.active
                                anchors.bottom: parent.bottom
                                anchors.horizontalCenter: parent.horizontalCenter
                                width: parent.width - Theme.space.lg
                                height: 2
                                radius: 1
                                color: Theme.color.brand
                            }

                            MouseArea {
                                id: tabMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                            }
                        }
                    }
                }

                Rectangle {
                    anchors.bottom: parent.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: 1
                    color: Theme.color.borderSubtle
                }
            }

            // Library nav
            Rectangle {
                id: libraryNav

                anchors.top: tabBar.bottom
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                width: parent.width * 0.24
                color: "transparent"

                ColumnLayout {
                    anchors.fill: parent
                    anchors.topMargin: Theme.space.md
                    spacing: Theme.space.xs

                    // Search
                    Item {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 36
                        Layout.leftMargin: Theme.space.lg
                        Layout.rightMargin: Theme.space.lg
                        Layout.bottomMargin: Theme.space.sm

                        Rectangle {
                            anchors.fill: parent
                            radius: Theme.radius.md
                            color: Theme.color.canvas
                            border.color: searchInput.activeFocus ? Theme.color.brand
                                                                  : Theme.color.borderStrong
                            border.width: 1

                            Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }

                            AppIcon {
                                anchors.left: parent.left
                                anchors.leftMargin: Theme.space.md
                                anchors.verticalCenter: parent.verticalCenter
                                name: "search"
                                color: Theme.color.textTertiary
                                size: 14
                            }
                            TextInput {
                                id: searchInput
                                anchors.left: parent.left
                                anchors.leftMargin: 36
                                anchors.right: shortcutHint.left
                                anchors.rightMargin: Theme.space.sm
                                anchors.verticalCenter: parent.verticalCenter
                                color: Theme.color.textPrimary
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.bodySize
                                selectByMouse: true
                                clip: true

                                Text {
                                    visible: !searchInput.activeFocus && searchInput.text.length === 0
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: qsTr("Search in lyrics…")
                                    color: Theme.color.textTertiary
                                    font.family: Theme.font.family
                                    font.pixelSize: Theme.font.bodySize
                                }
                            }

                            Rectangle {
                                id: shortcutHint
                                anchors.right: parent.right
                                anchors.rightMargin: 5
                                anchors.verticalCenter: parent.verticalCenter
                                width: 28; height: 18
                                radius: 3
                                color: Theme.color.elevated
                                border.color: Theme.color.borderStrong
                                border.width: 1
                                visible: !searchInput.activeFocus

                                Text {
                                    anchors.centerIn: parent
                                    text: "⌘A"
                                    color: Theme.color.textTertiary
                                    font.family: Theme.font.monoFamily
                                    font.pixelSize: 9
                                }
                            }
                        }
                    }

                    Repeater {
                        model: [
                            { icon: "folder",  l: qsTr("All Songs"),      active: true  },
                            { icon: "heart",   l: qsTr("My Favorites"),   active: false },
                            { icon: "folders", l: qsTr("My Collections"), active: false }
                        ]

                        delegate: Item {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 32

                            Rectangle {
                                anchors.fill: parent
                                anchors.leftMargin: Theme.space.sm
                                anchors.rightMargin: Theme.space.sm
                                radius: Theme.radius.md
                                color: modelData.active   ? Theme.color.brandSubtle
                                     : navMa.containsMouse ? Theme.color.overlay
                                                            : "transparent"

                                Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
                            }

                            Row {
                                anchors.left: parent.left
                                anchors.leftMargin: Theme.space.lg
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.space.md

                                AppIcon {
                                    anchors.verticalCenter: parent.verticalCenter
                                    name: modelData.icon
                                    color: modelData.active ? Theme.color.brand : Theme.color.textTertiary
                                    size: 13
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: modelData.l
                                    color: modelData.active ? Theme.color.textPrimary : Theme.color.textSecondary
                                    font.family: Theme.font.family
                                    font.pixelSize: Theme.font.bodySize
                                    font.weight: modelData.active ? Theme.font.weightMedium
                                                                  : Theme.font.weightRegular
                                }
                            }

                            MouseArea {
                                id: navMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                            }
                        }
                    }

                    Item { Layout.fillHeight: true }
                }

                Rectangle {
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: 1
                    color: Theme.color.borderSubtle
                }
            }

            // Library content
            Item {
                id: libraryContent

                anchors.top: tabBar.bottom
                anchors.bottom: parent.bottom
                anchors.left: libraryNav.right
                anchors.right: parent.right

                ColumnLayout {
                    anchors.centerIn: parent
                    spacing: Theme.space.sm

                    AppIcon {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.bottomMargin: Theme.space.xs
                        name: "music"
                        color: Theme.color.textTertiary
                        size: 32
                        opacity: 0.7
                    }
                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: qsTr("No songs yet")
                        color: Theme.color.textSecondary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.bodySize + 2
                        font.weight: Theme.font.weightMedium
                    }
                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: qsTr("Import songs from a file or create them manually to get started")
                        color: Theme.color.textTertiary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                        Layout.maximumWidth: 320
                    }

                    Item { Layout.preferredHeight: Theme.space.md; Layout.fillWidth: true }

                    // Add CTA
                    Rectangle {
                        Layout.alignment: Qt.AlignHCenter
                        height: 38
                        width: ctaRow.implicitWidth + Theme.space.xl * 2
                        radius: Theme.radius.md
                        color: ctaMa.containsMouse ? Theme.color.brandHover : Theme.color.brand

                        Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

                        Row {
                            id: ctaRow
                            anchors.centerIn: parent
                            spacing: Theme.space.sm

                            AppIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                name: "plus"
                                color: Theme.color.brandInk
                                size: 14
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: qsTr("Add your first song")
                                color: Theme.color.brandInk
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.bodySize
                                font.weight: Theme.font.weightSemiBold
                            }
                        }

                        MouseArea {
                            id: ctaMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                        }
                    }
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // Footer
    // ─────────────────────────────────────────────────────────────────────
    Rectangle {
        id: footerBar

        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 36
        color: Theme.color.elevated

        Rectangle {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: 1
            color: Theme.color.borderSubtle
        }

        Row {
            anchors.left: parent.left
            anchors.leftMargin: Theme.space.md
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.space.xs

            IconButton {
                anchors.verticalCenter: parent.verticalCenter
                iconName: "plus"
                iconSize: 14
            }

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: settingsRow.implicitWidth + Theme.space.md * 2
                height: 28
                radius: Theme.radius.md
                color: settingsMa.containsMouse ? Theme.color.overlay : "transparent"

                Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

                Row {
                    id: settingsRow
                    anchors.centerIn: parent
                    spacing: Theme.space.xs

                    AppIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "settings"
                        color: Theme.color.textSecondary
                        size: 13
                    }
                    AppIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "chevron-down"
                        color: Theme.color.textTertiary
                        size: 11
                    }
                }

                MouseArea {
                    id: settingsMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                }
            }
        }

        Text {
            anchors.right: parent.right
            anchors.rightMargin: Theme.space.xl
            anchors.verticalCenter: parent.verticalCenter
            text: qsTr("0 songs")
            color: Theme.color.textTertiary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.smallSize
        }
    }
}
