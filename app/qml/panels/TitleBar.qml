import QtQuick
import QtQuick.Window

// Custom window title strip. Sits above TopBar (chosen layout: stacked, not
// fused) and replaces the OS-drawn title bar that Main.qml's
// `Qt.FramelessWindowHint` removes. Carries the Crater brand mark, the
// window title text, and the min/max/close buttons.
//
// Frameless-window behaviors (drag, snap, edge-resize) are wired via
// `Window.startSystemMove()` and `Window.startSystemResize()` — Qt 6.5+
// primitives that delegate to the OS so Aero Snap (Windows), magnetic
// edges (macOS), and tile-on-drag (KDE/GNOME) all work natively without
// re-implementing WM behavior in QML.
//
// Layout flips per platform: window buttons sit on the RIGHT on
// Windows/Linux (Windows convention) and on the LEFT on macOS (Mac
// convention — close-in-the-corner reachability). The visual style of
// the buttons stays unified (Lucide glyphs, Crater hover wash) rather
// than mimicking native traffic lights — same logic as Slack / Discord
// / Figma.
Rectangle {
    id: root

    height: 32
    color: Theme.color.elevated

    // ── State derived from the containing Window ────────────────────────
    // `Window.window` is an attached property that resolves to the
    // QQuickWindow this item lives in — no plumbing from Main.qml needed.
    readonly property var _win: Window.window
    readonly property bool _isMaximized: _win
        ? (_win.visibility === Window.Maximized || _win.visibility === Window.FullScreen)
        : false

    // Buttons go top-LEFT on macOS (close, minimize, maximize) and top-
    // RIGHT on Windows/Linux (minimize, maximize, close). One bool flips
    // the entire layout.
    readonly property bool _macStyle: Qt.platform.os === "osx"

    // Bottom hairline — same idiom as TopBar so the two strips read as a
    // stacked unit, not as two floating panels.
    Rectangle {
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 1
        color: Theme.color.borderSubtle
    }

    // ── Window buttons cluster ──────────────────────────────────────────
    // Declared before the drag region so anchor references from the drag
    // region resolve to a sized item.
    Row {
        id: buttonRow

        anchors.verticalCenter: parent.verticalCenter
        // Pin to left or right based on platform. The unused side's anchor
        // is left undefined (QML resolves anchors with `undefined` as "no
        // constraint" — equivalent to omitting the assignment).
        anchors.left:  root._macStyle ? parent.left  : undefined
        anchors.right: root._macStyle ? undefined    : parent.right
        anchors.leftMargin:  root._macStyle ? Theme.space.sm : 0
        anchors.rightMargin: root._macStyle ? 0 : 0
        spacing: 0

        Repeater {
            // Order on Mac: close, minimize, maximize (visual order matches
            // native traffic-light positions even though we draw our own).
            // Order on Win/Linux: minimize, maximize, close.
            model: root._macStyle
                ? [ "close", "minimize", "maximize" ]
                : [ "minimize", "maximize", "close" ]

            delegate: TitlebarButton {
                kind: modelData
                isMaximized: root._isMaximized
                onClicked: root._handleAction(kind)
            }
        }
    }

    // ── Brand mark + title ──────────────────────────────────────────────
    // Brand sits next to the buttons on Mac (because buttons are on the
    // left there), or at the window's left edge on Windows/Linux. Either
    // way, the mark always shows up at the "natural" left of the strip
    // from the operator's reading-order perspective.
    Row {
        id: brandRow

        anchors.verticalCenter: parent.verticalCenter
        anchors.left: root._macStyle ? buttonRow.right : parent.left
        anchors.leftMargin: root._macStyle ? Theme.space.md : Theme.space.lg
        spacing: Theme.space.sm

        Image {
            id: brandMark

            source: "qrc:/brand/crater.svg"
            // sourceSize hints Qt's SVG renderer to rasterize at this size
            // rather than at the SVG's intrinsic 64-unit viewBox. Without
            // it, the SVG renders at 64x64 then scales down to 16 — visibly
            // softer on low-DPI displays.
            sourceSize.width: 16
            sourceSize.height: 16
            width: 16
            height: 16
            anchors.verticalCenter: parent.verticalCenter
            smooth: true
            antialiasing: true
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            // The window's `title` property is the source of truth — keeps
            // alt-tab tooltips, taskbar hover, and screen-reader output in
            // lockstep with what's drawn here.
            text: root._win ? root._win.title : ""
            color: Theme.color.textSecondary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.smallSize
            font.weight: Theme.font.weightMedium
            elide: Text.ElideRight
        }
    }

    // ── Drag region (fills the gap between brand and buttons) ───────────
    // startSystemMove() hands the drag to the WM. Aero Snap (Windows),
    // magnetic-edge snap (macOS), and edge-tile (GNOME/KDE) all flow
    // through this single call — no re-implementation of snap state
    // machines in QML.
    //
    // Double-click toggles maximize, matching every desktop OS convention.
    MouseArea {
        id: dragArea

        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.left: brandRow.right
        anchors.right: root._macStyle ? parent.right : buttonRow.left
        anchors.leftMargin: Theme.space.sm
        anchors.rightMargin: root._macStyle ? 0 : Theme.space.sm

        acceptedButtons: Qt.LeftButton
        // The hover cursor stays as the default arrow — Windows / macOS
        // both show no special cursor on titlebar drag regions and we
        // want to match.

        onPressed: function (mouse) {
            if (mouse.button === Qt.LeftButton && root._win) {
                root._win.startSystemMove()
            }
        }
        onDoubleClicked: function (mouse) {
            if (mouse.button === Qt.LeftButton) {
                root._toggleMaximize()
            }
        }
    }

    // ── Helpers ─────────────────────────────────────────────────────────
    function _toggleMaximize() {
        if (!root._win) return
        if (root._isMaximized) {
            root._win.showNormal()
        } else {
            root._win.showMaximized()
        }
    }

    function _handleAction(kind) {
        if (!root._win) return
        switch (kind) {
            case "minimize": root._win.showMinimized(); break
            case "maximize": root._toggleMaximize();    break
            case "close":    root._win.close();         break
        }
    }

    // ── Window-control button (inline component) ────────────────────────
    // Inline definitions (the `component` keyword, Qt 6.3+) keep the
    // button next to its only call site rather than spawning a one-off
    // file under controls/. The existing IconButton atom doesn't fit
    // here because (a) titlebar buttons want explicit hover colors per
    // role (close hover = red), and (b) they want platform-conditional
    // widths.
    component TitlebarButton: Rectangle {
        id: btn

        property string kind: ""          // "minimize" | "maximize" | "close"
        property bool   isMaximized: false
        signal clicked()

        readonly property bool _isClose: btn.kind === "close"

        // Windows 11 titlebar buttons are 46×32; Mac convention is closer
        // to 36×32 since the traffic-light density is tighter. We honor
        // each platform's eye-baseline.
        width: root._macStyle ? 36 : 46
        height: 32

        color: hover.containsMouse
            ? (btn._isClose ? Theme.color.live : Theme.color.overlay)
            : "transparent"

        Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

        AppIcon {
            anchors.centerIn: parent
            name: btn._iconName
            // Close-on-hover gets white ink against the red wash; the
            // other buttons brighten subtly from secondary → primary.
            color: hover.containsMouse
                ? (btn._isClose ? "#ffffff" : Theme.color.textPrimary)
                : Theme.color.textSecondary
            size: 12

            Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
        }

        // Picks the right Lucide glyph for kind + state. The maximize
        // button shows `copy` (two stacked squares) while the window is
        // restored and `square` (single outline) while it's maximized —
        // i.e. the icon previews what the window will look like AFTER
        // the click: dual-square silhouette for the about-to-spread-out
        // maximize action, single-square outline for the about-to-
        // consolidate-down restore action.
        readonly property string _iconName: {
            if (btn.kind === "minimize") return "minus"
            if (btn.kind === "close")    return "x"
            return btn.isMaximized ? "square" : "copy"
        }

        MouseArea {
            id: hover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: btn.clicked()
        }
    }
}
