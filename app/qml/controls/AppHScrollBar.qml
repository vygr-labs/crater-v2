import QtQuick
import QtQuick.Controls.Basic
import Crater

// Horizontal counterpart of AppScrollBar, for the side-scrolling strips (the
// theme editor's design rail, the presentation editor's Design strip):
//
//   ListView { orientation: ListView.Horizontal; ScrollBar.horizontal: AppHScrollBar {} }
//
// AppScrollBar is vertical by design. Its stepper arrows pad it out, so laid
// sideways it stood tall enough to cover the captions under each thumbnail
// and took the clicks meant for them. This one is a slim track and handle
// with no arrows. Pair it with HWheelArea for the mouse wheel, and keep
// the view's cells clear of `height` while the bar is shown (`shown`).
ScrollBar {
    id: control

    orientation: Qt.Horizontal
    policy: ScrollBar.AsNeeded
    minimumSize: 0.12
    padding: 2
    implicitHeight: 8

    // Present only while there is overflow to scroll.
    readonly property bool shown: size < 1.0

    contentItem: Rectangle {
        implicitHeight: 4
        radius: height / 2
        color: control.pressed ? Theme.color.textSecondary
             : control.hovered ? Theme.color.textTertiary
                                : Theme.color.borderStrong
        opacity: control.shown ? 1.0 : 0.0
        Behavior on opacity { NumberAnimation { duration: Theme.motion.instant } }
    }

    background: Rectangle {
        color: Theme.color.borderSubtle
        opacity: control.shown ? 0.5 : 0.0
        Behavior on opacity { NumberAnimation { duration: Theme.motion.instant } }
    }
}
