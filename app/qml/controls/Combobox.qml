import QtQuick
import Crater

// A select-style dropdown with optional filter. Displays the current value
// in a button; on click, opens a popover (reparented to the window root) with
// a search field and scrolling list of options. Closes on selection, Escape,
// or clicking outside the popover.
//
// `options` accepts either:
//   - an array of strings:        ["Inter", "Georgia", ...]
//   - an array of { label, value }: [{ label: "Inter (sans)", value: "Inter" }]
//
// Emits `valueSelected(string)` when the user picks an option.
//
// Hit-testing note:
//   The popover is reparented to the top-most ancestor (the Window content
//   item) on open. Qt Quick's default hit testing only delivers mouse events
//   to descendants whose hit point falls inside their parent's bounding rect.
//   Since the button is 24 px tall but the popover is 280 px, the popover's
//   rows would otherwise be unreachable past the first sliver — events would
//   pass through to whatever sibling control sits at that screen y. Re-
//   parenting to a window-tall ancestor sidesteps that constraint, the same
//   way ColorPickerPopover and MediaPickerPopover do.
Item {
    id: root

    property string value: ""
    property var    options: []
    property string placeholder: ""
    property bool   searchable: true
    property int    maxPopupHeight: 280
    property int    rowHeight: 28

    signal valueSelected(string v)

    implicitHeight: 24

    // Externally readable open state — callers (e.g. the Typography section
    // wrapping a font combobox) read this to lift their own z while we're
    // open. Mutated only via _showPopover() / _close() so reparent logic
    // stays paired with the visible state.
    property bool _open: false

    z: _open ? 1000 : 0

    // ── Button ────────────────────────────────────────────────────────
    Rectangle {
        id: button
        anchors.fill: parent
        radius: Theme.radius.sm
        color: Theme.color.canvas
        border.color: root._open ? Theme.color.brand : Theme.color.borderStrong
        border.width: 1

        Text {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 22
            verticalAlignment: Text.AlignVCenter
            text: root.value || root.placeholder
            color: root.value ? Theme.color.textPrimary : Theme.color.textTertiary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.smallSize
            elide: Text.ElideRight
        }
        AppIcon {
            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            name: root._open ? "chevron-up" : "chevron-down"
            size: Theme.icon.sm
            color: Theme.color.textTertiary
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root._open ? root._close() : root._showPopover()
        }
    }

    // ── Popover ───────────────────────────────────────────────────────
    // Declared as a child of root so its bindings against `root.searchable`
    // / `root.options` / etc. stay live, but reparented to the window root
    // on _showPopover(). When the parent is the window we can render and
    // hit-test the full 280 px height regardless of the button's geometry.
    Rectangle {
        id: popover
        visible: false
        z: 1000
        height: root.maxPopupHeight
        // Track the button's width even after reparenting to the window
        // root — anchors would tie us to a layout we're no longer in. The
        // binding stays live since `root` (and its width) outlive the
        // reparent for as long as the Combobox itself does.
        width: root.width
        color: Theme.color.raised
        border.color: Theme.color.borderStrong
        border.width: 1
        radius: Theme.radius.md
        clip: true

        property string _filter: ""
        property var _filteredOptions: {
            const opts = root.options || []
            if (!root.searchable || !_filter) return opts
            const f = _filter.toLowerCase()
            return opts.filter(function(opt) {
                const t = (typeof opt === "string") ? opt
                        : (opt.label || opt.value || "")
                return t.toLowerCase().indexOf(f) >= 0
            })
        }
        readonly property int _filteredCount: _filteredOptions ? _filteredOptions.length : 0

        // Event-blocking backdrop. A bare Rectangle does not stop mouse or
        // hover events from reaching items behind it. The backdrop catches
        // anything that lands in popover chrome (border, margins, between
        // rows) so the inputs underneath stay quiet. Delegate MouseAreas
        // declared later still receive events for their rows.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            hoverEnabled: true
            onPressed: function(m) { m.accepted = true }
            onWheel:   function(w) { w.accepted = true }
        }

        // ── Search row ────────────────────────────────────────────────
        Rectangle {
            id: searchRow
            visible: root.searchable
            anchors.top: parent.top
            anchors.topMargin: 6
            anchors.left: parent.left
            anchors.leftMargin: 6
            anchors.right: parent.right
            anchors.rightMargin: 6
            height: 24
            radius: Theme.radius.sm
            color: Theme.color.canvas
            border.color: Theme.color.borderSubtle
            border.width: 1

            AppIcon {
                anchors.left: parent.left
                anchors.leftMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                name: "search"
                size: Theme.icon.sm
                color: Theme.color.textTertiary
            }
            TextInput {
                id: searchField
                anchors.fill: parent
                anchors.leftMargin: 24
                anchors.rightMargin: 6
                verticalAlignment: TextInput.AlignVCenter
                color: Theme.color.textPrimary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                selectByMouse: true
                clip: true
                onTextChanged: popover._filter = text
                Keys.onEscapePressed: root._close()
                Keys.onReturnPressed: {
                    if (popover._filteredCount > 0) {
                        const first = popover._filteredOptions[0]
                        const v = (typeof first === "string") ? first
                                : (first.value || first.label || "")
                        root.valueSelected(v)
                        root._close()
                    }
                }
            }
        }

        // ── Scrolling list ────────────────────────────────────────────
        ListView {
            id: listView
            anchors.top: root.searchable ? searchRow.bottom : parent.top
            anchors.topMargin: root.searchable ? 4 : 6
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 6
            anchors.left: parent.left
            anchors.leftMargin: 6
            anchors.right: parent.right
            anchors.rightMargin: 6
            clip: true
            model: popover._filteredOptions
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
                width: listView.width
                height: root.rowHeight
                radius: Theme.radius.sm
                readonly property string _label: (typeof modelData === "string")
                    ? modelData
                    : (modelData.label || modelData.value || "")
                readonly property string _value: (typeof modelData === "string")
                    ? modelData
                    : (modelData.value || modelData.label || "")
                readonly property bool _selected: _value === root.value

                color: rowMa.containsMouse ? Theme.color.overlay
                     : _selected           ? Theme.color.brandSubtle
                                           : "transparent"
                Text {
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    verticalAlignment: Text.AlignVCenter
                    text: parent._label
                    color: parent._selected ? Theme.color.brand : Theme.color.textPrimary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                    elide: Text.ElideRight
                }
                MouseArea {
                    id: rowMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        root.valueSelected(parent._value)
                        root._close()
                    }
                }
            }
        }
    }

    // Full-window click-out catcher. Sits on z just below the popover so
    // clicks inside the popover hit the popover first; everything else
    // dismisses. Reparented to the window root alongside the popover.
    // hoverEnabled is on so hover events don't leak through to controls
    // visually obscured by (but logically below) the open popover —
    // otherwise the SimpleSlider thumbs and NumericInput borders behind us
    // would glow as the cursor crossed them while picking a font.
    MouseArea {
        id: dismissArea
        z: 999
        visible: false
        hoverEnabled: true
        onClicked: root._close()
        onWheel: function(w) { w.accepted = true }
    }

    function _showPopover() {
        // Walk to the top-most ancestor (the Window's content item) so the
        // popover paints — and hit-tests — above any clipping panel.
        let win = root
        while (win.parent) win = win.parent

        popover.parent      = win
        dismissArea.parent  = win
        dismissArea.x       = 0
        dismissArea.y       = 0
        dismissArea.width   = win.width
        dismissArea.height  = win.height

        const p = root.mapToItem(win, 0, root.height + 4)
        let x = p.x
        let y = p.y
        // Flip up if there isn't enough room below the button.
        if (y + popover.height > win.height) {
            y = p.y - root.height - 4 - popover.height
        }
        if (x + popover.width > win.width) x = win.width - popover.width - 8
        popover.x = Math.max(8, x)
        popover.y = Math.max(8, y)

        // Reset filter + focus the search field so typing starts narrowing
        // immediately. Doing this every open keeps the popover stateless
        // between sessions — the previous open's filter doesn't linger.
        searchField.text = ""
        popover._filter = ""

        popover.visible = true
        dismissArea.visible = true
        root._open = true

        searchField.forceActiveFocus()
    }

    function _close() {
        popover.visible = false
        dismissArea.visible = false
        root._open = false
    }

    // Re-parent the popover and dismiss area back into our subtree before
    // we are destroyed. If we left them parented to the window root, they
    // would survive as orphans (the window outlives the Combobox) and pile
    // up across selection changes — every text-node selection that opens
    // the font combobox would leak another popover instance on the window.
    Component.onDestruction: {
        if (popover.parent !== root)     popover.parent = root
        if (dismissArea.parent !== root) dismissArea.parent = root
    }
}
