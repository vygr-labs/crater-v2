import QtQuick

// The 5-tab strip at the top of the library area. Tab activation routes
// through AppState.setActiveTab so the shortcut-bound and click-bound
// paths share the same code.
Item {
    id: root

    height: 42

    // Panel surface for the tab strip — sits on the same `bg.muted`
    // equivalent as electron's Tabs.List so it reads as a raised band over
    // the slightly darker bgContent area underneath it.
    Rectangle {
        anchors.fill: parent
        color: Theme.color.elevated
        z: -1
    }

    readonly property var tabs: [
        { label: qsTr("Songs"),     iconName: "music"     },
        { label: qsTr("Scripture"), iconName: "book-open" },
        { label: qsTr("Strong's"),  iconName: "",           customGlyph: "S" },
        { label: qsTr("Media"),     iconName: "film"      },
        { label: qsTr("Themes"),    iconName: "palette"   }
    ]

    Row {
        anchors.left: parent.left
        anchors.leftMargin: Theme.space.md
        anchors.verticalCenter: parent.verticalCenter
        spacing: 2

        Repeater {
            model: root.tabs

            delegate: Item {
                id: tabItem
                width: tabRow.implicitWidth + Theme.space.lg * 2
                height: root.height

                readonly property bool isActive: AppState.activeTab === index

                Row {
                    id: tabRow
                    anchors.centerIn: parent
                    spacing: Theme.space.sm

                    AppIcon {
                        visible: modelData.iconName && modelData.iconName.length > 0
                        anchors.verticalCenter: parent.verticalCenter
                        name: modelData.iconName || ""
                        color: tabItem.isActive    ? Theme.color.brand
                             : tabMa.containsMouse ? Theme.color.textPrimary
                                                   : Theme.color.textTertiary
                        size: 13

                        Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
                    }
                    Text {
                        visible: !modelData.iconName || modelData.iconName.length === 0
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.customGlyph || ""
                        color: tabItem.isActive    ? Theme.color.brand
                             : tabMa.containsMouse ? Theme.color.textPrimary
                                                   : Theme.color.textTertiary
                        font.family: Theme.font.family
                        font.pixelSize: 14
                        font.weight: Theme.font.weightSemiBold
                        font.italic: true

                        Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.label
                        color: tabItem.isActive    ? Theme.color.textPrimary
                             : tabMa.containsMouse ? Theme.color.textSecondary
                                                   : Theme.color.textTertiary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.bodySize
                        font.weight: tabItem.isActive ? Theme.font.weightSemiBold
                                                      : Theme.font.weightRegular

                        Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
                    }
                }

                // Active underline
                Rectangle {
                    visible: tabItem.isActive
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
                    onClicked: AppState.setActiveTab(index)
                }
            }
        }
    }

    // Bottom hairline (separates tab strip from content below)
    Rectangle {
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 1
        color: Theme.color.borderSubtle
    }
}
