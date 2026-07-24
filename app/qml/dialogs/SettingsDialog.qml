import QtQuick
import QtQuick.Layouts

// Settings dialog — 720×540 with left section nav + right content panel.
// Section content is loaded via per-section QML files in dialogs/settings/.
ModalShell {
    id: root

    dialogWidth: 760
    dialogHeight: 560
    title: qsTr("Settings")

    readonly property var sections: [
        { id: "appearance",    label: qsTr("Appearance"),     iconName: "palette" },
        // Fonts management moved into Projection — see ProjectionSection's
        // FONTS subsection. Output appearance levers all live in one tab.
        { id: "projection",    label: qsTr("Projection"),     iconName: "monitor" },
        { id: "scripture",     label: qsTr("Scripture"),      iconName: "book-open" },
        { id: "song",          label: qsTr("Song"),           iconName: "music" },
        { id: "search",        label: qsTr("Search"),         iconName: "search" },
        { id: "media",         label: qsTr("Media"),          iconName: "image" },
        { id: "overlay",       label: qsTr("Overlay"),        iconName: "clock" },
        { id: "remoteControl", label: qsTr("Remote Control"), iconName: "tv" },
        { id: "ndi",           label: qsTr("NDI"),            iconName: "radio" },
        { id: "diagnostics",   label: qsTr("Diagnostics"),    iconName: "info" }
    ]

    Item {
        anchors.fill: parent

        // ── Left sidebar with section navigation ─────────────────────────
        // Transparent over the card's `elevated` surface so the sidebar
        // and content panel share one continuous background — only the
        // 1px hairline on the right separates them. Was `canvas`, which
        // made the sidebar read as a recessed strip and stuttered against
        // the elevated content area.
        Rectangle {
            id: sidebar
            anchors.top: parent.top
            anchors.bottom: footer.top
            anchors.left: parent.left
            width: 200
            color: "transparent"

            Rectangle {
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: 1
                color: Theme.color.borderSubtle
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.topMargin: Theme.space.md
                anchors.bottomMargin: Theme.space.md
                spacing: 2

                Repeater {
                    model: root.sections
                    delegate: LibraryRow {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 36
                        iconName: modelData.iconName
                        label:    modelData.label
                        active:   AppState.settingsSection === modelData.id
                        // Sharp active band matches the sharpened controls
                        // inside each section pane (segmented controls,
                        // chips, banners all at radius 0).
                        bgRadius: 0
                        onClicked: AppState.settingsSection = modelData.id
                    }
                }

                Item { Layout.fillHeight: true }
            }
        }

        // ── Content panel ───────────────────────────────────────────────
        // topMargin pads the loaded section's content below the modal
        // header divider, uniformly for every section — those opening with
        // a section header and those opening with a banner alike. Note: the
        // section files each also set an `anchors.topMargin` on their
        // ColumnLayout, but that one is a no-op (no `anchors.top` is set for
        // it to apply to), so this is the margin that actually takes effect.
        Item {
            anchors.top: parent.top
            anchors.topMargin: Theme.space.xxl
            anchors.bottom: footer.top
            anchors.left: sidebar.right
            anchors.right: parent.right

            Loader {
                anchors.fill: parent
                sourceComponent: {
                    switch (AppState.settingsSection) {
                        case "appearance":    return appearanceComp
                        // Legacy "fonts" id remapped to projection — older
                        // persisted state lands on the new home without
                        // showing an empty pane.
                        case "fonts":         return projectionComp
                        case "projection":    return projectionComp
                        case "scripture":     return scriptureComp
                        case "song":          return songComp
                        case "search":        return searchComp
                        case "media":         return mediaComp
                        case "overlay":       return overlayComp
                        case "remoteControl": return remoteComp
                        case "ndi":           return ndiComp
                        case "diagnostics":   return diagnosticsComp
                    }
                    return appearanceComp
                }
            }
        }

        // ── Footer ──────────────────────────────────────────────────────
        Rectangle {
            id: footer
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: 56
            color: "transparent"

            Rectangle {
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                height: 1
                color: Theme.color.borderSubtle
            }

            Row {
                anchors.right: parent.right
                anchors.rightMargin: Theme.space.lg
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.space.sm

                GhostButton {
                    text: qsTr("Cancel")
                    onClicked: AppState.closeModal()
                }
                PrimaryButton {
                    variant: "brand"
                    text: qsTr("Done")
                    onClicked: AppState.closeModal()
                }
            }
        }
    }

    Component { id: appearanceComp; AppearanceSection    { } }
    Component { id: projectionComp; ProjectionSection    { } }
    Component { id: scriptureComp;  ScriptureSection     { } }
    Component { id: songComp;       SongSection          { } }
    Component { id: searchComp;     SearchSection        { } }
    Component { id: mediaComp;      MediaSection         { } }
    Component { id: overlayComp;    OverlaySection       { } }
    Component { id: remoteComp;     RemoteControlSection { } }
    Component { id: ndiComp;        NdiSection           { } }
    Component { id: diagnosticsComp; DiagnosticsSection   { } }
}
