import QtQuick

// One row of a PopoverMenu. Extracted so both the main body's Repeater and
// the submenu body's Repeater can use it without duplicating the visuals.
//
// `rowData` carries the item dict; `rowIndex` is the index inside its
// Repeater; `host` points at the parent PopoverMenu so click handlers can
// call back into its submenu-state helpers and `itemActivated` signal.
// `isSubmenu` tells the row whether it lives in the submenu body (changes
// hover behavior — see onEntered).
Item {
    id: row

    property var  rowData:   ({})
    property int  rowIndex:  -1
    property var  host:      null
    property bool isSubmenu: false

    readonly property bool _separator:  rowData && rowData.separator === true
    readonly property bool _hasSubmenu: !!(rowData && rowData.submenu)
                                       && rowData.submenu.length > 0
    readonly property bool _enabled:    rowData && rowData.enabled !== false
                                       && !_separator

    height: _separator ? (1 + Theme.space.xs * 2) : 32

    // Separator
    Rectangle {
        visible: row._separator
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        height: 1
        color: Theme.color.borderSubtle
    }

    // Normal item
    Rectangle {
        visible: !row._separator
        anchors.fill: parent
        radius: Theme.radius.sm
        color: (itemMa.containsMouse && row._enabled) || _isOpenSubmenuOwner()
               ? Theme.color.overlay
               : "transparent"
        opacity: row._enabled ? 1.0 : 0.5

        function _isOpenSubmenuOwner() {
            return !row.isSubmenu
                && row._hasSubmenu
                && row.host && row.host._submenuRow === row.rowIndex
        }

        Row {
            anchors.left: parent.left
            anchors.leftMargin: Theme.space.md
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.space.md

            AppIcon {
                visible: !!rowData.iconName
                anchors.verticalCenter: parent.verticalCenter
                name: rowData.iconName || ""
                color: rowData.destructive ? Theme.color.live : Theme.color.textSecondary
                size: Theme.icon.sm
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: rowData.label || ""
                color: rowData.destructive ? Theme.color.live : Theme.color.textPrimary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize
            }
        }

        // Right-rail slot: chevron > kbd > detail. Order matters because
        // submenu items shouldn't also display a kbd hint or detail string —
        // they'd race with the chevron for the same anchor point.
        AppIcon {
            visible: row._hasSubmenu
            anchors.right: parent.right
            anchors.rightMargin: Theme.space.md
            anchors.verticalCenter: parent.verticalCenter
            name: "chevron-right"
            size: Theme.icon.sm
            color: Theme.color.textTertiary
        }

        Rectangle {
            visible: !row._hasSubmenu && !!rowData.kbd
            anchors.right: parent.right
            anchors.rightMargin: Theme.space.md
            anchors.verticalCenter: parent.verticalCenter
            implicitWidth: kbdText.implicitWidth + 12
            implicitHeight: 16
            radius: 3
            color: Theme.color.elevated
            border.color: Theme.color.borderStrong
            border.width: 1

            Text {
                id: kbdText
                anchors.centerIn: parent
                text: rowData.kbd || ""
                color: Theme.color.textTertiary
                font.family: Theme.font.monoFamily
                font.pixelSize: 12
            }
        }

        Text {
            visible: !row._hasSubmenu && !rowData.kbd && !!rowData.detail
            anchors.right: parent.right
            anchors.rightMargin: Theme.space.md
            anchors.verticalCenter: parent.verticalCenter
            text: rowData.detail || ""
            color: Theme.color.textTertiary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.smallSize
        }

        MouseArea {
            id: itemMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: row._enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            enabled: row._enabled

            onEntered: {
                if (!row.host) return
                if (row.isSubmenu) {
                    // Cursor inside the submenu — cancel any pending parent-
                    // row submenu changes (we're now over a child row of
                    // the already-open submenu).
                    row.host._cancelSubmenuTimer()
                } else if (row._hasSubmenu) {
                    row.host._scheduleSubmenu(row.rowIndex)
                } else {
                    row.host._scheduleSubmenu(-1)
                }
            }

            onClicked: {
                if (!row._enabled || !row.host) return
                if (!row.isSubmenu && row._hasSubmenu) {
                    // Skip the hover delay when the user clicks the row.
                    row.host._openSubmenuImmediately(row.rowIndex)
                    return
                }
                // Cache the host BEFORE running the action — if the action
                // opens a new modal, the contextMenu Loader (which owns this
                // PopoverMenu) deactivates and destroys the host before our
                // close() can run. Closing first sets active=false, which
                // the ModalLayer's onActiveChanged honors only when nothing
                // else has claimed activeModal yet.
                const h = row.host
                h.itemActivated(row.rowIndex, row.rowData)
                h.close()
                if (typeof row.rowData.action === "function") row.rowData.action()
            }
        }
    }
}
