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
    // Direct anchors instead of a Column-based layout so the search row
    // and the list have deterministic sizes — the previous Column-based
    // approach had height computations whose first evaluation could see
    // an empty options array (before the parent's font-list binding
    // resolved), capping the popover at ~3 rows and breaking scroll.
    Rectangle {
        id: popover
        visible: root._open
        z: 1000
        anchors.top: button.bottom
        anchors.topMargin: 4
        anchors.left: button.left
        anchors.right: button.right
        height: root.maxPopupHeight
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
                        root._open = false
                    }
                }
            }
        }
    }
}
