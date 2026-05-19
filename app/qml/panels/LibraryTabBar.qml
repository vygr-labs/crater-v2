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

    // Canonical 5-tab list. Strong's is filtered out when the operator's
    // "Show Strong's tab" setting is off; the visible `tabs` array shrinks
    // to 4 entries. Indices in `tabs` line up 1:1 with AppState.tabKeys
    // so click-to-setActiveTab(index) routes correctly without remapping.
    readonly property var allTabs: [
        { key: "songs",     label: qsTr("Songs"),     iconName: "music"     },
        { key: "scripture", label: qsTr("Scripture"), iconName: "book-open" },
        { key: "strongs",   label: qsTr("Strong's"),  iconName: "",           customGlyph: "S" },
        { key: "media",     label: qsTr("Media"),     iconName: "film"      },
        { key: "themes",    label: qsTr("Themes"),    iconName: "palette"   }
    ]
    readonly property var tabs: SettingsService.showStrongsTab
        ? allTabs
        : allTabs.filter(function(t) { return t.key !== "strongs" })

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

                // Hover wash — gives the tab a visible click-target on
                // pointer-over. Active tab stays unfilled (the underline +
                // brand-tinted icon + textPrimary label already mark it),
                // so hovering an inactive tab is the only state that
                // actually changes background.
                Rectangle {
                    anchors.fill: parent
                    color: !tabItem.isActive && tabMa.containsMouse
                            ? Theme.color.overlay
                            : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
                }

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
                                                   : Theme.color.textSecondary
                        size: Theme.icon.sm

                        Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
                    }
                    // Strong's custom glyph — stands in for a Lucide icon.
                    // Sized through Theme.icon.md (matches the visual weight
                    // of the lucide icons in adjacent tabs and scales with
                    // SettingsService.fontScale alongside them).
                    Text {
                        visible: !modelData.iconName || modelData.iconName.length === 0
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.customGlyph || ""
                        color: tabItem.isActive    ? Theme.color.brand
                             : tabMa.containsMouse ? Theme.color.textPrimary
                                                   : Theme.color.textSecondary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.icon.md
                        font.weight: Theme.font.weightSemiBold
                        font.italic: true

                        Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.label
                        color: tabItem.isActive    ? Theme.color.textPrimary
                             : tabMa.containsMouse ? Theme.color.textPrimary
                                                   : Theme.color.textSecondary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.bodySize
                        // Inactive tabs read as firmer body — Medium not
                        // Regular — so the strip feels like five legible
                        // siblings rather than four ghosted ones plus one.
                        font.weight: tabItem.isActive ? Theme.font.weightSemiBold
                                                      : Theme.font.weightMedium

                        Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
                    }
                }

                // Active underline — full tab width (no horizontal inset)
                // and squared to match the rest of the brand language.
                // Sits on top of the strip's bottom hairline so it reads as
                // the hairline taking on the brand tint under the active
                // tab rather than a floating bar above it.
                Rectangle {
                    visible: tabItem.isActive
                    anchors.bottom: parent.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: 2
                    radius: 0
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
