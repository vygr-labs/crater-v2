import QtQuick
import Crater

// A select-style dropdown with optional filter. Displays the current value
// in a button; on click, opens an inline popover below the button with a
// search field and scrolling list of options. Closes on selection, Escape,
// or clicking the button again.
//
// `options` accepts either:
//   - an array of strings:        ["Inter", "Georgia", ...]
//   - an array of { label, value }: [{ label: "Inter (sans)", value: "Inter" }]
//
// Emits `valueSelected(string)` when the user picks an option.
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

    property bool _open: false

    // While open, raise the whole Combobox above sibling items in its
    // parent's draw order. The popover lives in our subtree, so without
    // this, sibling rows declared *after* us in the parent's Column would
    // paint over the open dropdown. Callers may additionally lift the
    // containing accordion's z to push past accordion-level siblings.
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
            size: 12
            color: Theme.color.textTertiary
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                root._open = !root._open
                if (root._open) {
                    searchField.text = ""
                    searchField.forceActiveFocus()
                }
            }
        }
    }

    // ── Popover ───────────────────────────────────────────────────────
    // Rendered in the local scope. Its z (high) keeps it above sibling
    // accordion sections within the same Flickable. If it overflows the
    // Flickable's clip rect, the user can scroll to reveal the rest.
    Rectangle {
        id: popover
        visible: root._open
        z: 1000
        anchors.top: button.bottom
        anchors.topMargin: 4
        anchors.left: button.left
        anchors.right: button.right
        height: {
            const items = popover._filteredCount * root.rowHeight + 8
            const search = root.searchable ? searchField.parent.height + 6 : 0
            return Math.min(items + search + 8, root.maxPopupHeight)
        }
        color: Theme.color.raised
        border.color: Theme.color.borderStrong
        border.width: 1
        radius: Theme.radius.md
        clip: true

        // Event-blocking backdrop. A bare Rectangle does not stop mouse or
        // hover events from reaching items behind it — only a MouseArea
        // (or HoverHandler) claims the cursor. This sits at the bottom of
        // the popover's child stack so delegate MouseAreas above still
        // receive their own events, while events that fall in the gaps
        // (search row border, list margin, between delegates) are absorbed
        // here instead of bleeding through to the property inputs
        // underneath.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            hoverEnabled: true
            onPressed: function(m) { m.accepted = true }
            onWheel: function(w) { w.accepted = true }
        }

        property string _filter: ""
        property var _filteredOptions: {
            if (!root.searchable || !_filter) return root.options
            const f = _filter.toLowerCase()
            return root.options.filter(function(opt) {
                const t = (typeof opt === "string") ? opt
                        : (opt.label || opt.value || "")
                return t.toLowerCase().indexOf(f) >= 0
            })
        }
        readonly property int _filteredCount: _filteredOptions ? _filteredOptions.length : 0

        Column {
            anchors.fill: parent
            anchors.margins: 6
            spacing: 4

            // ── Search ─────────────────────────────────────────────────
            Rectangle {
                visible: root.searchable
                anchors.left: parent.left
                anchors.right: parent.right
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
                    size: 12
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
                    Keys.onEscapePressed: root._open = false
                    Keys.onReturnPressed: {
                        if (popover._filteredCount > 0) {
                            const first = popover._filteredOptions[0]
                            const v = (typeof first === "string") ? first
                                    : (first.value || first.label || "")
                            root.valueSelected(v)
                            root._open = false
                        }
                    }
                }
            }

            // ── List ──────────────────────────────────────────────────
            ListView {
                id: listView
                anchors.left: parent.left
                anchors.right: parent.right
                height: parent.height
                    - (root.searchable ? searchField.parent.height + parent.spacing : 0)
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
                            root._open = false
                        }
                    }
                }
            }
        }
    }
}
