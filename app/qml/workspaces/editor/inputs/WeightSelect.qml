import QtQuick
import Crater

// Dropdown counterpart to NumericInput for properties whose value space is
// a small fixed set. Used for `fontWeight` in the text properties panel —
// CSS/OpenType weight is one of nine 100..900 buckets, not a continuum, so
// a free-form number field invites typos (450, 750) that no installed font
// can actually render. The dropdown locks the user to legal values and
// labels each one ("Regular", "Bold") so the picker reads like a font menu
// instead of a numeric stepper.
//
// Brand-style popover: matches Combobox.qml — Theme.color.bgMenu surface,
// borderStrong frame, three-layer drop shadow, entrance fade+scale, and
// brandSubtle/brand selection wash. The popover reparents to the window
// root on open so it paints above any clipping panel (the theme editor's
// PropertiesPanel scrolls + clips its children; without reparenting the
// popup would be cropped and rows would be unhittable past the first row).
//
// Per-row label flourish: each option renders its name in its OWN weight
// ("Thin" in 100, "Black" in 900). That's a visual cue that lets the
// operator preview the weight before committing — same idea as rendering
// imported font family names in their own face in the Fonts section.
//
// Signal shape mirrors NumericInput so PropertiesPanel callers can swap
// between them without changing their _liveStyle / _commitStyle wiring:
//   live   ─ fires on every selection change (open + click)
//   commit ─ fires once after the popup closes with the final pick
Item {
    id: root

    property string label: ""
    property real   value: 400
    // Each entry: { value: int, label: string }. Ordered light → heavy so
    // the popup reads top-to-bottom the same way a font weight axis does.
    property var    options: [
        { value: 100, label: qsTr("Thin") },
        { value: 200, label: qsTr("Extra Light") },
        { value: 300, label: qsTr("Light") },
        { value: 400, label: qsTr("Regular") },
        { value: 500, label: qsTr("Medium") },
        { value: 600, label: qsTr("Semi Bold") },
        { value: 700, label: qsTr("Bold") },
        { value: 800, label: qsTr("Extra Bold") },
        { value: 900, label: qsTr("Black") },
    ]

    signal live(real newValue)
    signal commit(real newValue)

    implicitWidth: parent ? parent.width : 120
    implicitHeight: 36

    // Open state — also bumps z so the closed button sits above sibling
    // controls while the popover is being positioned (avoids a 1-frame
    // visual cross-fade with neighbouring NumericInputs glowing on hover).
    property bool _open: false
    z: _open ? 1000 : 0

    // Snap externally-supplied values to the nearest legal bucket so a
    // theme JSON with `fontWeight: 450` still resolves to a selectable
    // option (rounds to 500) rather than rendering as "—".
    readonly property int _snapped: {
        const v = Math.round((value || 400) / 100) * 100
        return Math.max(100, Math.min(900, v))
    }
    function _labelFor(v) {
        for (let i = 0; i < options.length; ++i) {
            if (options[i].value === v) return options[i].label
        }
        return v.toString()
    }

    // ── Inline label (left of the value box) ────────────────────────────
    Text {
        id: lbl
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: root.label
        color: Theme.color.textSecondary
        font.family: Theme.font.family
        font.pixelSize: Theme.font.bodySize
        font.weight: Theme.font.weightMedium
        width: Math.max(36, implicitWidth + 6)
        visible: root.label.length > 0
    }

    // ── Closed-state button ─────────────────────────────────────────────
    Rectangle {
        id: box
        anchors.left: lbl.visible ? lbl.right : parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        height: 32
        radius: 0
        color: Theme.color.canvas
        border.color: ma.containsMouse || root._open ? Theme.color.brand : Theme.color.borderStrong
        border.width: 1

        Text {
            id: valueText
            anchors.left: parent.left
            anchors.leftMargin: 8
            anchors.right: chevron.left
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            text: root._labelFor(root._snapped)
            color: Theme.color.textPrimary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.bodySize
            // Mirror the row treatment in the closed state so the current
            // value renders in its own weight — same hint as the popover.
            font.weight: root._snapped
        }

        AppIcon {
            id: chevron
            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            // chevron-up while open mirrors Combobox's directional cue.
            name: root._open ? "chevron-up" : "chevron-down"
            color: Theme.color.textSecondary
            size: Theme.icon.md
        }

        MouseArea {
            id: ma
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root._open ? _close() : _showPopover()
        }
    }

    // ── Popover ─────────────────────────────────────────────────────────
    // Declared inside root so its bindings against `root.options` stay
    // live, then reparented to the window root on open so the menu paints
    // above clipping panels. Mirrors Combobox.qml's structure 1:1 — same
    // surface tokens, same shadow stack, same entrance animation, same
    // dismiss-area pattern.
    Rectangle {
        id: popover
        visible: false
        z: 1000
        // Generous minimum width so a narrow PropertiesPanel doesn't
        // squish the row labels into the numeric weight on the right
        // (the bug the previous Popup had). 180 fits "Extra Light  200"
        // comfortably with breathing room.
        width: Math.max(box.width, 180)
        height: contentColumn.implicitHeight + 12
        color: Theme.color.bgMenu
        border.color: Theme.color.borderStrong
        border.width: 1
        radius: 0
        clip: true

        // Entrance animation — bound to _open so each open/close cycle
        // re-animates (popover lives for the WeightSelect's lifetime;
        // only `visible` toggles).
        transformOrigin: Item.TopLeft
        opacity: root._open ? 1.0 : 0.0
        scale:   root._open ? 1.0 : 0.96
        Behavior on opacity { NumberAnimation { duration: Theme.motion.instant; easing.type: Easing.OutCubic } }
        Behavior on scale   { NumberAnimation { duration: Theme.motion.instant; easing.type: Easing.OutCubic } }

        // Layered drop shadow — three offset rectangles at decreasing
        // alpha. Same recipe used by Combobox / PopoverMenu so floating
        // surfaces share one shadow language across the app.
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

        // Event-blocking backdrop — see Combobox.qml for the rationale.
        // A bare Rectangle doesn't stop mouse/hover events from leaking
        // through to controls behind it; this MouseArea catches anything
        // landing in chrome (margins, between rows) so inputs underneath
        // stay quiet. Delegate MouseAreas declared later still take their
        // own row events.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            hoverEnabled: true
            onPressed: function(m) { m.accepted = true }
            onWheel:   function(w) { w.accepted = true }
        }

        Column {
            id: contentColumn
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.topMargin: 6
            anchors.leftMargin: 6
            anchors.rightMargin: 6
            spacing: 0

            Repeater {
                model: root.options
                delegate: Rectangle {
                    required property var modelData
                    width: contentColumn.width
                    height: 30
                    radius: 0

                    readonly property bool _isCurrent:
                        modelData.value === root._snapped

                    color: rowMa.containsMouse ? Theme.color.overlay
                         : _isCurrent          ? Theme.color.brandSubtle
                                                : "transparent"
                    border.color: _isCurrent ? Theme.color.brand : "transparent"
                    border.width: 1

                    // Numeric weight on the right. Anchored first so the
                    // label can stop at its left edge — anchoring the
                    // label after numericText guarantees no overlap
                    // regardless of font / DPI.
                    Text {
                        id: numericText
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.value
                        color: parent._isCurrent ? Theme.color.brand
                                                  : Theme.color.textTertiary
                        font.family: Theme.font.monoFamily
                        font.pixelSize: Theme.font.smallSize
                    }

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        anchors.right: numericText.left
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.label
                        color: parent._isCurrent ? Theme.color.brand
                                                  : Theme.color.textPrimary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.bodySize
                        font.weight: modelData.value
                        elide: Text.ElideRight
                    }

                    MouseArea {
                        id: rowMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            const v = modelData.value
                            root.live(v)
                            root.commit(v)
                            root._close()
                        }
                    }
                }
            }
        }
    }

    // Full-window click-out catcher. Sits just below the popover on z so
    // clicks inside the popover hit the popover first; everything else
    // dismisses. Reparented to the window root alongside the popover.
    MouseArea {
        id: dismissArea
        z: 999
        visible: false
        hoverEnabled: true
        onClicked: root._close()
        onWheel: function(w) { w.accepted = true }
    }

    // ── Popover lifecycle ───────────────────────────────────────────────

    function _showPopover() {
        // Walk to the top-most ancestor (the Window's content item) so
        // the popover paints and hit-tests above any clipping panel —
        // PropertiesPanel scrolls + clips, so an in-place popover would
        // be cropped at the panel boundary. Same trick Combobox uses.
        let win = root
        while (win.parent) win = win.parent

        popover.parent     = win
        dismissArea.parent = win
        dismissArea.x      = 0
        dismissArea.y      = 0
        dismissArea.width  = win.width
        dismissArea.height = win.height

        const p = box.mapToItem(win, 0, box.height + 2)
        let x = p.x
        let y = p.y
        // Flip up if there isn't enough room below the button.
        if (y + popover.height > win.height) {
            y = p.y - box.height - 4 - popover.height
        }
        if (x + popover.width > win.width) x = win.width - popover.width - 8
        popover.x = Math.max(8, x)
        popover.y = Math.max(8, y)

        popover.visible = true
        dismissArea.visible = true
        root._open = true
    }

    function _close() {
        popover.visible = false
        dismissArea.visible = false
        root._open = false
    }

    // Reparent the popover + dismiss area back into our subtree before
    // destruction. If we left them parented to the window root, they'd
    // survive as orphans (the window outlives this Item) and pile up
    // across text-node selection changes that re-instantiate the
    // properties panel.
    Component.onDestruction: {
        if (popover.parent !== root)     popover.parent = root
        if (dismissArea.parent !== root) dismissArea.parent = root
    }
}
