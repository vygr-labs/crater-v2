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

    // ── Theme selection ─────────────────────────────────────────────────
    // The operator picks a palette in Appearance > Theme. The chosen id is
    // persisted in SettingsService.themeMode (backward-compatible: the old
    // "dark" default is still a valid id). Valid values are any `id` in the
    // `themes` registry below, plus "auto" (follow the OS light/dark scheme).
    //
    // The whole mechanism is a single indirection: every one of the ~880
    // `Theme.color.<token>` reads across the app routes through `color`
    // (the active palette QtObject). Because `color` is a binding on
    // `activeTheme`, flipping the setting swaps the palette object and every
    // dependent binding re-evaluates live — no restart, and not one call
    // site changes. Same trick as `uiScale`. To add a theme: add a palette
    // QtObject below and one row to `themes`. Nothing else to wire.
    readonly property string themeName: SettingsService.themeMode

    // Live OS color scheme (Qt.ColorScheme.Light / .Dark / .Unknown, Qt 6.5+).
    // Bound as a property so `activeTheme` re-resolves when the OS flips.
    readonly property int osColorScheme: Qt.styleHints.colorScheme

    // The concrete resolved theme id — never "auto". Unknown OS scheme falls
    // back to dark (the safe default).
    readonly property string activeTheme:
        themeName === "auto"
            ? (osColorScheme === Qt.ColorScheme.Light ? "light" : "dark")
            : themeName

    // Registry the Appearance picker iterates over. `dark` marks whether the
    // palette is dark-on-light or light-on-dark (used only to render preview
    // swatches sensibly).
    readonly property var themes: [
        { id: "dark",     name: qsTr("Dark"),     dark: true  },
        { id: "light",    name: qsTr("Light"),    dark: false },
        { id: "midnight", name: qsTr("Midnight"), dark: true  }
    ]

    // Active palette. readonly binding on `activeTheme` → re-evaluates (and
    // thus every `Theme.color.*` consumer re-evaluates) whenever the theme or
    // the OS scheme changes.
    readonly property QtObject color: paletteFor(activeTheme)

    // Palette lookup by id. Used by `color` and by the Appearance swatches,
    // which must preview a palette that isn't currently active. Unknown id →
    // dark, so a stale/invalid persisted value degrades gracefully.
    function paletteFor(id) {
        switch (id) {
            case "light":    return _lightPalette
            case "midnight": return _midnightPalette
            default:         return _darkPalette
        }
    }

    // Resolve an id (following "auto") to whether it's a dark palette — for
    // preview rendering in the picker.
    function isDarkTheme(id) {
        var resolved = (id === "auto")
            ? (osColorScheme === Qt.ColorScheme.Light ? "light" : "dark")
            : id
        for (var i = 0; i < themes.length; i++)
            if (themes[i].id === resolved) return !!themes[i].dark
        return true
    }

    // ── Dark palette (default) ──────────────────────────────────────────
    readonly property QtObject _darkPalette: QtObject {
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
        // Selection wash for a row that's selected in a pane whose pane
        // doesn't currently own keyboard focus. Pure neutral gray (= `raised`
        // below) so the eye instantly reads "this row is selected but the
        // keys aren't pointed here." macOS Finder / Logic / Ableton
        // convention. Bound at row sites via gating like:
        //   color: _selected ? (_paneFocused ? brandSubtle : selectionUnfocused) : ...
        readonly property color selectionUnfocused: "#27272a"   // == raised
        // Channel-mute tokens — Preview gold and Live red desaturated for
        // when their panel doesn't currently own focus. Keep a hint of
        // channel identity (warm-tinted gray vs cool-tinted gray) so the
        // operator can still tell at a glance which channel a card belongs
        // to, but drop saturation enough that the brand color isn't
        // shouting from an unfocused panel.
        readonly property color previewMuted:  "#5a5345"   // desat warm gold-gray
        readonly property color liveMuted:     "#5a3a3a"   // desat maroon-gray
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

    // ── Light palette ───────────────────────────────────────────────────
    // The mirror of `_darkPalette`: same token names, inverted lightness.
    // Surfaces go light (page = light gray, panels = white, controls =
    // gray insets — elevation reads via borders/shadow rather than a
    // brighter fill, since you can't go brighter than white). Text goes
    // dark. Brand hue is preserved (deep teal reads well on white); only
    // its *subtle* wash flips from a deep tint to a pale one, and hover/
    // press darken (emphasis-on-light) instead of lightening. Broadcast +
    // schedule hues are deepened so they stay legible on light surfaces.
    readonly property QtObject _lightPalette: QtObject {
        readonly property color canvas:        "#f4f4f5"   // gray.100 — page
        readonly property color elevated:      "#ffffff"   // panel surface
        readonly property color raised:        "#e8e8eb"   // raised control fill
        readonly property color overlay:       "#ededf0"   // hover wash
        readonly property color borderSubtle:  "#e4e4e7"   // gray.200 — divider hairline
        readonly property color borderStrong:  "#c4c4cc"   // gray.300/400 — focused input border

        readonly property color bgSidebar:     "#efeff1"
        readonly property color bgContent:     "#f7f7f8"

        readonly property color bgMenu:        "#ffffff"   // white menu, lifted by border + shadow

        readonly property color textPrimary:   "#18181b"   // gray.900
        readonly property color textSecondary: "#52525b"   // gray.600
        readonly property color textTertiary:  "#71717a"   // gray.500
        readonly property color textDisabled:  "#a1a1aa"   // gray.400
        readonly property color textTitle:     "#27272a"   // gray.800

        // Brand hue preserved. Fill (`brand`) + ink identical to dark so the
        // primary button looks the same on both themes; hover/press darken.
        readonly property color brand:         "#1A767D"
        readonly property color brandHover:    "#135E64"   // darken = emphasis on light
        readonly property color brandPressed:  "#0E4A4F"
        readonly property color brandSubtle:   "#d6eef0"   // pale cyan — selected-row tint
        readonly property color brandInk:      "#0a1f25"   // unchanged (fill is unchanged)
        readonly property color selectionUnfocused: "#d9d9de"   // light gray — selected, pane unfocused
        readonly property color previewMuted:  "#c8bda6"   // desat warm gold-gray (light)
        readonly property color liveMuted:     "#d1b0ae"   // desat maroon-gray (light)
        readonly property color rowHoverBrand: Qt.rgba(26/255, 118/255, 125/255, 0.12)

        readonly property color live:          "#c0392b"   // crimson, legible on white
        readonly property color liveSubtle:    "#f7dcd9"   // pale red wash
        readonly property color preview:       "#b8863d"   // deeper champagne — legible on white
        readonly property color previewSubtle: "#f4ecd9"   // pale gold wash
        readonly property color goLive:        "#16a34a"   // deeper green for light bg
        readonly property color goLiveHover:   "#1eb257"
        readonly property color goLivePressed: "#12833c"
        readonly property color goLiveInk:     "#f0fff5"   // light ink on the deeper green fill
        readonly property color success:       "#15803d"
        readonly property color warning:       "#b45309"

        readonly property color typeSong:      "#b57f43"
        readonly property color typeScripture: "#2563cc"
        readonly property color typeSermon:    "#9333ea"
        readonly property color typeVideo:     "#15803d"
        readonly property color typeMedia:     "#b45309"
        readonly property color typeNote:      "#6b6b78"
    }

    // ── Midnight palette (OLED) ─────────────────────────────────────────
    // A deeper dark variant for OLED panels / low-light booths. Surfaces
    // drop to near-black (this theme opts *into* the pure-black look the
    // default dark theme avoids); text, brand, and broadcast/schedule hues
    // are carried over from dark unchanged, since they already read well on
    // black. Only the neutral surface/border stack and the unfocused-
    // selection gray shift down.
    readonly property QtObject _midnightPalette: QtObject {
        readonly property color canvas:        "#050507"
        readonly property color elevated:      "#0d0d10"
        readonly property color raised:        "#18181c"
        readonly property color overlay:       "#202024"
        readonly property color borderSubtle:  "#1c1c20"
        readonly property color borderStrong:  "#34343a"

        readonly property color bgSidebar:     "#0a0a0e"
        readonly property color bgContent:     "#0c0c10"

        readonly property color bgMenu:        "#141418"

        readonly property color textPrimary:   "#e4e4e7"
        readonly property color textSecondary: "#a1a1aa"
        readonly property color textTertiary:  "#71717a"
        readonly property color textDisabled:  "#52525b"
        readonly property color textTitle:     "#d4d4d8"

        readonly property color brand:         "#1A767D"
        readonly property color brandHover:    "#3AC8D4"
        readonly property color brandPressed:  "#135E64"
        readonly property color brandSubtle:   "#0E2528"
        readonly property color brandInk:      "#0a1f25"
        readonly property color selectionUnfocused: "#18181c"   // == raised
        readonly property color previewMuted:  "#5a5345"
        readonly property color liveMuted:     "#5a3a3a"
        readonly property color rowHoverBrand: Qt.rgba(26/255, 118/255, 125/255, 0.18)

        readonly property color live:          "#b13634"
        readonly property color liveSubtle:    "#2c0f0f"
        readonly property color preview:       "#cdb78e"
        readonly property color previewSubtle: "#2a2418"
        readonly property color goLive:        "#22c55e"
        readonly property color goLiveHover:   "#3ad273"
        readonly property color goLivePressed: "#1cae54"
        readonly property color goLiveInk:     "#0a1f10"
        readonly property color success:       "#4fc285"
        readonly property color warning:       "#f0b341"

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
        // Width of AppScrollBar's overlay lane. Scrollable views inset their
        // content by this so the bar rides the right gutter, not the content.
        readonly property int scrollBar:         14
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
            case "pdf":          return color.typeSermon   // PDFs commonly carry sermon notes — share the sermon tint
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
            case "pdf":          return "file-text"
            case "presentation": return "presentation"
            default:             return "list"
        }
    }
}
