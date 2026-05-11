import QtQuick

// Right-click context menu — thin wrapper around PopoverMenu for the
// common case of "open at mouse position from a MouseArea.onPressed".
//
// Usage:
//   ContextMenu {
//       id: menu
//       model: [{ label: "Edit", iconName: "edit", action: () => ... },
//               { separator: true },
//               { label: "Delete", iconName: "trash", destructive: true, action: () => ... }]
//   }
//   ...
//   MouseArea {
//       acceptedButtons: Qt.LeftButton | Qt.RightButton
//       onClicked: function(mouse) {
//           if (mouse.button === Qt.RightButton) {
//               const p = mapToItem(menu.parent, mouse.x, mouse.y)
//               menu.openAt(p.x, p.y)
//           }
//       }
//   }
PopoverMenu {
    id: root

    // Defaults that distinguish a context menu from a dropdown:
    // narrower, slightly more compact. Override on each instance if needed.
    menuWidth: 200
}
