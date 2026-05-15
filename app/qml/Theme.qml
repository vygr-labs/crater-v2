pragma Singleton

import QtQuick

QtObject {
    id: theme

    // ── Global UI scale ─────────────────────────────────────────────────
    // Every Theme.font.* and Theme.icon.* token multiplies its base value by
    // this scale, so a single property bumps the whole UI together. Default
    // 1.0; future SettingsService wiring will persist a per-user value (think
    // accessibility / "increase text size" preference). Setting this at
    // runtime re-evaluates every binding that reads through the tokens.
    //
    // Hardcoded font.pixelSize / size: values at call sites do NOT scale —
    // those are deliberate one-off pixel choices. Most app surface area
    // routes through the tokens, so the practical impact is small.
    property real uiScale: 1.0

    readonly property QtObject color: QtObject {
        // Surfaces — neutral near-blacks aligned with the Electron palette
        // (Tailwind/Radix gray scale). Avoid #000 (harsh, OLED-burn-y).
        readonly property color canvas:        "#111111"   // gray.950
        readonly property color elevated:      "#18181b"   // gray.900
        readonly property color raised:        "#27272a"   // gray.800
        readonly property color overlay:       "#2a2a28"   // neutralDark.300 — used for hover wash
        readonly property color borderSubtle:  "#27272a"   // gray.800 — panel/divider hairline. Matches electron's `borderColor="gray.800"`. One shade lighter than the `elevated` panel surface so dividers stay visible against it.
        readonly property color borderStrong:  "#3f3f46"   // gray.700 — focused input border

        // Per-panel backgrounds. Sit on the panel surface (`elevated`, the
        // gray.900 equivalent) as subtle insets, mirroring electron's library
        // overlays — `bg="gray.950/50"` for the sidebar (~14% blend toward
        // gray.950) and `bg="gray.950/30"` for the content (~30% blend toward
        // gray.950). Earlier values pointed *below* canvas which read as
        // recessed cutouts; these sit just under the panel surface so the
        // hierarchy is page < library overlay < panel surface.
        readonly property color bgSidebar:     "#14141a"
        readonly property color bgContent:     "#16161a"

        // Text — calibrated for AA contrast on `canvas`/`elevated`. Values
        // mirror electron's gray.200 / gray.400 / gray.500 / gray.600.
        readonly property color textPrimary:   "#e4e4e7"
        readonly property color textSecondary: "#a1a1aa"
        readonly property color textTertiary:  "#71717a"
        readonly property color textDisabled:  "#52525b"
        // gray.300 — the body-row title color (slightly dimmer than textPrimary,
        // but bright enough to read at scale). Used by SongsTab and any other
        // dense list whose unselected rows shouldn't compete with focused ones.
        readonly property color textTitle:     "#d4d4d8"

        // Brand — Radix Green (electron `brand.800 #227617`). Used for the
        // brand mark, primary action affordances, scripture-tab selection
        // tint, and focus outlines. Was warm gold; switched to match the
        // electron experience.
        readonly property color brand:         "#227617"   // brand.800 — primary
        readonly property color brandHover:    "#2c7e21"   // brandDark.700
        readonly property color brandPressed:  "#216518"   // brandDark.900
        readonly property color brandSubtle:   "#173c13"   // brandDark.300 — selected-row wash
        readonly property color brandInk:      "#ffffff"   // text on a solid brand button
        // brand.900 at 30% alpha — the row-hover wash for library lists. The
        // RGB matches `brand` (#227617 = 34/118/23). Mirrors electron's
        // `bg=${defaultPalette}.900/30` used on Songs/Scripture row hovers.
        readonly property color rowHoverBrand: Qt.rgba(34/255, 118/255, 23/255, 0.30)

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

        // Pixel sizes scale with Theme.uiScale. Base values represent
        // uiScale=1.0 and were bumped +2 from earlier defaults
        // (13/11/10/16/26 → 15/13/12/18/30) to better match electron's
        // typography on operator-console screens.
        readonly property int displaySize: Math.round(30 * theme.uiScale)
        readonly property int titleSize:   Math.round(18 * theme.uiScale)
        readonly property int bodySize:    Math.round(15 * theme.uiScale)
        readonly property int smallSize:   Math.round(13 * theme.uiScale)
        readonly property int microSize:   Math.round(12 * theme.uiScale)

        readonly property int weightLight:    300
        readonly property int weightRegular:  400
        readonly property int weightMedium:   500
        readonly property int weightSemiBold: 600
        readonly property int weightBold:     700
    }

    // ── Icon sizes ──────────────────────────────────────────────────────
    // Lucide-glyph point sizes used by AppIcon and IconButton.iconSize.
    // Base values were chosen to absorb the previous +2 size bump:
    //   former 9-11   → tiny (11)
    //   former 10-11  → xs   (12)
    //   former 12-13  → sm   (14)
    //   former 14-15  → md   (16)
    //   former 16-17  → lg   (18)
    //   former 28-32  → xl   (30)   — empty-state illustrations
    //   former 52     → xxl  (52)   — hero feature illustrations
    // Like the font tokens, each multiplies through theme.uiScale.
    readonly property QtObject icon: QtObject {
        readonly property int tiny: Math.round(11 * theme.uiScale)
        readonly property int xs:   Math.round(12 * theme.uiScale)
        readonly property int sm:   Math.round(14 * theme.uiScale)
        readonly property int md:   Math.round(16 * theme.uiScale)
        readonly property int lg:   Math.round(18 * theme.uiScale)
        readonly property int xl:   Math.round(30 * theme.uiScale)
        readonly property int xxl:  Math.round(52 * theme.uiScale)
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
        readonly property int scheduleRowHeight: 36
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
    // Lucide icon name for a schedule item's kind. Mirrors electron's
    // typeIcons map in SchedulePanel.tsx (TbMusic / TbBook2 / TbPresentation /
    // TbVideo / TbPhoto / TbList default).
    function scheduleKindIcon(kind) {
        switch (kind) {
            case "song":         return "music"
            case "scripture":    return "book-2"
            case "image":        return "image"
            case "video":        return "video"
            case "presentation": return "presentation"
            default:             return "list"
        }
    }
}
