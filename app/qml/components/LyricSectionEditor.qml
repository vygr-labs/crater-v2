import QtQuick
import Crater

// Single song section in the structured editor. Mirrors electron's
// LyricEdit.tsx: number gutter on the left with duplicate/delete actions
// (revealed on hover), a flushed label TextInput, and a multi-line
// TextEdit for the lyric body. All mutations bubble up via signals —
// the parent SongEditorDialog owns the actual sections array (so it
// can push undo snapshots before mutating).
//
// We bind directly to `label` and `linesText` rather than to a section
// object so the parent can pass plain strings out of its Repeater
// model. `linesText` is the string-form (lines joined with "\n"); the
// parent splits it back into a QStringList before persisting.
Rectangle {
    id: root

    // ── Inputs ──────────────────────────────────────────────────────────
    property int    index: 0
    property string label: ""
    property string linesText: ""
    property bool   canDelete: true
    // Highlighted when the parent's "current section" pointer points at us.
    // Drives the live-preview update — clicking inside a section makes it
    // the previewed one even though we don't store that fact ourselves.
    property bool   active: false

    // ── Signals ─────────────────────────────────────────────────────────
    signal labelEdited(int idx, string value)
    signal linesEdited(int idx, string value)
    signal focused(int idx)
    signal deleteRequested(int idx)
    signal duplicateRequested(int idx)

    // Forward-edge accessor used by the parent so it can focus the label
    // input of a freshly-added section after the Repeater has built it.
    function focusLabel() { labelInput.forceActiveFocus() }

    // ── Layout ──────────────────────────────────────────────────────────
    implicitHeight: gutter.height
    color: Theme.color.canvas
    // Flat to match the song editor modal's data-app aesthetic — the dialog
    // dropped its rounded chrome and these cards follow suit.
    radius: 0
    border.color: root.active        ? Theme.color.brand
                : hoverArea.containsMouse ? Theme.color.borderStrong
                                          : Theme.color.borderSubtle
    border.width: 1
    clip: true

    Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }

    // Hover proxy — drives `_isHovered` for the action buttons. Sits behind
    // the inputs (z: -1) so it doesn't swallow clicks; hoverEnabled bubbles
    // hover state up while leaving press/click events untouched.
    MouseArea {
        id: hoverArea
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        z: -1
    }

    // Number + action gutter (mirrors electron's left rail)
    Rectangle {
        id: gutter
        anchors.left: parent.left
        anchors.top: parent.top
        width: 36
        height: Math.max(64, fieldsCol.implicitHeight + Theme.space.md * 2)
        color: Theme.color.raised
        radius: parent.radius
        // Right-edge is a vertical divider, not a rounded corner — flatten it.
        Rectangle {
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 1
            color: Theme.color.borderSubtle
        }

        Text {
            anchors.top: parent.top
            anchors.topMargin: Theme.space.sm
            anchors.horizontalCenter: parent.horizontalCenter
            text: (root.index + 1).toString()
            color: Theme.color.textTertiary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.smallSize
            font.weight: Theme.font.weightSemiBold
        }

        Column {
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Theme.space.sm
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 2
            opacity: hoverArea.containsMouse ? 1.0 : 0.0
            Behavior on opacity { NumberAnimation { duration: Theme.motion.instant } }

            IconButton {
                iconName: "copy"
                iconSize: Theme.icon.sm
                onClicked: root.duplicateRequested(root.index)
            }
            IconButton {
                visible: root.canDelete
                iconName: "trash"
                iconSize: Theme.icon.sm
                tint: Theme.color.live          // red affordance for destructive
                tintHover: Qt.lighter(Theme.color.live, 1.12)
                onClicked: root.deleteRequested(root.index)
            }
        }
    }

    // Body — label + lyric textarea, stacked
    Column {
        id: fieldsCol
        anchors.left: gutter.right
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.leftMargin: Theme.space.sm
        anchors.rightMargin: Theme.space.sm
        anchors.topMargin: Theme.space.sm
        spacing: Theme.space.xs

        // Label input — flushed (no fill, just bottom-border hover treatment)
        Rectangle {
            id: labelWrap
            width: parent.width
            height: 28
            radius: 0
            color: labelInput.activeFocus ? Theme.color.raised : "transparent"
            border.color: labelInput.activeFocus ? Theme.color.brand : "transparent"
            border.width: 1

            Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
            Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }

            TextInput {
                id: labelInput
                anchors.fill: parent
                anchors.leftMargin: Theme.space.sm
                anchors.rightMargin: Theme.space.sm
                verticalAlignment: TextInput.AlignVCenter
                color: Theme.color.textPrimary
                font.family: Theme.font.family
                // bodySize matches the song-title input and the rest of the
                // app's primary text controls. smallSize made the section
                // label feel like UI chrome instead of an editable field.
                font.pixelSize: Theme.font.bodySize
                font.weight: Theme.font.weightMedium
                selectByMouse: true
                text: root.label
                onTextEdited: root.labelEdited(root.index, text)
                onActiveFocusChanged: if (activeFocus) root.focused(root.index)

                // Placeholder
                Text {
                    visible: labelInput.text.length === 0 && !labelInput.activeFocus
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Section label (e.g., Verse 1, Chorus)")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize
                }
            }
        }

        // Lyric textarea — multi-line, autoresizes via implicitHeight.
        Rectangle {
            id: linesWrap
            width: parent.width
            // Implicit height tracks the TextEdit's content height — matches
            // electron's `autoresize` Textarea. Floor at ~3 line-heights so a
            // brand-new empty section is comfortable to click into.
            height: Math.max(60, linesEdit.contentHeight + Theme.space.sm * 2)
            radius: 0
            color: linesEdit.activeFocus ? Theme.color.raised : "transparent"
            border.color: linesEdit.activeFocus ? Theme.color.brand : "transparent"
            border.width: 1

            Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
            Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }

            TextEdit {
                id: linesEdit
                anchors.fill: parent
                anchors.margins: Theme.space.sm
                color: Theme.color.textPrimary
                font.family: Theme.font.family
                // bodySize — matches the title input above and the raw-mode
                // textarea, so the operator's typing experience is uniform
                // across the editor.
                font.pixelSize: Theme.font.bodySize
                selectByMouse: true
                wrapMode: TextEdit.Wrap
                text: root.linesText
                onTextChanged: if (text !== root.linesText) root.linesEdited(root.index, text)
                onActiveFocusChanged: if (activeFocus) root.focused(root.index)

                // Placeholder — TextEdit doesn't ship one, so we overlay a Text
                // when empty + unfocused. Same pattern as TextPropertiesContent.
                Text {
                    visible: linesEdit.text.length === 0 && !linesEdit.activeFocus
                    anchors.left: parent.left
                    anchors.top: parent.top
                    text: qsTr("Enter lyrics here…")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize
                }
            }
        }

        // Bottom padding inside the card.
        Item { width: parent.width; height: Theme.space.sm }
    }
}
