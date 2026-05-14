import QtQuick

// MouseArea subclass that opens a context menu on right-click. The 11+ call
// sites for right-click menus across the app used to duplicate ~15 lines of
// boilerplate (acceptedButtons + onClicked + button-check + mapToItem +
// openModal) — this collapses them to a single property assignment.
//
// Usage:
//   RightClickArea {
//       anchors.fill: parent
//       menuItems: [
//           { label: qsTr("Edit"),   iconName: "edit",  action: () => ... },
//           { separator: true },
//           { label: qsTr("Delete"), iconName: "trash", destructive: true,
//             action: () => ... }
//       ]
//       onLeftClicked:   function(mouse) { /* normal click */ }
//       onRightClicked:  function(mouse) { /* fired before menu opens — e.g.
//                                            select the row so the menu acts
//                                            on what's visually highlighted */ }
//       onDoubleClicked:                 { /* inherited from MouseArea */ }
//   }
//
// Notes:
//   - Listen to `leftClicked` / `rightClicked` (custom signals here), not
//     the inherited `clicked` — the latter is used internally to route
//     right-clicks into the menu and overriding it would defeat that.
//   - `menuItems` may also be a function (zero-arg, returning an array) for
//     menus whose contents depend on runtime state (favorite toggle, etc.).
//     Resolved on each right-click.
//   - All MouseArea features still work: hoverEnabled, containsMouse,
//     cursorShape, pressAndHold, drag, etc. We just pre-set sensible
//     defaults — override on the instance to change them.
MouseArea {
    id: root

    property var  menuItems: []
    property real menuWidth: 220

    signal leftClicked(var mouse)
    signal rightClicked(var mouse)

    acceptedButtons: Qt.LeftButton | Qt.RightButton
    hoverEnabled:    true
    cursorShape:     Qt.PointingHandCursor

    onClicked: function(mouse) {
        if (mouse.button === Qt.RightButton) {
            root.rightClicked(mouse)
            const items = (typeof root.menuItems === "function")
                          ? root.menuItems()
                          : root.menuItems
            if (!items || items.length === 0) return
            AppState.openContextMenuAt(root, mouse.x, mouse.y, items,
                                       { menuWidth: root.menuWidth })
        } else {
            root.leftClicked(mouse)
        }
    }
}
