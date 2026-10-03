import QtQuick
import QtQuick.Controls.Basic
import Crater

// Keyboard shortcut reference. Opened from the keyboard button in the TopBar
// or with F1 (Main.qml), through the normal modal slot ("shortcuts").
// Read-only: nothing here binds a key, it only lists what the app binds.
//
// `groups` below is the single list the dialog renders. It is written by
// hand from the real bindings (the Shortcut {} blocks in Main.qml, the
// dialogs, ScriptureTab and ThemeEditorWorkspace, plus the Keys handlers in
// TabSearchBar, GlobalSearchOverlay, the lyric editors and the cropper).
// When you add, change or remove a shortcut anywhere in app/qml, update its
// row here in the same change, or this page starts lying.
//
// Row shape:  { keys: [ ...alternatives ], label: "what it does" }
// Each alternative is drawn as key chips, with "or" between alternatives.
// A space inside an alternative means "press these in turn", so "Esc Esc"
// draws two chips side by side for a double tap.
ModalShell {
    id: root

    dialogWidth:  620
    dialogHeight: 640
    title: qsTr("Keyboard shortcuts")

    readonly property var groups: [
        { title: qsTr("General"), rows: [
            { keys: ["F1"],                        label: qsTr("Show this list") },
            { keys: ["Ctrl+K"],                    label: qsTr("Search everything") },
            { keys: ["Ctrl+,"],                    label: qsTr("Open Settings") },
            { keys: ["Ctrl+1–5"],                  label: qsTr("Go to a library tab") },
            { keys: ["Ctrl+Tab", "Ctrl+Shift+Tab"], label: qsTr("Next or previous library tab") },
            { keys: ["Esc"],                       label: qsTr("Deselect the schedule item") }
        ] },
        { title: qsTr("Live output"), rows: [
            { keys: ["Ctrl+L"],                    label: qsTr("Show or hide the logo") },
            { keys: ["Ctrl+C", "Ctrl+."],          label: qsTr("Clear the projected text") },
            { keys: ["Esc"],                       label: qsTr("In the projector window, close it") },
            { keys: ["Esc"],                       label: qsTr("In an extra output window, turn it off") }
        ] },
        { title: qsTr("Preview and Live"), rows: [
            { keys: ["↑", "↓"],                    label: qsTr("Previous or next slide in the focused panel") },
            { keys: ["Enter"],                     label: qsTr("Send the Preview slide live") },
            { keys: ["Ctrl+↑", "Ctrl+↓"],          label: qsTr("Live: pick a slide, release Ctrl to send it") }
        ] },
        { title: qsTr("Schedule"), rows: [
            { keys: ["Ctrl+S"],                    label: qsTr("Save the schedule, naming it the first time") },
            { keys: ["Ctrl+Shift+S"],              label: qsTr("Save the schedule under a new name") },
            { keys: ["Ctrl+T"],                    label: qsTr("Add the highlighted library item") },
            { keys: ["Ctrl+Click"],                label: qsTr("Select several items") },
            { keys: ["Shift+Click"],               label: qsTr("Select a range of items") },
            { keys: ["Del"],                       label: qsTr("Remove the selected items") }
        ] },
        { title: qsTr("Library"), rows: [
            { keys: ["↑", "↓"],                    label: qsTr("Move through the list and show it in Preview") },
            { keys: ["Shift+↑", "Shift+↓"],        label: qsTr("Extend the selection") },
            { keys: ["Enter"],                     label: qsTr("Send the highlighted item live") },
            { keys: ["←", "→"],                    label: qsTr("Move through the media grid") },
            { keys: ["Ctrl+Click", "Shift+Click"], label: qsTr("Scripture and media: select several items") }
        ] },
        { title: qsTr("Scripture"), rows: [
            { keys: ["Ctrl+F"],                    label: qsTr("Switch between reference and text search") },
            { keys: ["Space", "Tab"],              label: qsTr("Controlled input: on to the chapter, then the verse") },
            { keys: ["Backspace"],                 label: qsTr("Controlled input: delete, or back one part") },
            { keys: ["Space"],                     label: qsTr("Crater input: complete the book name") }
        ] },
        { title: qsTr("Search everything (Ctrl+K)"), rows: [
            { keys: ["↑", "↓"],                    label: qsTr("Move through the results") },
            { keys: ["Tab", "Shift+Tab"],          label: qsTr("Pick a verse of the highlighted song") },
            { keys: ["Enter"],                     label: qsTr("Run the default action") },
            { keys: ["Ctrl+Enter"],                label: qsTr("Go live") },
            { keys: ["Shift+Enter"],               label: qsTr("Add to the schedule") },
            { keys: ["Esc"],                       label: qsTr("Close") }
        ] },
        { title: qsTr("Dialogs"), rows: [
            { keys: ["Esc"],                       label: qsTr("Close, asking first if there are unsaved changes") },
            { keys: ["Esc Esc"],                   label: qsTr("Close without saving") },
            { keys: ["Ctrl+Enter Ctrl+Enter"],     label: qsTr("Save and close") },
            { keys: ["Enter"],                     label: qsTr("Confirm a name") }
        ] },
        { title: qsTr("Song editor"), rows: [
            { keys: ["Ctrl+S"],                    label: qsTr("Save the song") },
            { keys: ["Ctrl+Z"],                    label: qsTr("Undo") },
            { keys: ["Ctrl+Y", "Ctrl+Shift+Z"],    label: qsTr("Redo") },
            { keys: ["Ctrl+M", "Ctrl+Tab"],        label: qsTr("Switch between sections and raw text") },
            { keys: ["Ctrl+B", "Ctrl+I", "Ctrl+U"], label: qsTr("Bold, italic, underline") },
            { keys: ["Ctrl+Shift+V"],              label: qsTr("Paste as plain text") }
        ] },
        { title: qsTr("Schedule item editor"), rows: [
            { keys: ["Ctrl+S"],                    label: qsTr("Save to the schedule") },
            { keys: ["Ctrl+M"],                    label: qsTr("Switch between slides and raw text") },
            { keys: ["Ctrl+Shift+V"],              label: qsTr("Paste as plain text") }
        ] },
        { title: qsTr("Edit media crop (click the picture first)"), rows: [
            { keys: ["←", "→", "↑", "↓"],          label: qsTr("Move the crop") },
            { keys: ["Shift+↑"],                   label: qsTr("Move by one pixel (Shift with any arrow)") },
            { keys: ["Ctrl+↑"],                    label: qsTr("Resize (Ctrl with any arrow)") },
            { keys: ["Backspace"],                 label: qsTr("Reset the crop") }
        ] },
        { title: qsTr("Theme editor"), rows: [
            { keys: ["Ctrl+S"],                    label: qsTr("Save the theme") },
            { keys: ["Ctrl+Z"],                    label: qsTr("Undo") },
            { keys: ["Ctrl+Y", "Ctrl+Shift+Z"],    label: qsTr("Redo") },
            { keys: ["Ctrl+D"],                    label: qsTr("Duplicate the selected layer") },
            { keys: ["Del"],                       label: qsTr("Delete the selected layer") },
            { keys: ["←", "→", "↑", "↓"],          label: qsTr("Nudge the selected layer") },
            { keys: ["Shift+↑"],                   label: qsTr("Nudge further (Shift with any arrow)") },
            { keys: ["Ctrl++", "Ctrl+-"],          label: qsTr("Zoom in or out") },
            { keys: ["Ctrl+0"],                    label: qsTr("Reset zoom") },
            { keys: ["Esc"],                       label: qsTr("Deselect, then close the editor") }
        ] }
    ]

    Flickable {
        id: scroller
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: body.implicitHeight + Theme.space.lg * 2
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: AppScrollBar {}

        Column {
            id: body
            x: Theme.space.lg
            y: Theme.space.lg
            width: scroller.width - Theme.space.lg * 2 - Theme.size.scrollBar
            spacing: 0

            Repeater {
                model: root.groups

                delegate: Column {
                    id: group
                    required property var modelData
                    required property int index
                    width: body.width
                    spacing: 0

                    // Group heading, same treatment as SettingsSectionHeader.
                    Text {
                        width: parent.width
                        topPadding: group.index === 0 ? 0 : Theme.space.lg
                        bottomPadding: Theme.space.xs
                        text: group.modelData.title.toUpperCase()
                        color: Theme.color.textTertiary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.microSize
                        font.weight: Theme.font.weightSemiBold
                        font.letterSpacing: 1.0
                    }

                    Repeater {
                        model: group.modelData.rows

                        delegate: Item {
                            id: row
                            required property var modelData
                            width: group.width
                            height: 30

                            Rectangle {
                                anchors.bottom: parent.bottom
                                width: parent.width
                                height: 1
                                color: Theme.color.borderSubtle
                            }

                            Text {
                                anchors.left: parent.left
                                anchors.right: keysRow.left
                                anchors.rightMargin: Theme.space.md
                                anchors.verticalCenter: parent.verticalCenter
                                text: row.modelData.label
                                elide: Text.ElideRight
                                color: Theme.color.textPrimary
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.smallSize
                            }

                            Row {
                                id: keysRow
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.space.xs

                                Repeater {
                                    model: row.modelData.keys

                                    delegate: Row {
                                        id: alt
                                        required property var modelData
                                        required property int index
                                        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
                                        spacing: Theme.space.xs

                                        Text {
                                            visible: alt.index > 0
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: qsTr("or")
                                            color: Theme.color.textTertiary
                                            font.family: Theme.font.family
                                            font.pixelSize: Theme.font.microSize
                                        }

                                        Repeater {
                                            model: String(alt.modelData).split(" ")

                                            // Key chip. Same chrome as MenuRow's
                                            // kbd hint so a shortcut reads the
                                            // same here as in a context menu.
                                            delegate: Rectangle {
                                                id: chip
                                                required property var modelData
                                                anchors.verticalCenter: parent ? parent.verticalCenter : undefined
                                                implicitWidth: Math.max(18, chipText.implicitWidth + 10)
                                                implicitHeight: 18
                                                radius: 0
                                                color: Theme.color.elevated
                                                border.color: Theme.color.borderSubtle
                                                border.width: 1

                                                Text {
                                                    id: chipText
                                                    anchors.centerIn: parent
                                                    text: chip.modelData
                                                    color: Theme.color.textTertiary
                                                    font.family: Theme.font.monoFamily
                                                    font.pixelSize: 11
                                                    font.weight: Theme.font.weightMedium
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
