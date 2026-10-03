import QtQuick

// One checkbox line: box, label, optional detail on the right. The box is
// the same 18 px brand-filled square ExportThemeDialog draws inline for its
// font list, lifted into a control so the profile export / import dialogs
// share one look instead of each re-drawing it.
//
//   CheckRow {
//       label:   qsTr("Songs")
//       detail:  qsTr("120 songs")
//       checked: root.parts.songs
//       onToggled: root.parts = Object.assign({}, root.parts, { songs: !root.parts.songs })
//   }
//
// `checked` is a plain input. The row never flips it itself, it only emits
// toggled(), so the owner stays the single source of truth (same contract
// as ToggleSwitch).
Rectangle {
    id: root

    property bool   checked: false
    property string label: ""
    property string detail: ""

    signal toggled()

    implicitHeight: 36
    implicitWidth: 240
    color: ma.containsMouse && root.enabled ? Theme.color.overlay : "transparent"
    opacity: root.enabled ? 1.0 : 0.45

    Rectangle {
        id: box
        width: 18
        height: 18
        anchors.left: parent.left
        anchors.leftMargin: Theme.space.sm
        anchors.verticalCenter: parent.verticalCenter
        radius: 3
        color: root.checked ? Theme.color.brand : "transparent"
        border.color: root.checked ? Theme.color.brand : Theme.color.borderStrong
        border.width: 1

        AppIcon {
            visible: root.checked
            anchors.centerIn: parent
            name: "check"
            color: "#ffffff"   // check on the deep-teal box
            size: 12
        }
    }

    Text {
        anchors.left: box.right
        anchors.leftMargin: Theme.space.md
        anchors.right: detailText.left
        anchors.rightMargin: Theme.space.md
        anchors.verticalCenter: parent.verticalCenter
        elide: Text.ElideRight
        text: root.label
        color: Theme.color.textPrimary
        font.family: Theme.font.family
        font.pixelSize: Theme.font.bodySize
    }

    Text {
        id: detailText
        anchors.right: parent.right
        anchors.rightMargin: Theme.space.sm
        anchors.verticalCenter: parent.verticalCenter
        text: root.detail
        color: Theme.color.textTertiary
        font.family: Theme.font.family
        font.pixelSize: Theme.font.smallSize
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: root.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: if (root.enabled) root.toggled()
    }
}
