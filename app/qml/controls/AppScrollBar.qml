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
    implicitWidth: Theme.size.scrollBar

    // ── Step distance ───────────────────────────────────────────────────
    // ScrollBar.stepSize is measured in FRACTION OF TOTAL CONTENT, not
    // pixels, so any constant here scales with list length: the 0.05 this
    // used to carry moved 5% of the content per tick — measured at 420px
    // (15 rows) on a 300-row list, and proportionally worse on the
    // 31k-verse scripture list.
    //
    // Convert a fixed pixel distance into those units instead. `size` is
    // viewport/content and `height` is the viewport, so
    // contentHeight == height / size, and moving `px` pixels is
    // px / contentHeight == px * size / height. Measured at a flat 48px per
    // tick across 12-, 300- and 31,102-row lists.
    //
    // The floor matters: QQuickScrollBar reads a stepSize of zero as 0.1
    // (qFuzzyIsNull, threshold 1e-12), so letting this reach 0 would
    // silently install a 10%-of-content jump. It has to stay WELL below any
    // legitimate value though — the scripture list wants 5.5e-5 per tick,
    // and a floor of 1e-3 was measured clamping that back up to 870px.
    // 1e-9 clears qFuzzyIsNull with room to spare and never clamps a real
    // step. The 0.5 ceiling keeps a barely-overflowing view from stepping
    // past its own end in one tick.
    stepSize: {
        if (control.height <= 0 || control.size <= 0 || control.size >= 1.0)
            return 0.05
        const s = (Theme.size.scrollStep * control.size) / control.height
        return Math.max(1e-9, Math.min(0.5, s))
    }

    // Reserve the arrow zones at top and bottom.
    readonly property real arrowSize: 16
    topPadding: arrowSize
    bottomPadding: arrowSize

    // Auto-repeat timings for a held arrow, matching the platform feel: a
    // deliberate pause after the first tick so a plain click is exactly ONE
    // step, then a steady repeat.
    readonly property int _repeatDelay:    350
    readonly property int _repeatInterval: 60

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

    // ── Track ───────────────────────────────────────────────────────────
    // Faint channel so the bar reads as a scrollbar, not a floating sliver.
    // The arrows deliberately do NOT live in here — see the stepper block.
    background: Item {
        opacity: control._shown ? 1.0 : 0.0
        Behavior on opacity { NumberAnimation { duration: Theme.motion.instant } }

        Rectangle {
            anchors.fill: parent
            color: Theme.color.borderSubtle
            opacity: 0.5
        }
    }

    // ── Stepper arrows ──────────────────────────────────────────────────
    // Parented to the control's PARENT (the attached Flickable), not to the
    // control, and laid over its two ends.
    //
    // This looks like a detour and is not. QQuickControl — ScrollBar's base
    // — calls setFiltersChildMouseEvents(true), so the ScrollBar intercepts
    // every press aimed at any descendant and consumes it for its own
    // click-the-track-to-jump behaviour. Arrow buttons living inside
    // `background` therefore never received a single click: pressing the
    // down arrow was read as a track click at the very bottom of the bar
    // and teleported the view to the end, pressing the up arrow sent it to
    // the top. That is the "the up/down button jumps to the end of the
    // page" report, and it also left stepSize above as dead code, since
    // nothing ever reached increase() / decrease().
    //
    // Verified against real Qt 6.11.1 before choosing this shape: with the
    // arrow inside `background`, neither a MouseArea, a MouseArea with
    // preventStealing, nor a TapHandler fires — the bar jumps to 0.93 in
    // all three. Reparented out, the press lands. Track clicks BETWEEN the
    // arrows still jump to the clicked position, which is correct scrollbar
    // behaviour; the arrows simply now cover the two ends, where a jump was
    // never what the operator was asking for.
    //
    // Coordinates are direct — control.x / y / width / height are already
    // expressed in this same parent's coordinate space.
    Item {
        id: steppers
        parent: control.parent
        x: control.x
        y: control.y
        width: control.width
        height: control.height
        z: control.z + 1

        // Follow the bar's own fade, and stop taking clicks once it is gone
        // so a view with nothing to scroll doesn't keep two dead 16px
        // targets pinned over its content.
        opacity: (control.visible && control._shown) ? 1.0 : 0.0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Theme.motion.instant } }

        // Up arrow — one click is one step; press-and-hold repeats after a
        // deliberate pause (see _repeatDelay).
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
            // The press above already fired the first tick, so this waits out
            // _repeatDelay before taking over, then shortens its own interval
            // for the steady repeat and resets on release.
            Timer {
                interval: control._repeatDelay
                repeat: true
                running: upMa.pressed
                onTriggered: { interval = control._repeatInterval; control.decrease() }
                onRunningChanged: if (!running) interval = control._repeatDelay
            }
        }

        // Down arrow — mirror of the above.
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
            Timer {
                interval: control._repeatDelay
                repeat: true
                running: downMa.pressed
                onTriggered: { interval = control._repeatInterval; control.increase() }
                onRunningChanged: if (!running) interval = control._repeatDelay
            }
        }
    }
}
