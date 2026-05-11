pragma Singleton

import QtQuick

QtObject {
    readonly property QtObject color: QtObject {
        // Surfaces — neutral near-blacks aligned with the Electron palette
        // (Tailwind/Radix gray scale). Avoid #000 (harsh, OLED-burn-y).
        readonly property color canvas:        "#111111"   // gray.950
        readonly property color elevated:      "#18181b"   // gray.900
        readonly property color raised:        "#27272a"   // gray.800
        readonly property color overlay:       "#2a2a28"   // neutralDark.300 — used for hover wash
        readonly property color borderSubtle:  "#1c1c1c"   // between gray.900 and gray.950 — the panel/divider hairline
        readonly property color borderStrong:  "#3f3f46"   // gray.700 — focused input border

        // Per-panel backgrounds. The library sidebar and the right pane each
        // get a very subtle differentiation from `canvas` so the operator's
        // eye can find pane boundaries even when borders are quiet. Both
        // sit a hair darker than canvas — mirrors electron's
        // `bg="gray.950/50"` (sidebar) and `bg="gray.950/30"` (content) which
        // composite to ~same color on a dark page.
        readonly property color bgSidebar:     "#0e0e0e"
        readonly property color bgContent:     "#0c0c0c"

        // Text — calibrated for AA contrast on `canvas`/`elevated`. Values
        // mirror electron's gray.200 / gray.400 / gray.500 / gray.600.
        readonly property color textPrimary:   "#e4e4e7"
        readonly property color textSecondary: "#a1a1aa"
        readonly property color textTertiary:  "#71717a"
        readonly property color textDisabled:  "#52525b"

        // Brand — Radix Green (electron `brand.800 #227617`). Used for the
        // brand mark, primary action affordances, scripture-tab selection
        // tint, and focus outlines. Was warm gold; switched to match the
        // electron experience.
        readonly property color brand:         "#227617"   // brand.800 — primary
        readonly property color brandHover:    "#2c7e21"   // brandDark.700
        readonly property color brandPressed:  "#216518"   // brandDark.900
        readonly property color brandSubtle:   "#173c13"   // brandDark.300 — selected-row wash
        readonly property color brandInk:      "#ffffff"   // text on a solid brand button

        // Broadcast semantics — these never get used decoratively.
        readonly property color live:          "#e85a4a"
        readonly property color liveSubtle:    "#3a1a17"
        readonly property color preview:       "#5b9df0"
        readonly property color previewSubtle: "#152538"
        readonly property color goLive:        "#22c55e"   // green: the "send it" action color
        readonly property color goLiveHover:   "#3ad273"
        readonly property color goLivePressed: "#1cae54"
        readonly property color goLiveInk:     "#0a1f10"
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
        // Body font is Funnel Sans (bundled at qrc:/fonts/FunnelSans-VariableFont_wght.ttf
        // and registered in main.cpp::registerBodyFont). Single family on
        // purpose: QML's `font.family` is a single QString, not a CSS-style
        // fallback chain. The application-wide fallbacks (Segoe UI, etc.)
        // live in main.cpp::initDefaultFont via QFont::setFamilies — anything
        // that doesn't override `font.family` inherits that chain.
        readonly property string family:    "Funnel Sans"
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

    // Schedule-item display helpers — derive label + color from item `kind`
    // so ScheduleService items don't need to carry presentation metadata.
    // Reuses the existing `color.typeXxx` tokens for design-system consistency.
    function scheduleLabel(kind) {
        if (!kind) return ""
        return String(kind).toUpperCase()
    }
    function scheduleColor(kind) {
        switch (kind) {
            case "song":         return color.typeSong
            case "scripture":    return color.typeScripture
            case "image":        return color.typeMedia
            case "video":        return color.typeVideo
            case "presentation": return color.typeSermon
            default:             return color.textSecondary
        }
    }
}
