import QtQuick
import QtQuick.Controls.Basic
import Crater

// Themed vertical scrollbar with stepper arrows. Attach to any Flickable /
// ListView / GridView:
//
//   ListView { ScrollBar.vertical: AppScrollBar {} }
//
// Layout, top to bottom:  [ ^ up ] [ track + draggable handle ] [ v down ].
// The handle travels ONLY between the arrows — topPadding/bottomPadding reserve
// their height, and QQuickScrollBar lays the handle out within the remaining
// area, so it never slides under an arrow. The whole bar appears only while the
// content overflows (AsNeeded) and fades out when it fits.
//
// Vertical orientation by design — every attach site in the app is vertical.
ScrollBar {
    id: control

    policy: ScrollBar.AsNeeded
    minimumSize: 0.12               // keep the handle grabbable on long views
    stepSize: 0.05                  // distance one arrow tick / hold-step scrolls
    implicitWidth: Theme.size.scrollBar

    // Reserve the arrow zones at top and bottom.
    readonly property real arrowSize: 16
    topPadding: arrowSize
    bottomPadding: arrowSize

    // Present only while there is overflow to scroll.
    readonly property bool _shown: size < 1.0

    // ── Handle ──────────────────────────────────────────────────────────
    contentItem: Rectangle {
        implicitWidth: Theme.size.scrollBar - 4   // < bar width: a sliver of track each side
        radius: width / 2
        color: control.pressed ? Theme.color.textSecondary
             : control.hovered ? Theme.color.textTertiary
                                : Theme.color.borderStrong
        opacity: control._shown ? 1.0 : 0.0
        Behavior on opacity { NumberAnimation { duration: Theme.motion.instant } }
    }

    // ── Track + stepper arrows ──────────────────────────────────────────
    background: Item {
        opacity: control._shown ? 1.0 : 0.0
        Behavior on opacity { NumberAnimation { duration: Theme.motion.instant } }

        // Faint channel so the bar reads as a scrollbar, not a floating sliver.
        Rectangle {
            anchors.fill: parent
            color: Theme.color.borderSubtle
            opacity: 0.5
        }

        // Up arrow — single click nudges by stepSize; press-and-hold repeats.
        Rectangle {
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height: control.arrowSize
            color: upMa.pressed ? Theme.color.overlay : "transparent"
            AppIcon {
                anchors.centerIn: parent
                name: "chevron-up"
                size: Theme.icon.xs
                color: upMa.containsMouse ? Theme.color.textPrimary : Theme.color.textTertiary
            }
            MouseArea {
                id: upMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onPressed: control.decrease()
            }
            // Hold-to-scroll: the first step fires on press above, this repeats
            // while the button stays down.
            Timer { interval: 55; repeat: true; running: upMa.pressed; onTriggered: control.decrease() }
        }

        // Down arrow.
        Rectangle {
            anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
            height: control.arrowSize
            color: downMa.pressed ? Theme.color.overlay : "transparent"
            AppIcon {
                anchors.centerIn: parent
                name: "chevron-down"
                size: Theme.icon.xs
                color: downMa.containsMouse ? Theme.color.textPrimary : Theme.color.textTertiary
            }
            MouseArea {
                id: downMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onPressed: control.increase()
            }
            Timer { interval: 55; repeat: true; running: downMa.pressed; onTriggered: control.increase() }
        }
    }
}
