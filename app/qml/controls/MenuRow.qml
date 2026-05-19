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

    // Intrinsic width for dynamic menu sizing — the parent Column's
    // implicitWidth picks up max(child.implicitWidth) automatically, and
    // PopoverMenu's body width binding reads that to size the menu to its
    // content. Separators contribute 0 so they don't drive the calculation;
    // they stretch to whatever width the body ends up at. The right-side
    // element is one of submenu chevron / kbd chip / detail text, so we
    // only count one of them in the formula.
    implicitWidth: {
        if (_separator) return 0
        const iconWidth = rowData.iconName ? Theme.icon.sm + Theme.space.md : 0
        let rightWidth = 0
        if (_hasSubmenu) {
            rightWidth = Theme.icon.sm
        } else if (rowData.kbd) {
            rightWidth = Math.max(18, kbdText.implicitWidth + 10)
        } else if (rowData.detail) {
            rightWidth = detailText.implicitWidth
        }
        const gap = rightWidth > 0 ? Theme.space.lg : Theme.space.md
        return Theme.space.md
             + iconWidth
             + labelText.implicitWidth
             + gap
             + rightWidth
             + Theme.space.md
    }

    // Separator — inset horizontally by xs so it doesn't run into the
    // rounded body corners, and uses a slightly lifted shade so it stays
    // visible against the new bgMenu surface.
    Rectangle {
        visible: row._separator
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Theme.space.xs
        anchors.rightMargin: Theme.space.xs
        anchors.verticalCenter: parent.verticalCenter
        height: 1
        color: Theme.color.borderSubtle
    }

    // Normal item. Destructive rows get a red-tinted hover wash so the
    // affordance reinforces the destructive read; non-destructive rows
    // keep the neutral `overlay` wash.
    Rectangle {
        visible: !row._separator
        anchors.fill: parent
        radius: 0
        color: {
            const hovered = (itemMa.containsMouse && row._enabled) || _isOpenSubmenuOwner()
            if (!hovered) return "transparent"
            return rowData.destructive ? Theme.color.liveSubtle : Theme.color.overlay
        }
        opacity: row._enabled ? 1.0 : 0.5

        Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

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
                id: labelText
                anchors.verticalCenter: parent.verticalCenter
                text: rowData.label || ""
                color: rowData.destructive ? Theme.color.live : Theme.color.textPrimary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize
                font.weight: Theme.font.weightMedium
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

        // Keyboard shortcut hint chip. Hairline border on a slightly raised
        // fill — quieter than the body's outer border so it reads as a
        // glyph-sized accent, not a button. Width auto-fits the label
        // (e.g. "E" gets a compact square, "Del" gets a wider pill).
        Rectangle {
            visible: !row._hasSubmenu && !!rowData.kbd
            anchors.right: parent.right
            anchors.rightMargin: Theme.space.md
            anchors.verticalCenter: parent.verticalCenter
            implicitWidth: Math.max(18, kbdText.implicitWidth + 10)
            implicitHeight: 18
            radius: 0
            color: Theme.color.elevated
            border.color: Theme.color.borderSubtle
            border.width: 1

            Text {
                id: kbdText
                anchors.centerIn: parent
                text: rowData.kbd || ""
                color: Theme.color.textTertiary
                font.family: Theme.font.monoFamily
                font.pixelSize: 11
                font.weight: Theme.font.weightMedium
            }
        }

        Text {
            id: detailText
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
