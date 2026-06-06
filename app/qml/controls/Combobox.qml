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
    property int    maxPopupHeight: 320
    property int    rowHeight: 34

    // When true, the selected-value button and every dropdown row render in
    // the font family they name (using each option's *value*, so an imported
    // font labelled "Inter (imported)" still previews in Inter). Lets the
    // font-family picker show each typeface inline, no selection required.
    // Off by default so non-font comboboxes (weight, etc.) are unaffected.
    property bool   previewFontFamily: false

    signal valueSelected(string v)

    // 32px tracks Theme.size.controlHeight — the canonical height for
    // dialog-grade controls (toggle switches, segmented buttons, etc.).
    // Was 24 (tuned for the dense theme-editor inputs), which read as
    // too small inside the more spacious settings dialog rows.
    implicitHeight: Theme.size.controlHeight

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
        // Squared corners — matches the rest of the dialog chrome and keeps
        // the dropdown looking like a flat input rather than a pill.
        radius: 0
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
            font.family: (root.previewFontFamily && root.value) ? root.value : Theme.font.family
            font.pixelSize: Theme.font.bodySize
            elide: Text.ElideRight
        }
        AppIcon {
            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            name: root._open ? "chevron-up" : "chevron-down"
            size: Theme.icon.md
            color: Theme.color.textSecondary
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
        // Snug-to-content height: search row (if present) + filtered rows +
        // small bottom gutter, capped at maxPopupHeight for long lists.
        // Without this the popover renders a fixed 280 px box even for a
        // 3-item list, wasting screen real estate and forcing the eye to
        // travel past empty rows. We reserve one row's worth of height when
        // _filteredCount is 0 so the "no matches" state doesn't collapse
        // the box into the search row.
        height: {
            const search = root.searchable ? (30 + 6 + 4) : 6
            const rows   = Math.max(1, _filteredCount) * root.rowHeight
            const bottom = 6
            return Math.min(root.maxPopupHeight, search + rows + bottom)
        }
        // Track the button's width even after reparenting to the window
        // root — anchors would tie us to a layout we're no longer in. The
        // binding stays live since `root` (and its width) outlive the
        // reparent for as long as the Combobox itself does.
        width: root.width
        // Vertical position is driven by the anchor properties below (filled
        // in by _showPopover) rather than a one-shot y, so the box tracks its
        // OWN height as the filtered list grows / shrinks:
        //   • opening downward → top pinned just under the button (_anchorTopY).
        //     A shrinking list simply lifts the bottom edge up — no gap.
        //   • opening upward (flipped: not enough room below) → BOTTOM pinned
        //     just above the button (_anchorBottomY); binding y to
        //     (_anchorBottomY − height) keeps that bottom edge glued to the
        //     button as height changes. A one-shot y computed at the full list
        //     height used to leave the box floating far above a 1–2 row result.
        property bool _flipUp: false
        property real _anchorTopY: 0
        property real _anchorBottomY: 0
        y: _flipUp ? Math.max(8, _anchorBottomY - height) : _anchorTopY
        // Floating-menu surface — matches PopoverMenu / ScheduleDropdown.
        color: Theme.color.bgMenu
        border.color: Theme.color.borderStrong
        border.width: 1
        radius: 0
        clip: true

        // Entrance animation — bound to root._open so each open/close cycle
        // re-animates (the popover Rectangle lives for the Combobox's
        // lifetime; only its `visible` toggles, so a Component.onCompleted
        // gate would only fire once per session).
        transformOrigin: Item.TopLeft
        opacity: root._open ? 1.0 : 0.0
        scale:   root._open ? 1.0 : 0.96
        Behavior on opacity { NumberAnimation { duration: Theme.motion.instant; easing.type: Easing.OutCubic } }
        Behavior on scale   { NumberAnimation { duration: Theme.motion.instant; easing.type: Easing.OutCubic } }

        // Layered drop shadow — mirrors PopoverMenu so all floating
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
            height: 30
            radius: 0
            color: Theme.color.canvas
            border.color: Theme.color.borderSubtle
            border.width: 1

            AppIcon {
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                name: "search"
                size: Theme.icon.md
                color: Theme.color.textTertiary
            }
            TextInput {
                id: searchField
                anchors.fill: parent
                anchors.leftMargin: 28
                anchors.rightMargin: 8
                verticalAlignment: TextInput.AlignVCenter
                color: Theme.color.textPrimary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize
                selectByMouse: true
                clip: true
                onTextChanged: popover._filter = text
                Keys.onEscapePressed: root._close()
                Keys.onReturnPressed: {
                    if (popover._filteredCount > 0) {
                        const first = popover._filteredOptions[0]
                        const v = (typeof first === "string") ? first
                                : (first.value || first.label || "")
                        root._close()           // close before notify — see row onClicked
                        root.valueSelected(v)
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
                radius: 0
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
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    verticalAlignment: Text.AlignVCenter
                    text: parent._label
                    color: parent._selected ? Theme.color.brand : Theme.color.textPrimary
                    font.family: root.previewFontFamily ? parent._value : Theme.font.family
                    font.pixelSize: Theme.font.bodySize
                    elide: Text.ElideRight
                }
                MouseArea {
                    id: rowMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        // Close BEFORE notifying. A valueSelected handler that
                        // mutates `options` (e.g. the card's "add member" picker)
                        // rebuilds this ListView and destroys THIS delegate
                        // mid-click — so a _close() placed after the emit would
                        // never run and the popover would stick open. Close first.
                        root._close()
                        root.valueSelected(parent._value)
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

        // Reset the filter BEFORE measuring. popover.height is bound to the
        // filtered row count, so a filter lingering from a previous open would
        // shrink it and make the flip-up test below mis-judge whether the full
        // list fits under the button. (Also keeps the popover stateless between
        // opens — the previous filter never lingers.)
        searchField.text = ""
        popover._filter = ""

        // Anchor points in window space: just below the button (downward open)
        // and just above it (flipped open, where the popover's bottom pins).
        const below = root.mapToItem(win, 0, root.height + 4)
        const above = root.mapToItem(win, 0, -4)
        popover._anchorTopY    = below.y
        popover._anchorBottomY = above.y
        // Decide direction ONCE, against the full-height popover. Fixing it for
        // this open avoids the box hopping sides as the operator narrows the
        // list; the reactive y binding then absorbs the height changes.
        popover._flipUp = (below.y + popover.height > win.height)

        // Horizontal clamp so a button near the right edge can't push the
        // popover off-screen. Width is height-independent, so a one-shot x is
        // fine — no binding needed.
        let x = below.x
        if (x + popover.width > win.width) x = win.width - popover.width - 8
        popover.x = Math.max(8, x)

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
