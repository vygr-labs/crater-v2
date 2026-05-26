import QtQuick
import QtQuick.Controls.Basic
import Crater

// Dropdown counterpart to NumericInput for properties whose value space is
// a small fixed set. Used for `fontWeight` in the text properties panel —
// CSS/OpenType weight is one of nine 100..900 buckets, not a continuum, so
// a free-form number field invites typos (450, 750) that no installed font
// can actually render. The dropdown locks the user to legal values and
// labels each one ("Regular", "Bold") so the picker reads like a font menu
// instead of a numeric stepper.
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

    Rectangle {
        id: box
        anchors.left: lbl.visible ? lbl.right : parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        height: 32
        radius: 0
        color: Theme.color.canvas
        border.color: ma.containsMouse || popup.visible ? Theme.color.brand : Theme.color.borderStrong
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
        }

        AppIcon {
            id: chevron
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            name: "chevron-down"
            color: Theme.color.textTertiary
            size: Theme.icon.xs
        }

        MouseArea {
            id: ma
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: popup.visible ? popup.close() : popup.open()
        }
    }

    Popup {
        id: popup
        // Align popup's left edge to the value box, not the whole row,
        // so the label column on the left doesn't push the menu off-center.
        x: box.x
        y: box.y + box.height + 2
        width: box.width
        padding: 4
        modal: false
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent

        background: Rectangle {
            color: Theme.color.surface
            border.color: Theme.color.borderStrong
            border.width: 1
            radius: Theme.radius.sm
        }

        contentItem: Column {
            spacing: 0
            Repeater {
                model: root.options
                delegate: Rectangle {
                    required property var modelData
                    width: popup.width - popup.padding * 2
                    height: 28
                    radius: Theme.radius.xs
                    readonly property bool _isCurrent: modelData.value === root._snapped
                    color: rowMa.containsMouse
                           ? Theme.color.overlay
                           : (_isCurrent ? Theme.color.overlay : "transparent")

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.label
                        color: Theme.color.textPrimary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.bodySize
                        font.weight: modelData.value
                    }
                    Text {
                        anchors.right: parent.right
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.value
                        color: Theme.color.textTertiary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
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
                            popup.close()
                        }
                    }
                }
            }
        }
    }
}
