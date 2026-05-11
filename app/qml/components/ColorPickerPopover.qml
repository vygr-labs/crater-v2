import QtQuick
import Crater

// Floating popover for the ColorPicker. Re-parents to the top window
// (via parent chain walk) on open so it can render above clipping panels.
Item {
    id: root
    property string targetValue: "#ffffff"
    visible: false

    signal colorChosen(string hex)

    width: 0; height: 0    // zero footprint when closed

    // The picker chrome. Reparented to the window root on openAt() so panel
    // scroll/clip don't truncate it.
    Rectangle {
        id: chrome
        visible: false
        z: 1000
        radius: Theme.radius.lg
        color: Theme.color.elevated
        border.color: Theme.color.borderStrong
        border.width: 1
        width: picker.width + 2
        height: picker.height + 2

        ColorPicker {
            id: picker
            anchors.centerIn: parent
            value: root.targetValue
            onCommit: function(hex) { root.colorChosen(hex) }
        }
    }

    // Click-out catcher
    MouseArea {
        id: dismissArea
        z: 999
        visible: false
        // anchors set when shown
        onClicked: root._close()
    }

    function openAt(anchorItem) {
        // Walk up to the window root.
        let win = anchorItem
        while (win.parent) win = win.parent

        chrome.parent = win
        dismissArea.parent = win
        dismissArea.x = 0; dismissArea.y = 0
        dismissArea.width = win.width; dismissArea.height = win.height

        const p = anchorItem.mapToItem(win, 0, anchorItem.height + 4)
        let x = p.x
        let y = p.y
        // Clamp inside window bounds.
        if (x + chrome.width  > win.width)  x = win.width - chrome.width - 8
        if (y + chrome.height > win.height) y = p.y - chrome.height - anchorItem.height - 8
        chrome.x = Math.max(8, x)
        chrome.y = Math.max(8, y)

        dismissArea.visible = true
        chrome.visible = true
    }

    function _close() {
        chrome.visible = false
        dismissArea.visible = false
    }
}
