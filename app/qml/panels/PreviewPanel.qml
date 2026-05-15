import QtQuick
import QtQuick.Layouts

// Middle top pane — what the operator is *staging*. Shows pages of the
// currently-selected schedule item. A page-row list at the top, a mini
// monitor at the bottom.
Rectangle {
    id: root

    // Panel surface — matches electron's `bg.muted` panel container.
    color: Theme.color.elevated

    // What's currently in the Preview pane. Two sources:
    //   1. AppState.libraryPreviewItem ─ set when the operator clicks a row in
    //      Songs/Scripture/Media tab. Takes priority because library navigation
    //      is the most-recent intent.
    //   2. ScheduleService.currentItems[selectedScheduleIndex] ─ the existing
    //      schedule-driven selection.
    // Clicking a schedule row clears libraryPreviewItem (see AppState.selectScheduleItem),
    // so the two never disagree silently.
    readonly property var selectedItem:
        AppState.libraryPreviewItem !== null
            ? AppState.libraryPreviewItem
            : (AppState.selectedScheduleIndex >= 0
               && AppState.selectedScheduleIndex < ScheduleService.currentItems.length
                   ? ScheduleService.currentItems[AppState.selectedScheduleIndex]
                   : null)

    // Canonical-shape items carry `pages` (array of {label, content}).
    readonly property var pages: selectedItem && selectedItem.pages ? selectedItem.pages : []

    // ── Header ──────────────────────────────────────────────────────────
    Item {
        id: header
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
                size: Theme.icon.md
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("Preview")
                color: Theme.color.textPrimary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize
                font.weight: Theme.font.weightMedium
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.pages.length > 0
                text: "· " + (AppState.previewSubIndex + 1) + " / " + root.pages.length
                color: Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
            }
        }

        IconButton {
            id: settingsBtn
            anchors.right: parent.right
            anchors.rightMargin: Theme.space.md
            anchors.verticalCenter: parent.verticalCenter
            iconName: "settings"
            iconSize: Theme.icon.sm
            onClicked: {
                AppState.openContextMenuAt(settingsBtn,
                    settingsBtn.width, settingsBtn.height + 4, [
                    { label: qsTr("Sort by index"),   iconName: "sliders" },
                    { label: qsTr("Refresh"),         iconName: "refresh-cw" },
                    { separator: true },
                    { label: qsTr("Preview settings…"), iconName: "settings",
                      action: function() { AppState.openModal("settings", {}) } }
                ], { dx: -220 })
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

    // ── Body: empty state OR page list ──────────────────────────────────
    Item {
        anchors.top: header.bottom
        anchors.bottom: monitorWrap.top
        anchors.bottomMargin: Theme.space.md
        anchors.left: parent.left
        anchors.right: parent.right

        EmptyState {
            anchors.fill: parent
            visible: !root.selectedItem
            iconName: "eye"
            title: qsTr("No item selected")
            body: qsTr("Select an item from the schedule to preview")
        }

        ListView {
            id: pagesList
            anchors.fill: parent
            anchors.leftMargin: Theme.space.lg
            anchors.rightMargin: Theme.space.lg
            anchors.topMargin: Theme.space.sm
            visible: root.selectedItem !== null
            model: root.pages
            clip: true
            cacheBuffer: 200
            spacing: Theme.space.xs

            delegate: Rectangle {
                width: pagesList.width
                height: pageText.implicitHeight + Theme.space.lg * 2
                radius: Theme.radius.md
                color: AppState.previewSubIndex === index ? Theme.color.previewSubtle
                                                          : pageMa.containsMouse ? Theme.color.raised
                                                                                 : "transparent"
                border.color: AppState.previewSubIndex === index ? Theme.color.preview
                                                                 : "transparent"
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
                    onClicked: AppState.previewSubIndex = index
                    onDoubleClicked: {
                        AppState.previewSubIndex = index
                        AppState.goLive()
                    }
                }
            }
        }
    }

    // ── Mini monitor ────────────────────────────────────────────────────
    // Renders one of three things, in priority order:
    //   1. Image / looping video (muted) when the selected item is a
    //      media kind. MediaMonitor's internal Loader gates the decoder,
    //      so when the operator picks a non-media item the player is
    //      destroyed entirely — no pinned GPU memory.
    //   2. Page text for everything else (songs, scripture, etc.).
    //   3. Empty-state copy when nothing is selected.
    readonly property bool _isMediaPreview:
        root.selectedItem !== null
        && (root.selectedItem.kind === "image" || root.selectedItem.kind === "video")
        && (root.selectedItem.mediaPath || "").length > 0

    Item {
        id: monitorWrap
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
            // clip so the video / image respects the rounded corners.
            // Border itself is drawn at the geometry edge so clip doesn't
            // affect it.
            clip: true

            Rectangle {
                anchors.fill: parent
                anchors.margins: 1
                radius: parent.radius - 1
                gradient: Gradient {
                    GradientStop { position: 0.0; color: "#0d0d12" }
                    GradientStop { position: 1.0; color: "#050508" }
                }
            }

            MediaMonitor {
                anchors.fill: parent
                anchors.margins: 1
                mediaKind: root._isMediaPreview ? root.selectedItem.kind : ""
                mediaPath: root._isMediaPreview ? root.selectedItem.mediaPath : ""
                muted: true        // operator monitors silently; live carries audio
                crop:  false       // letterbox in the mini-monitor — full frame visible
            }

            Text {
                anchors.centerIn: parent
                anchors.margins: Theme.space.md
                width: parent.width * 0.85
                visible: !root._isMediaPreview
                text: {
                    if (!root.selectedItem) return qsTr("No preview")
                    if (root.pages.length === 0) return qsTr("No pages")
                    const page = root.pages[AppState.previewSubIndex]
                    return (page && page.content) ? page.content : qsTr("No content")
                }
                color: root.selectedItem ? Theme.color.textPrimary : Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: 15
                font.weight: Theme.font.weightLight
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                maximumLineCount: 3
                elide: Text.ElideRight
            }
        }
    }

    // Right divider
    Rectangle {
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 1
        color: Theme.color.borderSubtle
    }
}
