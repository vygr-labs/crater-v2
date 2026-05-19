import QtQuick
import Crater

// Floating media picker for the container properties panel's Media slot.
//
// Patterned after ColorPickerPopover — re-parents its chrome to the top-most
// Window root on open() so the popover can paint above clipping panels and
// scroll-clipped property accordions. The picker shows a "None" option at the
// top (clears mediaId on the container) followed by every imported image /
// video in MediaService.allMedia.
//
//   MediaPickerPopover {
//       id: picker
//       targetId: node.data.mediaId || 0
//       onMediaChosen: function(id) { workspace.workingTheme.setNodeData(...) }
//   }
//   ...
//   MouseArea { onClicked: picker.openAt(slot) }
Item {
    id: root
    property int  targetId: 0
    visible: false
    width: 0; height: 0    // zero footprint when closed

    // Emits the new mediaId. 0 means "clear" — callers should map to null
    // when storing onto a node's data field so the schema reads cleanly.
    signal mediaChosen(int id)

    // Drives the entrance animation each time the popover opens. Same
    // pattern Combobox / ColorPickerPopover use — flipped inside openAt()
    // and _close() so the binding re-fires per show/hide cycle.
    property bool _open: false

    Rectangle {
        id: chrome
        visible: false
        z: 1000
        width: 320
        height: 360
        radius: 0
        color: Theme.color.bgMenu
        border.color: Theme.color.borderStrong
        border.width: 1
        clip: true

        transformOrigin: Item.TopLeft
        opacity: root._open ? 1.0 : 0.0
        scale:   root._open ? 1.0 : 0.96
        Behavior on opacity { NumberAnimation { duration: Theme.motion.instant; easing.type: Easing.OutCubic } }
        Behavior on scale   { NumberAnimation { duration: Theme.motion.instant; easing.type: Easing.OutCubic } }

        // Layered drop shadow — mirrors PopoverMenu / ColorPicker /
        // Combobox so all floating surfaces share one shadow language.
        Rectangle {
            anchors.fill: parent
            anchors.margins: -12
            anchors.topMargin: -6
            anchors.bottomMargin: -18
            radius: 0
            color: "#00000018"
            z: -3
        }
        Rectangle {
            anchors.fill: parent
            anchors.margins: -6
            anchors.topMargin: -3
            anchors.bottomMargin: -10
            radius: 0
            color: "#00000028"
            z: -2
        }
        Rectangle {
            anchors.fill: parent
            anchors.margins: -1
            anchors.topMargin: 1
            radius: 0
            color: "#00000048"
            z: -1
        }

        // Header label — matches the section-header typography of the
        // properties panel (smallSize / textPrimary / SemiBold) so the
        // popover feels native to it.
        Text {
            id: header
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: Theme.space.md
            text: qsTr("MEDIA")
            color: Theme.color.textPrimary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.smallSize
            font.weight: Theme.font.weightSemiBold
            font.letterSpacing: 1.2
        }

        ListView {
            id: list
            anchors.top: header.bottom
            anchors.topMargin: Theme.space.sm
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: 6
            anchors.rightMargin: 6
            anchors.bottomMargin: 6
            clip: true
            spacing: 2

            // Sentinel at index 0 is the "None" affordance — modelData with
            // id === 0 means "clear". Concatenating onto the live media list
            // keeps the bindings simple and means a re-imported library
            // updates the popover the next time it opens.
            model: {
                const all = MediaService.allMedia || []
                const none = [{ id: 0, title: qsTr("None"), type: "none", path: "" }]
                return none.concat(all)
            }

            delegate: Rectangle {
                width: list.width
                height: 48
                radius: 0
                readonly property bool _selected: modelData.id === root.targetId
                readonly property bool _isNone:   modelData.id === 0
                color: rowMa.containsMouse ? Theme.color.overlay
                     : _selected           ? Theme.color.brandSubtle
                                           : "transparent"

                Row {
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    spacing: 10

                    // Thumb — image preview for images, film icon for videos,
                    // and a different "x" affordance for the None option.
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 36; height: 36; radius: 0
                        color: Theme.color.canvas
                        border.color: Theme.color.borderSubtle
                        border.width: 1

                        Image {
                            visible: !parent.parent.parent._isNone
                                  && modelData.type === "image"
                            anchors.fill: parent
                            anchors.margins: 1
                            asynchronous: true
                            cache: true
                            source: modelData.path
                                ? "file:///" + modelData.path
                                : ""
                            fillMode: Image.PreserveAspectCrop
                        }
                        AppIcon {
                            anchors.centerIn: parent
                            visible: parent.parent.parent._isNone
                                  || modelData.type === "video"
                            name: parent.parent.parent._isNone ? "x"
                                : modelData.type === "video"   ? "film"
                                                                 : "image"
                            size: Theme.icon.md
                            color: Theme.color.textTertiary
                        }
                    }

                    // Title + type subtitle. None uses a single tertiary-tone
                    // line so the affordance reads as "absence" instead of
                    // looking like another picky-able item.
                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2
                        Text {
                            text: modelData.title
                            color: parent.parent.parent._selected ? Theme.color.textPrimary
                                 : parent.parent.parent._isNone   ? Theme.color.textTertiary
                                                                  : Theme.color.textPrimary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.bodySize
                            font.weight: Theme.font.weightMedium
                            font.italic: parent.parent.parent._isNone
                            elide: Text.ElideRight
                            width: list.width - 62
                        }
                        Text {
                            visible: !parent.parent.parent._isNone
                            text: modelData.type === "video" ? qsTr("Video") : qsTr("Image")
                            color: Theme.color.textTertiary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.smallSize
                        }
                    }
                }

                MouseArea {
                    id: rowMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        root.mediaChosen(modelData.id)
                        root._close()
                    }
                }
            }
        }
    }

    // Click-out catcher. Sits below chrome on z, full window above the
    // chrome's anchor — anchors set in openAt() once we know the window.
    // hoverEnabled prevents hover wash leaking through to the property
    // inputs and panel chrome that sit visually behind us while open.
    MouseArea {
        id: dismissArea
        z: 999
        visible: false
        hoverEnabled: true
        onClicked: root._close()
    }

    function openAt(anchorItem) {
        // Walk to the top-most ancestor (the Window's content item) so the
        // chrome paints above any clipping panel/accordion below.
        let win = anchorItem
        while (win.parent) win = win.parent

        chrome.parent       = win
        dismissArea.parent  = win
        dismissArea.x       = 0
        dismissArea.y       = 0
        dismissArea.width   = win.width
        dismissArea.height  = win.height

        const p = anchorItem.mapToItem(win, 0, anchorItem.height + 4)
        let x = p.x
        let y = p.y
        if (x + chrome.width  > win.width)  x = win.width  - chrome.width  - 8
        if (y + chrome.height > win.height) y = p.y - chrome.height - anchorItem.height - 8
        chrome.x = Math.max(8, x)
        chrome.y = Math.max(8, y)

        dismissArea.visible = true
        chrome.visible = true
        root._open = true
    }

    function _close() {
        chrome.visible = false
        dismissArea.visible = false
        root._open = false
    }
}
