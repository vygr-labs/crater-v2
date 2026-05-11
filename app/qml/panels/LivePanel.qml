import QtQuick
import QtQuick.Layouts

// Right top pane — what's currently on the projector. Shows the live
// item's pages with the live page highlighted in red.
Rectangle {
    id: root

    color: "transparent"

    readonly property var liveItem:
        AppState.liveScheduleIndex >= 0 && AppState.liveScheduleIndex < AppState.scheduleItems.count
            ? AppState.scheduleItems.get(AppState.liveScheduleIndex)
            : null

    readonly property var pages: liveItem && liveItem.data ? liveItem.data : []
    readonly property bool isLive: liveItem !== null && !AppState.isClear

    // ── Header ──────────────────────────────────────────────────────────
    Item {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 40

        // LIVE pill — visible only when something's live.
        Rectangle {
            visible: root.isLive
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

                    SequentialAnimation on opacity {
                        running: root.isLive
                        loops: Animation.Infinite
                        NumberAnimation { from: 1.0; to: 0.4; duration: 800; easing.type: Easing.InOutQuad }
                        NumberAnimation { from: 0.4; to: 1.0; duration: 800; easing.type: Easing.InOutQuad }
                    }
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

        // Idle label when nothing is live (keeps header height consistent).
        Row {
            visible: !root.isLive
            anchors.left: parent.left
            anchors.leftMargin: Theme.space.lg
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.space.sm

            AppIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "radio"
                color: Theme.color.textTertiary
                size: 14
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("Live")
                color: Theme.color.textSecondary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize
                font.weight: Theme.font.weightMedium
            }
        }

        IconButton {
            id: settingsBtn
            anchors.right: parent.right
            anchors.rightMargin: Theme.space.md
            anchors.verticalCenter: parent.verticalCenter
            iconName: "settings"
            iconSize: 13
            onClicked: {
                const p = settingsBtn.mapToItem(null, settingsBtn.width, settingsBtn.height + 4)
                AppState.openModal("contextMenu", {
                    anchorX: p.x - 220,
                    anchorY: p.y,
                    items: [
                        { label: qsTr("Clear output"),     iconName: "x",
                          action: function() { AppState.clearLive() } },
                        { label: qsTr("Toggle logo"),      iconName: "list-ordered",
                          action: function() { AppState.toggleLogo() } },
                        { separator: true },
                        { label: qsTr("Output settings…"), iconName: "monitor",
                          action: function() { AppState.openModal("settings", {}) } }
                    ]
                })
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

    // ── Body ────────────────────────────────────────────────────────────
    Item {
        anchors.top: header.bottom
        anchors.bottom: monitorWrap.top
        anchors.bottomMargin: Theme.space.md
        anchors.left: parent.left
        anchors.right: parent.right

        EmptyState {
            anchors.fill: parent
            visible: !root.isLive
            iconName: "radio"
            title: AppState.isClear ? qsTr("Display cleared") : qsTr("Nothing live")
            body: AppState.isClear ? qsTr("Output is currently blank")
                                   : qsTr("Double-click a preview item to go live")
        }

        ListView {
            id: pagesList
            anchors.fill: parent
            anchors.leftMargin: Theme.space.lg
            anchors.rightMargin: Theme.space.lg
            anchors.topMargin: Theme.space.sm
            visible: root.isLive
            model: root.pages
            clip: true
            cacheBuffer: 200
            spacing: Theme.space.xs

            delegate: Rectangle {
                width: pagesList.width
                height: pageText.implicitHeight + Theme.space.lg * 2
                radius: Theme.radius.md
                color: AppState.liveSubIndex === index ? Theme.color.liveSubtle
                                                       : pageMa.containsMouse ? Theme.color.elevated
                                                                              : "transparent"
                border.color: AppState.liveSubIndex === index ? Theme.color.live : "transparent"
                border.width: 1

                Behavior on color        { ColorAnimation { duration: Theme.motion.instant } }
                Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }

                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.space.md
                    anchors.verticalCenter: parent.verticalCenter
                    text: (index + 1).toString()
                    color: Theme.color.textTertiary
                    font.family: Theme.font.monoFamily
                    font.pixelSize: Theme.font.smallSize
                    width: 18
                }

                Text {
                    id: pageText
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.space.xl + 6
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.space.lg
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.content || ""
                    color: Theme.color.textPrimary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize
                    wrapMode: Text.WordWrap
                    lineHeight: 1.4
                }

                MouseArea {
                    id: pageMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: AppState.liveSubIndex = index
                }
            }
        }
    }

    // ── Mini monitor ────────────────────────────────────────────────────
    Item {
        id: monitorWrap
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Theme.space.lg
        anchors.horizontalCenter: parent.horizontalCenter
        width: 320
        height: 180

        Rectangle {
            anchors.fill: parent
            radius: Theme.radius.md
            color: "#000000"
            border.color: root.isLive ? Theme.color.live : Theme.color.borderStrong
            border.width: 1.5

            Behavior on border.color { ColorAnimation { duration: Theme.motion.normal } }

            Rectangle {
                anchors.fill: parent
                anchors.margins: 1.5
                radius: parent.radius - 1
                gradient: Gradient {
                    GradientStop { position: 0.0; color: "#0d0d12" }
                    GradientStop { position: 1.0; color: "#050508" }
                }
            }

            // Show the live page content, or "logo" overlay if showLogo is on.
            Text {
                anchors.centerIn: parent
                anchors.margins: Theme.space.md
                width: parent.width * 0.85
                visible: !AppState.showLogo
                text: {
                    if (AppState.isClear) return ""
                    if (!root.liveItem) return ""
                    if (root.pages.length === 0) return ""
                    const page = root.pages[AppState.liveSubIndex]
                    return (page && page.content) ? page.content : ""
                }
                color: Theme.color.textPrimary
                font.family: Theme.font.family
                font.pixelSize: 14
                font.weight: Theme.font.weightLight
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                maximumLineCount: 3
                elide: Text.ElideRight
            }

            // Logo placeholder when toggled on
            Column {
                anchors.centerIn: parent
                visible: AppState.showLogo
                spacing: Theme.space.xs

                AppIcon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    name: "list-ordered"
                    color: Theme.color.brand
                    size: 28
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: qsTr("LOGO")
                    color: Theme.color.brand
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                    font.weight: Theme.font.weightSemiBold
                    font.letterSpacing: 2.0
                }
            }
        }
    }
}
