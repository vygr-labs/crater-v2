import QtQuick

// Window-level popup menu. Two open modes:
//   - openAt(x, y):           absolute position (right-click context menus)
//   - openBelow(item, dy):    anchored under an Item (TopBar dropdowns, gear menus)
//
// The popover renders as a backdrop + body inside whatever parent it's placed
// in — typically the root ApplicationWindow's content item or ModalLayer. The
// backdrop catches outside clicks to close.
//
// Item shape:
//   { label, iconName?, destructive?, separator?, action?,
//     detail?, kbd?, enabled?, submenu? }
//
//   - action is an optional JS function called on selection.
//   - detail / kbd / submenu compete for the same right-rail slot in this
//     order: submenu > kbd > detail.
//   - submenu is an array of items in the same shape — the row gets a
//     chevron and the submenu opens to the right on hover or click. Only
//     one level of nesting is supported (submenu items must not themselves
//     carry a non-empty submenu — their chevron would render but not open).
//   - enabled defaults to true; disabled rows render dimmed and ignore clicks.
Item {
    id: root

    property var   model: []
    property real  menuWidth: 240
    property bool  active: false
    property real  anchorX: 0
    property real  anchorY: 0

    signal itemActivated(int index, var itemData)

    function openAt(x, y) {
        anchorX = x
        anchorY = y
        active = true
    }

    function openBelow(item, dy) {
        if (!item) return
        const p = item.mapToItem(root, 0, item.height + (dy || 4))
        openAt(p.x, p.y)
    }

    function close() {
        _closeSubmenu()
        active = false
    }

    visible: active
    z: 500
    anchors.fill: parent

    // ── Submenu state (one level of nesting) ────────────────────────────
    // _submenuRow is the index of the row whose submenu is showing, or -1.
    // Hover-open uses a small timer so cursor traversal across non-submenu
    // rows doesn't flash a submenu in and out.
    property int  _submenuRow:    -1
    property int  _pendingRow:    -1
    property real _submenuX:       0
    property real _submenuY:       0
    property var  _submenuItems:   []

    Timer {
        id: submenuTimer
        interval: 180
        onTriggered: root._openSubmenuNow()
    }

    function _scheduleSubmenu(rowIdx) {
        if (rowIdx === _submenuRow) {
            submenuTimer.stop()
            _pendingRow = -1
            return
        }
        if (rowIdx < 0 || !root.model[rowIdx] || !root.model[rowIdx].submenu
                       || root.model[rowIdx].submenu.length === 0) {
            _closeSubmenu()
            return
        }
        _pendingRow = rowIdx
        submenuTimer.restart()
    }

    function _openSubmenuImmediately(rowIdx) {
        _pendingRow = rowIdx
        _openSubmenuNow()
    }

    function _openSubmenuNow() {
        const r = _pendingRow
        if (r < 0 || !root.model[r] || !root.model[r].submenu) return
        const rowItem = repeater.itemAt(r)
        if (!rowItem) return
        const top = rowItem.mapToItem(root, 0, 0)
        _submenuItems = root.model[r].submenu
        _submenuX = body.x + body.width - 4
        _submenuY = top.y - Theme.space.sm
        _submenuRow = r
        _pendingRow = -1
    }

    function _cancelSubmenuTimer() { submenuTimer.stop() }

    function _closeSubmenu() {
        submenuTimer.stop()
        _submenuRow = -1
        _pendingRow = -1
    }

    // Backdrop — catches clicks anywhere outside both menu bodies.
    MouseArea {
        anchors.fill: parent
        onPressed: function(mouse) {
            root.close()
            mouse.accepted = true
        }
    }

    // ── Main body ────────────────────────────────────────────────────────
    Rectangle {
        id: body
        x: Math.max(8, Math.min(root.anchorX, root.width - width - 8))
        y: Math.max(8, Math.min(root.anchorY, root.height - height - 8))
        width: root.menuWidth
        height: contents.implicitHeight + Theme.space.sm * 2
        color: Theme.color.raised
        border.color: Theme.color.borderStrong
        border.width: 1
        radius: Theme.radius.md

        Rectangle {
            anchors.fill: parent
            anchors.margins: -1
            anchors.topMargin: 1
            radius: parent.radius + 1
            color: "#00000040"
            z: -1
        }

        // Block backdrop click-through but stay hoverable so row crossings
        // fire reliably. The position handler also auto-closes the submenu
        // when the cursor wanders to a non-owner row of the body.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.NoButton
            hoverEnabled: true
            onPositionChanged: if (root._submenuRow >= 0)
                                   root._maybeCloseSubmenuFromBody(mouseY)
        }

        Column {
            id: contents
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Theme.space.sm
            spacing: 2

            Repeater {
                id: repeater
                model: root.model
                delegate: MenuRow {
                    width: contents.width
                    rowData:   modelData
                    rowIndex:  index
                    host:      root
                    isSubmenu: false
                }
            }
        }
    }

    // ── Submenu body ─────────────────────────────────────────────────────
    Rectangle {
        id: submenuBody
        visible: root._submenuRow >= 0 && root.active
        x: Math.max(8, Math.min(root._submenuX, root.width - width - 8))
        y: Math.max(8, Math.min(root._submenuY, root.height - height - 8))
        width: 220
        height: submenuContents.implicitHeight + Theme.space.sm * 2
        color: Theme.color.raised
        border.color: Theme.color.borderStrong
        border.width: 1
        radius: Theme.radius.md
        z: 1

        Rectangle {
            anchors.fill: parent
            anchors.margins: -1
            anchors.topMargin: 1
            radius: parent.radius + 1
            color: "#00000040"
            z: -1
        }

        // Hovering anywhere inside the submenu keeps it open. Without this
        // the body MouseArea above would auto-close as soon as the cursor
        // left the owner row.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.NoButton
            hoverEnabled: true
            onEntered: root._cancelSubmenuTimer()
        }

        Column {
            id: submenuContents
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Theme.space.sm
            spacing: 2

            Repeater {
                model: root._submenuItems
                delegate: MenuRow {
                    width: submenuContents.width
                    rowData:   modelData
                    rowIndex:  index
                    host:      root
                    isSubmenu: true
                }
            }
        }
    }

    // Close the submenu if the cursor moved onto a body row that isn't the
    // open submenu's owner — without this, the submenu would stick around
    // even after the cursor moved off to a different parent row.
    function _maybeCloseSubmenuFromBody(mouseY) {
        const rowItem = repeater.itemAt(_submenuRow)
        if (!rowItem) return
        const top = rowItem.mapToItem(body, 0, 0)
        const inside = mouseY >= top.y && mouseY < top.y + rowItem.height
        if (!inside) _scheduleSubmenu(-1)
    }
}
