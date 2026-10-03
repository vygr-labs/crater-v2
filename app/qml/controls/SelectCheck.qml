import QtQuick

// Multi-select checkbox for list rows and grid tiles (library tabs and the
// schedule). Clicking it toggles the row's checked state and nothing else:
// the current row, Preview and keyboard focus are left alone.
//
// Two looks:
//   - default: hairline box on the row surface (list rows)
//   - onImage: dark translucent box with a light rim, legible on top of a
//     thumbnail or theme preview (media grid, theme tiles)
// Checked is the same brand fill in both.
//
// Hosts place it above the row's own MouseArea (z: 1 or later in the
// delegate) so the toggle is not swallowed by the row click.
Rectangle {
    id: root

    property bool checked: false
    property bool onImage: false
    // Pointer is over the box. Hosts fold this into their "show the box"
    // condition: the box's own MouseArea can take hover away from the row
    // underneath, and a box that hid itself the moment the pointer reached
    // it could never be clicked.
    readonly property bool hovered: ma.containsMouse

    signal toggled()

    implicitWidth: 16
    implicitHeight: 16
    radius: 0
    color: root.checked ? Theme.color.brand
         : root.onImage ? "#000000bb"
         : ma.containsMouse ? Theme.color.overlay
                            : "transparent"
    border.color: root.checked ? Theme.color.brand
                : root.onImage ? (ma.containsMouse ? "#ffffffcc" : "#ffffff66")
                : ma.containsMouse ? Theme.color.textSecondary
                                   : Theme.color.borderStrong
    border.width: 1

    AppIcon {
        anchors.centerIn: parent
        visible: root.checked
        name: "check"
        size: Theme.icon.xs
        color: "#ffffff"
    }

    MouseArea {
        id: ma
        // A few px of slack around a 16 px box: easier to hit at speed
        // without stealing clicks meant for the row text.
        anchors.fill: parent
        anchors.margins: -4
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggled()
    }
}
