pragma Singleton

import QtQuick

QtObject {
    id: theme

    // ── Global UI scale ─────────────────────────────────────────────────
    // Every Theme.font.* and Theme.icon.* token multiplies its base value by
    // this scale, so a single property bumps the whole UI together. Bound
    // to SettingsService.fontScale (driven by the Appearance > Font size
    // S/M/L picker; 0.9 / 1.0 / 1.15 respectively). Setting this at
    // runtime re-evaluates every binding that reads through the tokens.
    //
    // Hardcoded font.pixelSize / size: values at call sites do NOT scale —
    // those are deliberate one-off pixel choices. Most app surface area
    // routes through the tokens, so the practical impact is small.
    property real uiScale: SettingsService.fontScale

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

        // Floating popover-menu surface. Sits one shade above `elevated`
        // (#18181b — the panel surface) so menus read as a level "up" from
        // panels rather than flush with them. A 1px `borderStrong` outline
        // + drop shadow keep the floating identity. Earlier values flirted
        // with `canvas`-adjacent (#111114) but that let menus visually
        // merge with the page beneath them; this value gives clear lift
        // without competing with the panel surfaces.
        readonly property color bgMenu:        "#1a1a1d"

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

        // Brand — Mixer Cyan. Promoted from the standalone `accent*` block
        // (Mixer Cyan was originally introduced as the C-Aperture logo color
        // only); the whole brand surface now tracks the mark, so chrome,
        // selection washes, focus outlines, and primary buttons all carry
        // this hue. Previously Radix Green (#227617) inherited from the
        // electron build. The "send it" Go Live affordance is intentionally
        // NOT in this block — see `goLive*` below; lime green stays the
        // traffic-light "go" semantic regardless of the platform brand.
        //
        // brandInk flipped to dark ink (#0a1f25) because cyan is a light
        // hue: white text on solid cyan is ~2.2:1 (fails AA Normal); dark
        // ink on the same surface is ~9.8:1 (AAA). Same reasoning as goLive's
        // dark ink on lime green.
        // Center stop deepened in two iterative steps from the mark-color
        // #3AC8D4 (luminance ~0.55) down to #1A767D (~0.18). The first
        // step (#218E96, ~0.28) still read as "too prominent" on solid-wash
        // surfaces because the eye's L/M/rod response peaks in the 480-510nm
        // cyan band, making cyan read brighter than its luminance number
        // suggests. The deep teal-cyan sits at a calmer perceived weight
        // while still clearly carrying brand identity. brandHover steps
        // back up to the mark color so hovering reads as a clear "lift";
        // the mark itself (qt/app/resources/brand/crater.svg) keeps its
        // own embedded #3AC8D4 — that's the logo-on-#111 chrome value,
        // deliberately brighter than the wash-surface value so the small
        // mark still pops at 16-32px on the titlebar.
        readonly property color brand:         "#1A767D"   // mixer cyan deep — primary
        readonly property color brandHover:    "#3AC8D4"   // lifts to the original mark color
        readonly property color brandPressed:  "#135E64"   // darker on press
        readonly property color brandSubtle:   "#0E2528"   // deep cyan wash — selected-row tint
        readonly property color brandInk:      "#0a1f25"   // dark ink on solid-brand button
        // brand at 18% alpha — the row-hover wash for library lists. RGB
        // updated to match the new deeper center. Alpha unchanged at 18%
        // (down from 30% in the Radix-green era — cyan reads heavier so
        // a lower alpha gives the same subjective subtlety).
        readonly property color rowHoverBrand: Qt.rgba(26/255, 118/255, 125/255, 0.18)

        // Broadcast semantics — these never get used decoratively.
        // Live — deep crimson. Carries dual semantics: the ON-AIR channel
        // state (LivePanel, Monitor, schedule live indicators) AND every
        // destructive/error UI in the app (Delete buttons, validation
        // failures, batch-delete chrome). Crimson keeps both reads: it's
        // unambiguously red for broadcast convention and destructive-UX
        // muscle memory, but tonally deep enough to pair with the champagne
        // preview without competing in saturation. Subtle variant follows
        // the same depth/saturation compression as `previewSubtle`.
        readonly property color live:          "#b13634"
        readonly property color liveSubtle:    "#2c0f0f"
        // Preview — pale champagne gold. Treats preview as a channel
        // state paired with live=red, but keeps the saturation low so the
        // staged card reads as dignified rather than alarming. Connects
        // to Crater's original warm-gold brand mark; native to worship
        // contexts (stage lighting, candles, scripture parchment).
        // Subtle variant mirrors `liveSubtle`'s tonal relationship.
        readonly property color preview:       "#cdb78e"
        readonly property color previewSubtle: "#2a2418"
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
        // Gated on SettingsService.reduceMotion — when the operator opts
        // out of motion (Appearance > Reduce motion), every Behavior /
        // NumberAnimation that reads through this token collapses to
        // duration 0, snapping rather than easing. We keep the binding
        // here (rather than at each Behavior call site) so the toggle is
        // a single source of truth.
        readonly property int instant: SettingsService.reduceMotion ? 0 : 120
        readonly property int normal:  SettingsService.reduceMotion ? 0 : 180
        readonly property int slow:    SettingsService.reduceMotion ? 0 : 240
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
