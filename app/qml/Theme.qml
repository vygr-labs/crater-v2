pragma Singleton

import QtQuick

QtObject {
    readonly property QtObject color: QtObject {
        // Surfaces — warm-tinted near-blacks. Avoid #000 (harsh, OLED-burn-y).
        readonly property color canvas:        "#0a0a0d"
        readonly property color elevated:      "#13131a"
        readonly property color raised:        "#1c1c25"
        readonly property color overlay:       "#262631"
        readonly property color borderSubtle:  "#1f1f29"
        readonly property color borderStrong:  "#2e2e3a"

        // Text — calibrated for AA contrast on `canvas`/`elevated`.
        readonly property color textPrimary:   "#f1f1f5"
        readonly property color textSecondary: "#a3a3b0"
        readonly property color textTertiary:  "#6b6b78"
        readonly property color textDisabled:  "#4a4a55"

        // Brand — warm gold. Used for primary actions, focus, brand mark.
        readonly property color brand:         "#d4a574"
        readonly property color brandHover:    "#dfb585"
        readonly property color brandPressed:  "#c89967"
        readonly property color brandSubtle:   "#2a2218"
        readonly property color brandInk:      "#1a1208"

        // Broadcast semantics — these never get used decoratively.
        readonly property color live:          "#e85a4a"
        readonly property color liveSubtle:    "#3a1a17"
        readonly property color preview:       "#5b9df0"
        readonly property color previewSubtle: "#152538"
        readonly property color success:       "#4fc285"
        readonly property color warning:       "#f0b341"

        // Schedule item type tints.
        readonly property color typeSong:      "#d4a574"
        readonly property color typeScripture: "#5b9df0"
        readonly property color typeSermon:    "#c084fc"
        readonly property color typeVideo:     "#4fc285"
        readonly property color typeMedia:     "#f0b341"
        readonly property color typeNote:      "#a3a3b0"
    }

    readonly property QtObject space: QtObject {
        readonly property int xs:   4
        readonly property int sm:   8
        readonly property int md:   12
        readonly property int lg:   16
        readonly property int xl:   24
        readonly property int xxl:  32
        readonly property int xxxl: 48
    }

    readonly property QtObject radius: QtObject {
        readonly property int sm:   4
        readonly property int md:   6
        readonly property int lg:   10
        readonly property int xl:   16
        readonly property int pill: 999
    }

    readonly property QtObject font: QtObject {
        // Use the OS UI font so we look native on each platform.
        // QFont treats comma-separated family strings as a fallback chain,
        // so the first available family wins. We can bundle Inter via qrc
        // later for cross-platform pixel consistency.
        readonly property string family:
            "Segoe UI Variable Display, Segoe UI, .AppleSystemUIFont, SF Pro Display, Inter, Cantarell, Helvetica Neue, sans-serif"
        readonly property string monoFamily:
            "JetBrains Mono, Cascadia Code, SF Mono, Consolas, DejaVu Sans Mono, monospace"

        readonly property int displaySize: 26
        readonly property int titleSize:   16
        readonly property int bodySize:    13
        readonly property int smallSize:   11
        readonly property int microSize:   10

        readonly property int weightLight:    300
        readonly property int weightRegular:  400
        readonly property int weightMedium:   500
        readonly property int weightSemiBold: 600
    }

    readonly property QtObject motion: QtObject {
        readonly property int instant: 120
        readonly property int normal:  180
        readonly property int slow:    240
    }

    readonly property QtObject size: QtObject {
        readonly property int topBarHeight:      56
        readonly property int statusBarHeight:   28
        readonly property int leftRailWidth:     240
        readonly property int outputPanelWidth:  380
        readonly property int rowHeight:         44
        readonly property int controlHeight:     32
        readonly property int scheduleRowHeight: 64
    }
}
