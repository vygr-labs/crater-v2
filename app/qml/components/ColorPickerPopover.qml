import QtQuick
import Crater

// Floating popover for the ColorPicker. Re-parents to the top window
// (via parent chain walk) on open so it can render above clipping panels.
Item {
    id: root
    property string targetValue: "#ffffff"
    visible: false

    signal colorChosen(string hex)   // live, fired on every drag tick
    signal committed(string hex)     // once, on close, with the final color

    // One-undo-step bookkeeping: the live colorChosen ticks drive the node
    // during a drag without touching history; `committed` fires a single time
    // when the picker closes. `_dirty` gates out opens that changed nothing.
    property bool   _dirty: false
    property string _last:  ""

    width: 0; height: 0    // zero footprint when closed

    // Tracks `chrome.visible` so the entrance animation re-fires on each
    // open (the chrome Rectangle lives for the popover's lifetime; only its
    // visibility toggles). Same shape as Combobox's `root._open`.
    property bool _open: false

    // The picker chrome. Reparented to the window root on openAt() so panel
    // scroll/clip don't truncate it. Chrome surface matches PopoverMenu /
    // ScheduleDropdown / Combobox — `bgMenu` token, squared corners.
    Rectangle {
        id: chrome
        visible: false
        z: 1000
        radius: 0
        color: Theme.color.bgMenu
        border.color: Theme.color.borderStrong
        border.width: 1
        width: picker.width + 2
        height: picker.height + 2

        transformOrigin: Item.TopLeft
        opacity: root._open ? 1.0 : 0.0
        scale:   root._open ? 1.0 : 0.96
        Behavior on opacity { NumberAnimation { duration: Theme.motion.instant; easing.type: Easing.OutCubic } }
        Behavior on scale   { NumberAnimation { duration: Theme.motion.instant; easing.type: Easing.OutCubic } }

        // Layered drop shadow — mirrors PopoverMenu so floating surfaces
        // share one shadow language without pulling in QtQuick.Effects.
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

        ColorPicker {
            id: picker
            anchors.centerIn: parent
            value: root.targetValue
            onCommit: function(hex) {
                root._dirty = true
                root._last  = hex
                root.colorChosen(hex)
            }
        }
    }

    // Click-out catcher. hoverEnabled prevents hover wash leaking through
    // to the property inputs and panel chrome visually behind us while open.
    MouseArea {
        id: dismissArea
        z: 999
        visible: false
        hoverEnabled: true
        // anchors set when shown
        onClicked: root._close()
    }

    function openAt(anchorItem) {
        root._dirty = false
        root._last  = ""
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
        root._open = true
    }

    function _close() {
        chrome.visible = false
        dismissArea.visible = false
        root._open = false
        // Snapshot a single undo step for the whole open session — but only if
        // the color actually changed, so opening then dismissing adds nothing.
        if (root._dirty) {
            root._dirty = false
            root.committed(root._last)
        }
    }
}
