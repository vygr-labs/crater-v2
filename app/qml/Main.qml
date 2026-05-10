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
    // Top bar — brand, service context, output target, ON-AIR indicator
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

        // Left cluster: brand mark + service context
        Row {
            anchors.left: parent.left
            anchors.leftMargin: Theme.space.xl
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.space.xl

            Row {
                spacing: Theme.space.sm

                Rectangle {
                    width: 24; height: 24
                    radius: Theme.radius.md
                    anchors.verticalCenter: parent.verticalCenter
                    gradient: Gradient {
                        orientation: Gradient.Vertical
                        GradientStop { position: 0.0; color: Theme.color.brand }
                        GradientStop { position: 1.0; color: Qt.darker(Theme.color.brand, 1.4) }
                    }
                    Rectangle {
                        anchors.centerIn: parent
                        width: 8; height: 8
                        radius: 1
                        color: Theme.color.brandInk
                        rotation: 45
                    }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Crater"
                    color: Theme.color.textPrimary
                    font.family: Theme.font.family
                    font.pixelSize: 16
                    font.weight: Theme.font.weightSemiBold
                    font.letterSpacing: 0.3
                }
            }

            Rectangle {
                width: 1; height: 22
                anchors.verticalCenter: parent.verticalCenter
                color: Theme.color.borderStrong
            }

            Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2
                Text {
                    text: qsTr("Sunday Morning")
                    color: Theme.color.textPrimary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize
                    font.weight: Theme.font.weightMedium
                }
                Text {
                    text: qsTr("10:00 AM  ·  8 items  ·  ~75 min")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                }
            }
        }

        // Right cluster: timer, output target, settings, ON-AIR
        Row {
            anchors.right: parent.right
            anchors.rightMargin: Theme.space.lg
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.space.md

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("00:42:18")
                color: Theme.color.textSecondary
                font.family: Theme.font.monoFamily
                font.pixelSize: Theme.font.bodySize
            }

            Rectangle {
                width: 1; height: 22
                anchors.verticalCenter: parent.verticalCenter
                color: Theme.color.borderStrong
            }

            // Output target chip
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                height: 30
                width: outRow.implicitWidth + Theme.space.lg * 2
                radius: Theme.radius.md
                color: outMa.containsMouse ? Theme.color.overlay : Theme.color.raised
                border.width: 1
                border.color: Theme.color.borderSubtle

                Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

                Row {
                    id: outRow
                    anchors.centerIn: parent
                    spacing: Theme.space.sm

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 6; height: 6; radius: 3
                        color: Theme.color.success
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Projector 1")
                        color: Theme.color.textPrimary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                        font.weight: Theme.font.weightMedium
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "▾"
                        color: Theme.color.textTertiary
                        font.pixelSize: 9
                    }
                }
                MouseArea {
                    id: outMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                }
            }

            IconButton {
                anchors.verticalCenter: parent.verticalCenter
                symbol: "⚙"
                symbolSize: 15
            }

            // ON-AIR pill — pulses while live
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                height: 32
                width: liveRow.implicitWidth + Theme.space.lg * 2
                radius: Theme.radius.md
                color: Theme.color.live

                Row {
                    id: liveRow
                    anchors.centerIn: parent
                    spacing: Theme.space.sm

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 7; height: 7; radius: 3.5
                        color: "#ffffff"

                        SequentialAnimation on opacity {
                            running: true
                            loops: Animation.Infinite
                            NumberAnimation { from: 1.0; to: 0.35; duration: 700; easing.type: Easing.InOutQuad }
                            NumberAnimation { from: 0.35; to: 1.0; duration: 700; easing.type: Easing.InOutQuad }
                        }
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("ON AIR")
                        color: "#ffffff"
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                        font.weight: Theme.font.weightSemiBold
                        font.letterSpacing: 1.0
                    }
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // Main work surface — three panes
    // ─────────────────────────────────────────────────────────────────────
    Item {
        id: mainArea

        anchors.top: topBar.bottom
        anchors.bottom: statusBar.top
        anchors.left: parent.left
        anchors.right: parent.right

        // ── Library rail (left)
        Rectangle {
            id: leftRail

            width: Theme.size.leftRailWidth
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            color: Theme.color.elevated

            Rectangle {
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: 1
                color: Theme.color.borderSubtle
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.topMargin: Theme.space.lg
                spacing: 0

                PaneHeader {
                    Layout.fillWidth: true
                    label: qsTr("Library")
                }

                // Search field
                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 40
                    Layout.leftMargin: Theme.space.lg
                    Layout.rightMargin: Theme.space.lg
                    Layout.topMargin: Theme.space.xs
                    Layout.bottomMargin: Theme.space.md

                    Rectangle {
                        anchors.fill: parent
                        radius: Theme.radius.md
                        color: Theme.color.canvas
                        border.color: searchInput.activeFocus ? Theme.color.brand : Theme.color.borderStrong
                        border.width: 1

                        Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }

                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.space.md
                            anchors.verticalCenter: parent.verticalCenter
                            text: "⌕"
                            color: Theme.color.textTertiary
                            font.pixelSize: 16
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
                                text: qsTr("Search anywhere…")
                                color: Theme.color.textTertiary
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.bodySize
                            }
                        }

                        // ⌘K hint
                        Rectangle {
                            id: shortcutHint
                            anchors.right: parent.right
                            anchors.rightMargin: 6
                            anchors.verticalCenter: parent.verticalCenter
                            width: 26; height: 18
                            radius: 3
                            color: Theme.color.elevated
                            border.color: Theme.color.borderStrong
                            border.width: 1
                            visible: !searchInput.activeFocus

                            Text {
                                anchors.centerIn: parent
                                text: "⌘K"
                                color: Theme.color.textTertiary
                                font.family: Theme.font.monoFamily
                                font.pixelSize: 9
                            }
                        }
                    }
                }

                LibraryRow { Layout.fillWidth: true; symbol: "✠"; label: qsTr("Bible");  count: 31102; active: true }
                LibraryRow { Layout.fillWidth: true; symbol: "♪"; label: qsTr("Songs");  count: 248 }
                LibraryRow { Layout.fillWidth: true; symbol: "◐"; label: qsTr("Themes"); count: 12 }
                LibraryRow { Layout.fillWidth: true; symbol: "▤"; label: qsTr("Media");  count: 87 }
                LibraryRow { Layout.fillWidth: true; symbol: "✎"; label: qsTr("Notes");  count: 0 }

                Item { Layout.fillWidth: true; Layout.preferredHeight: Theme.space.xl }

                PaneHeader {
                    Layout.fillWidth: true
                    label: qsTr("Quick access")
                }

                LibraryRow { Layout.fillWidth: true; symbol: "↻"; label: qsTr("Last service") }
                LibraryRow { Layout.fillWidth: true; symbol: "★"; label: qsTr("Favorites") }
                LibraryRow { Layout.fillWidth: true; symbol: "↧"; label: qsTr("Recent verses") }

                Item { Layout.fillWidth: true; Layout.fillHeight: true }

                // Footer card — operator identity / quick switch
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 56
                    color: Theme.color.canvas

                    Rectangle {
                        anchors.top: parent.top
                        anchors.left: parent.left
                        anchors.right: parent.right
                        height: 1
                        color: Theme.color.borderSubtle
                    }

                    Row {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.space.lg
                        anchors.rightMargin: Theme.space.sm
                        spacing: Theme.space.md

                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 28; height: 28
                            radius: 14
                            color: Theme.color.brandSubtle

                            Text {
                                anchors.centerIn: parent
                                text: "K"
                                color: Theme.color.brand
                                font.family: Theme.font.family
                                font.pixelSize: 13
                                font.weight: Theme.font.weightSemiBold
                            }
                        }

                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 1
                            Text {
                                text: qsTr("Kingsley")
                                color: Theme.color.textPrimary
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.smallSize + 1
                                font.weight: Theme.font.weightMedium
                            }
                            Text {
                                text: qsTr("Operator")
                                color: Theme.color.textTertiary
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.microSize
                            }
                        }
                    }
                }
            }
        }

        // ── Schedule (center)
        Item {
            id: scheduleArea

            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.left: leftRail.right
            anchors.right: rightPanel.left

            ColumnLayout {
                anchors.fill: parent
                anchors.topMargin: Theme.space.lg
                spacing: 0

                PaneHeader {
                    Layout.fillWidth: true
                    label: qsTr("Schedule  ·  Sunday morning")
                    action: qsTr("+ Add item")
                }

                ListView {
                    id: scheduleList

                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.topMargin: Theme.space.sm
                    clip: true
                    spacing: 0
                    boundsBehavior: Flickable.StopAtBounds

                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                    model: ListModel {
                        ListElement { itype: "Welcome";   title: "Welcome & Announcements"; subtitle: "Pastor James  ·  ~5 min";                live: false; queued: false; tcolor: "#a3a3b0" }
                        ListElement { itype: "Song";      title: "10,000 Reasons (Bless the Lord)"; subtitle: "Matt Redman  ·  Key of G  ·  4 verses"; live: true;  queued: false; tcolor: "#d4a574" }
                        ListElement { itype: "Scripture"; title: "John 3:16 – 21";          subtitle: "ESV  ·  6 verses";                       live: false; queued: true;  tcolor: "#5b9df0" }
                        ListElement { itype: "Song";      title: "Amazing Grace (My Chains Are Gone)"; subtitle: "Chris Tomlin  ·  Key of G  ·  5 verses"; live: false; queued: false; tcolor: "#d4a574" }
                        ListElement { itype: "Sermon";    title: "The Cost of Discipleship"; subtitle: "Pastor Adeyemi  ·  Luke 9:23 – 27  ·  ~30 min"; live: false; queued: false; tcolor: "#c084fc" }
                        ListElement { itype: "Video";     title: "Closing reflection — \"Be still\""; subtitle: "1 minute 24 seconds  ·  1080p";  live: false; queued: false; tcolor: "#4fc285" }
                        ListElement { itype: "Song";      title: "Great Are You Lord";      subtitle: "All Sons & Daughters  ·  Key of A  ·  3 verses"; live: false; queued: false; tcolor: "#d4a574" }
                        ListElement { itype: "Note";      title: "Benediction";             subtitle: "Numbers 6:24 – 26";                      live: false; queued: false; tcolor: "#a3a3b0" }
                    }

                    delegate: ScheduleRow {
                        width: scheduleList.width
                        rowIndex: model.index + 1
                        title: model.title
                        subtitle: model.subtitle
                        typeName: model.itype
                        typeColor: model.tcolor
                        isLive: model.live
                        isQueued: model.queued
                    }
                }

                // Add-item affordance at the bottom
                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 48
                    Layout.leftMargin: Theme.space.lg
                    Layout.rightMargin: Theme.space.lg
                    Layout.bottomMargin: Theme.space.md

                    Rectangle {
                        anchors.fill: parent
                        radius: Theme.radius.lg
                        color: addMa.containsMouse ? Theme.color.elevated : "transparent"
                        border.width: 1
                        border.color: Theme.color.borderSubtle

                        Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

                        Row {
                            anchors.centerIn: parent
                            spacing: Theme.space.sm
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "+"
                                color: Theme.color.textTertiary
                                font.pixelSize: 16
                                font.weight: Theme.font.weightLight
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: qsTr("Add scripture, song, video, or note")
                                color: Theme.color.textTertiary
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.smallSize
                            }
                        }
                        MouseArea {
                            id: addMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                        }
                    }
                }
            }
        }

        // ── Output panel (right)
        Rectangle {
            id: rightPanel

            width: Theme.size.outputPanelWidth
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.right: parent.right
            color: Theme.color.elevated

            Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: 1
                color: Theme.color.borderSubtle
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.topMargin: Theme.space.lg
                anchors.leftMargin: Theme.space.lg
                anchors.rightMargin: Theme.space.lg
                anchors.bottomMargin: Theme.space.lg
                spacing: Theme.space.lg

                // PREVIEW
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Theme.space.sm

                    Row {
                        spacing: Theme.space.sm
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 6; height: 6; radius: 3
                            color: Theme.color.preview
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: qsTr("PREVIEW")
                            color: Theme.color.textTertiary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.microSize
                            font.weight: Theme.font.weightSemiBold
                            font.letterSpacing: 1.2
                        }
                        Item { width: Theme.space.sm; height: 1 }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: qsTr("Queued — John 3:16")
                            color: Theme.color.textSecondary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.smallSize
                        }
                    }

                    Monitor {
                        Layout.fillWidth: true
                        monitorState: "preview"
                        caption: qsTr("For God so loved the world that he gave his only Son…")
                        subCaption: qsTr("John 3:16  ·  English Standard Version")
                    }
                }

                // Send to Live — primary action
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 48
                    radius: Theme.radius.md
                    color: sendMa.pressed       ? Qt.darker(Theme.color.brand, 1.15)
                         : sendMa.containsMouse ? Theme.color.brandHover
                                                : Theme.color.brand

                    Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

                    // Soft brand glow
                    layer.enabled: sendMa.containsMouse
                    layer.effect: ShaderEffect { property real strength: 0 }

                    Row {
                        anchors.centerIn: parent
                        spacing: Theme.space.md

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: qsTr("Send to Live")
                            color: Theme.color.brandInk
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.bodySize + 1
                            font.weight: Theme.font.weightSemiBold
                            font.letterSpacing: 0.4
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "→"
                            color: Theme.color.brandInk
                            font.pixelSize: Theme.font.titleSize
                        }
                        Item { width: Theme.space.md; height: 1 }
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: kbdHint.implicitWidth + 10; height: 18
                            radius: 3
                            color: "#26ffffff"

                            Text {
                                id: kbdHint
                                anchors.centerIn: parent
                                text: qsTr("Space")
                                color: Theme.color.brandInk
                                font.family: Theme.font.monoFamily
                                font.pixelSize: 9
                                font.weight: Theme.font.weightSemiBold
                            }
                        }
                    }

                    MouseArea {
                        id: sendMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                    }
                }

                // LIVE
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Theme.space.sm

                    Row {
                        spacing: Theme.space.sm
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 6; height: 6; radius: 3
                            color: Theme.color.live

                            SequentialAnimation on opacity {
                                running: true
                                loops: Animation.Infinite
                                NumberAnimation { from: 1.0; to: 0.35; duration: 700; easing.type: Easing.InOutQuad }
                                NumberAnimation { from: 0.35; to: 1.0; duration: 700; easing.type: Easing.InOutQuad }
                            }
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: qsTr("LIVE")
                            color: Theme.color.textTertiary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.microSize
                            font.weight: Theme.font.weightSemiBold
                            font.letterSpacing: 1.2
                        }
                        Item { width: Theme.space.sm; height: 1 }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: qsTr("On screen — 10,000 Reasons")
                            color: Theme.color.textSecondary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.smallSize
                        }
                    }

                    Monitor {
                        Layout.fillWidth: true
                        monitorState: "live"
                        caption: qsTr("Bless the Lord, O my soul")
                        subCaption: qsTr("10,000 Reasons  ·  Verse 1")
                    }
                }

                // Quick actions — Black, Logo, Clear
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.space.sm

                    Repeater {
                        model: [
                            { l: qsTr("Black"), c: "#0d0d12", t: qsTr("B") },
                            { l: qsTr("Logo"),  c: Theme.color.brand,     t: qsTr("L") },
                            { l: qsTr("Clear"), c: Theme.color.textSecondary, t: qsTr("C") }
                        ]
                        delegate: Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 36
                            radius: Theme.radius.md
                            color: actionMa.containsMouse ? Theme.color.overlay : Theme.color.raised
                            border.width: 1
                            border.color: Theme.color.borderSubtle

                            Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

                            Row {
                                anchors.centerIn: parent
                                spacing: Theme.space.sm

                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 8; height: 8
                                    radius: 2
                                    color: modelData.c
                                    border.width: modelData.l === qsTr("Black") ? 1 : 0
                                    border.color: Theme.color.borderStrong
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: modelData.l
                                    color: Theme.color.textPrimary
                                    font.family: Theme.font.family
                                    font.pixelSize: Theme.font.smallSize
                                    font.weight: Theme.font.weightMedium
                                }
                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 16; height: 16
                                    radius: 3
                                    color: Theme.color.canvas
                                    border.color: Theme.color.borderSubtle
                                    border.width: 1

                                    Text {
                                        anchors.centerIn: parent
                                        text: modelData.t
                                        color: Theme.color.textTertiary
                                        font.family: Theme.font.monoFamily
                                        font.pixelSize: 9
                                    }
                                }
                            }
                            MouseArea {
                                id: actionMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                            }
                        }
                    }
                }

                Item { Layout.fillHeight: true }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // Status bar
    // ─────────────────────────────────────────────────────────────────────
    Rectangle {
        id: statusBar

        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: Theme.size.statusBarHeight
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
            anchors.leftMargin: Theme.space.xl
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.space.lg

            Repeater {
                model: [
                    { d: Theme.color.success,      l: qsTr("Output: connected") },
                    { d: Theme.color.success,      l: qsTr("NDI: streaming  ·  2 receivers") },
                    { d: Theme.color.textTertiary, l: qsTr("Remote: not active") }
                ]
                delegate: Row {
                    spacing: 6
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 6; height: 6; radius: 3
                        color: modelData.d
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.l
                        color: Theme.color.textTertiary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                    }
                }
            }
        }

        Text {
            anchors.right: parent.right
            anchors.rightMargin: Theme.space.xl
            anchors.verticalCenter: parent.verticalCenter
            text: qsTr("Crater  ·  v0.6.0")
            color: Theme.color.textTertiary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.smallSize
        }
    }
}
