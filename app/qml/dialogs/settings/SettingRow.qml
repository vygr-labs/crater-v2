import QtQuick
import QtQuick.Layouts

// One settings row: title and an optional description on the left, the
// row's controls on the right. The text column takes whatever width the
// controls leave and wraps, so a long description or a wide control group
// never runs underneath the other. Height follows the content.
//
// Controls go in as children and are laid out left to right:
//
//   SettingRow {
//       title: qsTr("Reduce motion")
//       description: qsTr("Snap instead of animating")
//       ToggleSwitch { value: ...; onToggled: ... }
//   }
//
// Children sit in a Row, so they must not set anchors themselves.
RowLayout {
    id: root

    property string title: ""
    property string description: ""
    // Dims the text when the row's controls are inert.
    property bool   dimmed: false
    default property alias controls: controlRow.data

    Layout.fillWidth: true
    spacing: Theme.space.lg

    ColumnLayout {
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignVCenter
        Layout.topMargin: Theme.space.sm
        Layout.bottomMargin: Theme.space.sm
        spacing: 2
        opacity: root.dimmed ? 0.5 : 1.0

        Text {
            Layout.fillWidth: true
            text: root.title
            wrapMode: Text.WordWrap
            color: Theme.color.textPrimary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.bodySize
            font.weight: Theme.font.weightMedium
        }
        Text {
            Layout.fillWidth: true
            visible: root.description.length > 0
            text: root.description
            wrapMode: Text.WordWrap
            color: Theme.color.textTertiary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.smallSize
        }
    }

    Row {
        id: controlRow
        Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
        spacing: Theme.space.sm
    }
}
