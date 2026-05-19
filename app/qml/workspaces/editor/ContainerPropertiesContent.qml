import QtQuick
import Crater

// Container-specific properties: background fill, media (with picker popover
// and per-media opacity), and corner radius.
//
// Design notes:
//   • Media-opacity lives in the Media section (not Background) because it
//     only affects the media layer rendered by MediaBackgroundLoader. Putting
//     it under "Fill" was confusing — operators dragged it expecting the
//     solid color to fade and saw nothing happen on a media-less container.
//   • Corner radius is a single uniform value. NodeRenderer averages the four
//     stored fields anyway (Qt 6 Rectangle only supports a uniform radius), so
//     exposing four inputs that all collapse to their average lied about the
//     output. We still write to all four schema fields — keeps the door open
//     for a future per-corner painter without a token migration.
Column {
    id: root
    property var workspace
    property var node

    spacing: 4

    function _setStyle(f, v) { workspace.workingTheme.setNodeStyle(node.id, f, v); workspace.saveToHistory() }
    function _setData (f, v) { workspace.workingTheme.setNodeData (node.id, f, v); workspace.saveToHistory() }

    // Resolve the current media so visibility / preview bindings can read off
    // a single source. `_media` is null when no media is picked OR when the
    // referenced id was removed from the library; both cases collapse the
    // media-only inputs to keep the panel quiet.
    readonly property var _media: (node && node.data && node.data.mediaId)
        ? MediaService.byId(node.data.mediaId) : null

    // ── Background ────────────────────────────────────────────────────
    AccordionSection {
        anchors.left: parent.left
        anchors.right: parent.right
        title: qsTr("Background")
        Column {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: Theme.space.md
            anchors.topMargin: Theme.space.sm
            spacing: 6

            ColorSwatchInput {
                anchors.left: parent.left
                anchors.right: parent.right
                height: 32
                label: qsTr("Fill")
                value: (node && node.style && node.style.backgroundColor) || "#000000"
                onColorPicked: function(c) { root._setStyle("backgroundColor", c) }
            }
        }
    }

    // ── Media ─────────────────────────────────────────────────────────
    AccordionSection {
        id: mediaSection
        anchors.left: parent.left
        anchors.right: parent.right
        title: qsTr("Media")
        // Lift this section above subsequent siblings while the picker is
        // open — same trick the Typography accordion uses around its font
        // combobox so the popover's chrome paints above sections declared
        // after it. The popover already reparents to the window root for
        // truly-out-of-bounds clipping, but z lift keeps the picker's anchor
        // rectangle's hover/click handling on top of any overlap.
        z: mediaPicker.visible ? 100 : 0
        Column {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: Theme.space.md
            anchors.topMargin: Theme.space.sm
            spacing: 6

            Rectangle {
                id: mediaSlot
                anchors.left: parent.left
                anchors.right: parent.right
                height: 48
                radius: 0
                color: Theme.color.canvas
                border.color: slotMa.containsMouse ? Theme.color.brand : Theme.color.borderStrong
                border.width: 1

                Row {
                    anchors.fill: parent
                    anchors.margins: 6
                    spacing: 8

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 36; height: 36; radius: 0
                        color: Theme.color.elevated
                        Image {
                            visible: root._media && root._media.type === "image"
                            anchors.fill: parent
                            anchors.margins: 1
                            asynchronous: true
                            cache: true
                            source: root._media ? "file:///" + root._media.path : ""
                            fillMode: Image.PreserveAspectCrop
                        }
                        AppIcon {
                            visible: !root._media || root._media.type !== "image"
                            anchors.centerIn: parent
                            name: root._media ? "film" : "image"
                            color: Theme.color.textTertiary
                            size: Theme.icon.md
                        }
                    }

                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2
                        Text {
                            text: root._media ? root._media.title : qsTr("No media")
                            color: root._media ? Theme.color.textPrimary : Theme.color.textTertiary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.smallSize
                            font.italic: !root._media
                            elide: Text.ElideRight
                            width: mediaSlot.width - 64
                        }
                        Text {
                            visible: !!root._media
                            text: root._media && root._media.type === "video" ? qsTr("Video") : qsTr("Image")
                            color: Theme.color.textTertiary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.microSize
                        }
                    }
                }

                AppIcon {
                    anchors.right: parent.right
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    name: "chevron-down"
                    size: Theme.icon.sm
                    color: Theme.color.textTertiary
                }

                MouseArea {
                    id: slotMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: mediaPicker.openAt(mediaSlot)
                }
            }

            // Per-media opacity. Only meaningful when there's media to fade;
            // hidden otherwise so the panel doesn't suggest a slider that
            // visibly does nothing.
            SimpleSlider {
                anchors.left: parent.left
                anchors.right: parent.right
                visible: !!root._media
                label: qsTr("Opacity")
                value: (node && node.data && node.data.bgOpacity !== undefined)
                    ? node.data.bgOpacity : 1.0
                min: 0; max: 1; step: 0.05
                onCommit: function(v) { root._setData("bgOpacity", v) }
            }
        }
    }

    // ── Corner radius ─────────────────────────────────────────────────
    // Single uniform value — sets all four corner fields to the same number.
    // Read value = average of the four fields (handles legacy asymmetric
    // tokens by surfacing what NodeRenderer would actually paint).
    AccordionSection {
        anchors.left: parent.left
        anchors.right: parent.right
        title: qsTr("Corner Radius")
        Column {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: Theme.space.md
            anchors.topMargin: Theme.space.sm
            spacing: 6

            NumericInput {
                anchors.left: parent.left
                anchors.right: parent.right
                workspace: root.workspace
                label: qsTr("Radius"); suffix: "px"; min: 0; max: 200; step: 1
                value: {
                    if (!node || !node.style) return 0
                    const s = node.style
                    return ((s.borderTopLeftRadius     || 0)
                          + (s.borderTopRightRadius    || 0)
                          + (s.borderBottomLeftRadius  || 0)
                          + (s.borderBottomRightRadius || 0)) / 4
                }
                onCommit: function(v) {
                    const r = Math.round(v)
                    const wt = workspace.workingTheme
                    // Write all four corner fields so legacy per-corner values
                    // converge to a clean uniform set, then snapshot once —
                    // a single radius edit should produce a single undo step,
                    // not four (one per corner). Each setNodeStyle is a no-op
                    // when the value didn't change, so this is cheap.
                    wt.setNodeStyle(node.id, "borderTopLeftRadius",     r)
                    wt.setNodeStyle(node.id, "borderTopRightRadius",    r)
                    wt.setNodeStyle(node.id, "borderBottomLeftRadius",  r)
                    wt.setNodeStyle(node.id, "borderBottomRightRadius", r)
                    workspace.saveToHistory()
                }
            }
        }
    }

    // Floating picker — reparents to the window root on openAt() so the
    // list isn't clipped by the properties panel's Flickable or by the
    // section's bounds.
    MediaPickerPopover {
        id: mediaPicker
        targetId: (node && node.data && node.data.mediaId) || 0
        onMediaChosen: function(id) {
            // Store null (not 0) for "no media" so the saved token reads
            // cleanly; NodeRenderer reads mediaId || 0 either way.
            root._setData("mediaId", id === 0 ? null : id)
        }
    }
}
