import QtQuick

// One row in the schedule list. Visual state varies with isLive, isSelected
// (member of the multi-set), isPrimarySelected (anchor / Preview pane source),
// hasThemeOverride, and isDragging.
//
// Emits clicked(button, modifiers), doubleClicked, rightClicked(x, y), and
// drag lifecycle signals (dragStarted/dragMoved/dragReleased). The host panel
// keeps the drag state and triggers ScheduleService.moveItem on release.
Item {
    id: root

    property int    rowIndex: 0
    property string title: ""
    property string subtitle: ""
    // The canonical kind ("song", "scripture", "image", "video", "presentation").
    // Label + color are derived from this via Theme helpers — no presentation
    // metadata stored on schedule items.
    property string kind: ""

    property bool isLive: false
    property bool isSelected: false           // a member of the multi-selection set
    property bool isPrimarySelected: false    // the anchor (drives Preview pane)
    property bool hasThemeOverride: false

    // Drag state. The card visually translates by dragOffsetY while a drag is
    // in progress; ListView delegate positioning isn't touched, so the
    // operator sees the row "float" without ListView relayout fighting it.
    property bool isDragging: false
    property real dragOffsetY: 0

    readonly property string _label: Theme.scheduleLabel(kind)
    readonly property color  _color: Theme.scheduleColor(kind)

    // Clicks pass through modifiers so the host can route Ctrl+/Shift+ to
    // multi-select helpers without each row knowing about selection model.
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

    // Elevate the whole delegate above its siblings while being dragged so the
    // floating card paints over neighbouring rows. Setting z on the inner card
    // alone wouldn't work — ListView stacks delegates within contentItem, and
    // a child's z only reorders within its own delegate's subtree.
    z: isDragging ? 100 : 0

    Rectangle {
        id: card

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Theme.space.lg
        anchors.rightMargin: Theme.space.lg
        height: parent.height - 6
        y: 3 + root.dragOffsetY
        radius: Theme.radius.lg
        color: root.isLive             ? Theme.color.liveSubtle
             : root.isSelected         ? Theme.color.previewSubtle
             : ma.containsMouse        ? Theme.color.raised
                                       : Theme.color.elevated
        border.width: (root.isLive || root.isSelected) ? 1 : 0
        border.color: root.isLive            ? Theme.color.live
                    : root.isPrimarySelected ? Theme.color.preview
                    : root.isSelected        ? Qt.darker(Theme.color.preview, 1.6)
                                             : "transparent"
        opacity: root.isDragging ? 0.92 : 1.0

        Behavior on color   { ColorAnimation  { duration: Theme.motion.instant } }
        Behavior on opacity { NumberAnimation { duration: Theme.motion.instant } }

        // ── Drag handle (far left) ──────────────────────────────────────
        // Captures press-drag-release to drive the reorder. Sits on top of
        // the card's main MouseArea (which excludes this region via
        // anchors.leftMargin: handle.width) so clicks here never start a
        // selection action.
        Item {
            id: handle
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 20

            AppIcon {
                anchors.centerIn: parent
                name: "grip-vertical"
                size: 12
                color: handleMa.containsMouse || root.isDragging
                       ? Theme.color.textPrimary : Theme.color.textTertiary
                opacity: handleMa.containsMouse || root.isDragging || ma.containsMouse
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

        // ── Index column / multi-select indicator ───────────────────────
        // Shows row number when not selected, a check glyph when selected.
        Item {
            id: indexCol
            anchors.left: handle.right
            anchors.verticalCenter: parent.verticalCenter
            width: 24
            height: 18

            Text {
                anchors.centerIn: parent
                visible: !root.isSelected
                text: ("0" + (root.rowIndex + 1)).slice(-2)
                color: Theme.color.textTertiary
                font.family: Theme.font.monoFamily
                font.pixelSize: Theme.font.smallSize
            }
            AppIcon {
                anchors.centerIn: parent
                visible: root.isSelected
                name: "check"
                size: 13
                color: root.isPrimarySelected ? Theme.color.preview
                                              : Qt.darker(Theme.color.preview, 1.3)
            }
        }

        // ── Kind badge ──────────────────────────────────────────────────
        Badge {
            id: typeBadge
            anchors.left: indexCol.right
            anchors.leftMargin: Theme.space.md
            anchors.verticalCenter: parent.verticalCenter
            text: root._label
            background: Qt.darker(root._color, 4.0)
            foreground: root._color
        }

        // ── Per-item theme override indicator ───────────────────────────
        // Palette glyph between the kind badge and the title — visible only
        // when the operator has set a non-default theme on this item. The
        // glyph's color matches the kind tint so it reads as an additional
        // decoration on the same item, not a separate semantic class.
        AppIcon {
            id: themeMark
            visible: root.hasThemeOverride
            anchors.left: typeBadge.right
            anchors.leftMargin: Theme.space.sm
            anchors.verticalCenter: parent.verticalCenter
            name: "palette"
            size: 12
            color: root._color
            opacity: 0.8
        }

        // ── Title + subtitle ────────────────────────────────────────────
        Column {
            anchors.left: themeMark.visible ? themeMark.right : typeBadge.right
            anchors.leftMargin: Theme.space.md
            anchors.right: statusRow.left
            anchors.rightMargin: Theme.space.md
            anchors.verticalCenter: parent.verticalCenter
            spacing: 3

            Text {
                text: root.title
                color: Theme.color.textPrimary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize + 1
                font.weight: Theme.font.weightMedium
                elide: Text.ElideRight
                width: parent.width
            }
            Text {
                visible: root.subtitle.length > 0
                text: root.subtitle
                color: Theme.color.textSecondary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                elide: Text.ElideRight
                width: parent.width
            }
        }

        // ── Status badges (Live / Preview) ──────────────────────────────
        Row {
            id: statusRow
            anchors.right: parent.right
            anchors.rightMargin: Theme.space.lg
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.space.sm

            Badge {
                visible: root.isLive
                text: qsTr("Live")
                background: Theme.color.live
                foreground: "#ffffff"
                pulse: true
            }
            Badge {
                visible: root.isPrimarySelected && !root.isLive
                text: qsTr("Preview")
                background: Theme.color.preview
                foreground: "#ffffff"
            }
        }

        // ── Click area (everything to the right of the drag handle) ─────
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
