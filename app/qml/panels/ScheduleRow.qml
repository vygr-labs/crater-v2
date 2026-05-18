import QtQuick

// One row in the schedule list. Visual language mirrors electron's
// ScheduleItem: a flat hstack — no card, no rounded corners, no kind pill,
// no index number, no Preview/Live badges. Selection is signaled by a 3px
// left border + faint bg wash; the primary (focused) selected row gets a
// deeper brand-tinted bg; drag-over surfaces as a top border. Live state is
// owned by LivePanel — putting it back on the row would duplicate the
// authoritative indicator and add visual noise in a dense schedule.
//
// Emits clicked(button, modifiers), doubleClicked, rightClicked(x, y), and
// drag lifecycle signals (dragStarted / dragMoved / dragReleased). The host
// panel keeps the drag state and triggers ScheduleService.moveItem on release.
Item {
    id: root

    property int    rowIndex: 0
    property string title: ""
    property string subtitle: ""
    // The canonical kind ("song", "scripture", "image", "video", "presentation").
    // Label + color + icon are derived from this via Theme helpers — no
    // presentation metadata stored on schedule items.
    property string kind: ""

    property bool isLive: false               // unused visually here; LivePanel owns the indicator
    property bool isSelected: false           // a member of the multi-selection set
    property bool isPrimarySelected: false    // the anchor (drives Preview pane)
    property bool hasThemeOverride: false

    // Drag state. The row translates by dragOffsetY while a drag is in
    // progress; ListView delegate positioning isn't touched so the operator
    // sees the row "float" without ListView relayout fighting it.
    property bool isDragging: false
    property real dragOffsetY: 0

    readonly property color _kindColor: Theme.scheduleColor(kind)
    readonly property string _kindIcon: Theme.scheduleKindIcon(kind)

    // Clicks pass through modifiers so the host can route Ctrl+/Shift+ to
    // multi-select helpers without each row knowing about the selection model.
    signal clicked(int mouseButton, int keyboardModifiers)
    signal doubleClicked()
    signal rightClicked(real mouseX, real mouseY)

    // Drag lifecycle. The panel uses these to compute a drop-target index
    // and call ScheduleService.moveItem on release.
    signal dragStarted(int rowIndex)
    signal dragMoved(int rowIndex, real offsetY)
    signal dragReleased(int rowIndex, real offsetY)

    implicitHeight: Theme.size.scheduleRowHeight
    implicitWidth: 400

    // Elevate the whole delegate above siblings while dragging so the
    // floating row paints over neighbours. Setting z on the inner item
    // alone wouldn't work — ListView stacks delegates inside contentItem,
    // and a child's z only reorders within its own delegate subtree.
    z: isDragging ? 100 : 0

    // ── Row body ────────────────────────────────────────────────────────
    // Flat container — translates by dragOffsetY during a drag.
    Item {
        id: body
        anchors.fill: parent
        y: root.dragOffsetY
        opacity: root.isDragging ? 0.92 : 1.0
        Behavior on opacity { NumberAnimation { duration: Theme.motion.instant } }

        // Background wash. Three distinct states:
        //   primary-selected (focused)  → opaque brandSubtle (deep wash)
        //   selected (non-primary)      → brandSubtle at 0.55 (medium wash)
        //   hover                       → rowHoverBrand at 0.30 (light wash)
        //   default                     → transparent
        // Using shade contrast (subtle vs brand) keeps selected and hover
        // visually distinct even though both involve brand colors.
        Rectangle {
            anchors.fill: parent
            color: root.isPrimarySelected ? Theme.color.brandSubtle
                 : root.isSelected        ? Qt.rgba(23/255, 60/255, 19/255, 0.55)
                 : ma.containsMouse       ? Theme.color.rowHoverBrand
                                          : "transparent"
            Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
        }

        // 3px brand-colored left edge for any member of the selection set.
        // Electron uses defaultPalette.400 (a lighter brand) — Qt.lighter on
        // the brand gives us the equivalent without adding a new token.
        Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 3
            visible: root.isSelected
            color: Qt.lighter(Theme.color.brand, 1.6)
        }

        // ── Drag handle column ───────────────────────────────────────────
        // Always-visible grip — used to be a grip↔check swap on selection,
        // but selection is already strongly signaled by the 3px brand left
        // edge, the brandSubtle bg wash, the brighter title weight, and
        // the kind-icon recoloring. A fifth selection cue (the check) was
        // visual noise, and swapping the handle glyph also momentarily
        // hid the drag affordance for selected rows. Width matches
        // electron's px={2} + icon — ~28px total.
        Item {
            id: handle
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 28

            AppIcon {
                anchors.centerIn: parent
                name: "grip-vertical"
                size: Theme.icon.md
                color: handleMa.containsMouse || root.isDragging
                       ? Theme.color.textSecondary : Theme.color.textTertiary
                // Sit at full opacity whenever the row is hovered, being
                // dragged, OR currently selected — so the handle visually
                // ranks alongside the other "active row" cues.
                opacity: handleMa.containsMouse || root.isDragging
                       || ma.containsMouse        || root.isSelected
                         ? 1.0 : 0.6
                Behavior on opacity { NumberAnimation { duration: Theme.motion.instant } }
            }

            MouseArea {
                id: handleMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: root.isDragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                preventStealing: true

                property real pressStartY: 0

                onPressed: function(mouse) {
                    pressStartY = mouse.y
                    root.isDragging = true
                    root.dragStarted(root.rowIndex)
                }
                onPositionChanged: function(mouse) {
                    if (root.isDragging) {
                        root.dragOffsetY = (mouse.y - pressStartY)
                        root.dragMoved(root.rowIndex, root.dragOffsetY)
                    }
                }
                onReleased: {
                    const finalOffset = root.dragOffsetY
                    root.isDragging = false
                    root.dragOffsetY = 0
                    root.dragReleased(root.rowIndex, finalOffset)
                }
                onCanceled: {
                    root.isDragging = false
                    root.dragOffsetY = 0
                }
            }
        }

        // ── Kind icon ────────────────────────────────────────────────────
        // Small kind-tinted glyph (music / book / image / video / …). Brighter
        // when the row is focused/selected so it reads as "active item".
        AppIcon {
            id: kindIcon
            anchors.left: handle.right
            anchors.verticalCenter: parent.verticalCenter
            name: root._kindIcon
            size: Theme.icon.md
            color: root.isPrimarySelected ? Qt.lighter(root._kindColor, 1.25)
                 : root.isSelected        ? root._kindColor
                                          : Qt.darker(root._kindColor, 1.15)
            opacity: root.isPrimarySelected || root.isSelected ? 1.0 : 0.85
        }

        // ── Title ────────────────────────────────────────────────────────
        // Single-line, truncated. No subtitle (electron's schedule rows are
        // a single line; the title field already carries enough info for
        // scriptures ("Genesis 1:4 (KJV)") and songs ("Amazing Grace")).
        Text {
            id: titleText
            anchors.left: kindIcon.right
            anchors.leftMargin: Theme.space.sm
            anchors.right: themeMark.visible ? themeMark.left : parent.right
            anchors.rightMargin: Theme.space.md
            anchors.verticalCenter: parent.verticalCenter
            text: root.title
            color: root.isPrimarySelected ? Theme.color.textPrimary
                 : root.isSelected        ? Theme.color.textPrimary
                                          : Theme.color.textTitle
            font.family: Theme.font.family
            font.pixelSize: Theme.font.bodySize
            font.weight: (root.isPrimarySelected || root.isSelected)
                         ? Theme.font.weightMedium
                         : Theme.font.weightRegular
            elide: Text.ElideRight
        }

        // ── Theme-override glyph ─────────────────────────────────────────
        // Tiny palette mark on the right edge when this item carries a
        // non-default theme. Tinted in the row's kind color so it reads as
        // an annotation on the same item, not a separate semantic class.
        AppIcon {
            id: themeMark
            visible: root.hasThemeOverride
            anchors.right: parent.right
            anchors.rightMargin: Theme.space.md
            anchors.verticalCenter: parent.verticalCenter
            name: "palette"
            size: Theme.icon.sm
            color: Qt.lighter(root._kindColor, 1.1)
            opacity: 0.85
        }

        // ── Drag-over top accent ─────────────────────────────────────────
        // The host SchedulePanel renders the global insertion line in the
        // ListView contentItem; this row-local indicator (currently unused)
        // would slot in here if we ever want per-row drop affordance.

        // ── Click area (everything to the right of the drag handle) ──────
        MouseArea {
            id: ma
            anchors.fill: parent
            anchors.leftMargin: handle.width
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: function(mouse) {
                if (mouse.button === Qt.RightButton) {
                    root.rightClicked(mouse.x, mouse.y)
                } else {
                    root.clicked(mouse.button, mouse.modifiers)
                }
            }
            onDoubleClicked: root.doubleClicked()
        }
    }
}
