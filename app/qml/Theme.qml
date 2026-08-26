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
        { id: "dark",           name: qsTr("Dark"),            dark: true  },
        { id: "light",          name: qsTr("Light"),           dark: false },
        { id: "midnight",       name: qsTr("Midnight"),        dark: true  },
        { id: "highContrast",   name: qsTr("High Contrast"),   dark: true  },
        { id: "dusk",           name: qsTr("Dusk"),            dark: true  },
        { id: "sepia",          name: qsTr("Sepia"),           dark: false },
        // Tier 2 — established third-party palettes
        { id: "nord",           name: qsTr("Nord"),            dark: true  },
        { id: "solarizedDark",  name: qsTr("Solarized Dark"),  dark: true  },
        { id: "solarizedLight", name: qsTr("Solarized Light"), dark: false },
        { id: "gruvbox",        name: qsTr("Gruvbox"),         dark: true  },
        { id: "dracula",        name: qsTr("Dracula"),         dark: true  },
        // Tier 3 — brand-hue variants of Dark
        { id: "royalPurple",    name: qsTr("Royal Purple"),    dark: true  },
        { id: "amber",          name: qsTr("Amber"),           dark: true  },
        { id: "ecclesialBlue",  name: qsTr("Ecclesial Blue"),  dark: true  }
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
            case "light":          return _lightPalette
            case "midnight":       return _midnightPalette
            case "highContrast":   return _highContrastPalette
            case "dusk":           return _duskPalette
            case "sepia":          return _sepiaPalette
            case "nord":           return _nordPalette
            case "solarizedDark":  return _solarizedDarkPalette
            case "solarizedLight": return _solarizedLightPalette
            case "gruvbox":        return _gruvboxPalette
            case "dracula":        return _draculaPalette
            case "royalPurple":    return _royalPurplePalette
            case "amber":          return _amberPalette
            case "ecclesialBlue":  return _ecclesialBluePalette
            default:               return _darkPalette
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
        // Production-cue card rails — the Preview/Live index column + header
        // band. Idle/hover are neutral insets a step off the card body; the
        // active state carries the channel tint (champagne for Preview,
        // crimson for Live). Split into tokens so the light palette can
        // invert them — these were hardcoded near-blacks that rendered as
        // dark bars on the white light-mode cards.
        readonly property color cueRailIdle:    "#1c1c20"
        readonly property color cueRailHover:   "#22222a"
        readonly property color cueRailPreview: "#4a3d28"   // active — warm gold
        readonly property color cueRailLive:    "#4d1918"   // active — deep crimson
        // Strong's interlinear language tags (the superscript ref numbers).
        // Blue = Hebrew, green = Greek. Themed so they stay legible on the
        // light reader surface — the dark values are too pale on white.
        readonly property color langHebrew:     "#60a5fa"
        readonly property color langGreek:      "#4ade80"
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
        // Cue rails inverted for light: neutral light-grays a step darker
        // than the card body (`raised`/`overlay`), and the active states a
        // deeper, more saturated tint than the pale channel washes so the
        // dark active digit reads and the L-frame still lifts.
        readonly property color cueRailIdle:    "#dadadf"
        readonly property color cueRailHover:   "#d5d5db"
        readonly property color cueRailPreview: "#e7d3a6"   // active — warm gold, deeper than previewSubtle
        readonly property color cueRailLive:    "#eec3bd"   // active — red, deeper than liveSubtle
        readonly property color langHebrew:     "#1d4ed8"   // deep blue, legible on white
        readonly property color langGreek:      "#15803d"   // deep green, legible on white
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
        // Cue rails — darker than midnight's `raised` (#18181c) so the frame
        // recedes; active tints carry over from dark (read fine on black).
        readonly property color cueRailIdle:    "#101014"
        readonly property color cueRailHover:   "#17171c"
        readonly property color cueRailPreview: "#4a3d28"
        readonly property color cueRailLive:    "#4d1918"
        readonly property color langHebrew:     "#60a5fa"
        readonly property color langGreek:      "#4ade80"
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

    // ── High Contrast palette (accessibility) ───────────────────────────
    // Not a mood — a capability. Pure-black surfaces, near-white text at
    // every tier (even textTertiary clears AA), 2px-worthy borders (border
    // stack pushed far brighter than the other darks so dividers/focus rings
    // are unmistakable), and maximally-saturated broadcast/accent hues. For
    // low-vision operators and for bright/sunlit rooms where the standard
    // Dark washes out. Brand flips to bright cyan-on-black with pure-black
    // ink so the primary button hits ~14:1. Every text tier and accent here
    // is chosen to clear WCAG AA (most clear AAA) on `canvas`.
    readonly property QtObject _highContrastPalette: QtObject {
        readonly property color canvas:        "#000000"
        readonly property color elevated:      "#0a0a0a"
        readonly property color raised:        "#1a1a1a"
        readonly property color overlay:       "#262626"   // hover wash — must be seen
        readonly property color borderSubtle:  "#6b6b6b"   // dividers pushed bright — visibility over subtlety
        readonly property color borderStrong:  "#ffffff"   // focus ring = pure white

        readonly property color bgSidebar:     "#000000"
        readonly property color bgContent:     "#050505"

        readonly property color bgMenu:        "#0d0d0d"

        readonly property color textPrimary:   "#ffffff"   // 21:1
        readonly property color textSecondary: "#e4e4e4"   // ~17:1 — kept bright, no gray dropout
        readonly property color textTertiary:  "#c2c2c2"   // ~12:1 — even tertiary stays legible
        readonly property color textDisabled:  "#8a8a8a"   // ~5.6:1 — disabled still readable
        readonly property color textTitle:     "#ffffff"

        // Bright cyan on black; black ink on the fill (~14:1). Hover lifts
        // brighter, press darkens. brandInk is pure black (the fill is a
        // light hue in every state here).
        readonly property color brand:         "#22d3ee"   // cyan.400
        readonly property color brandHover:    "#67e8f9"   // cyan.300
        readonly property color brandPressed:  "#06b6d4"   // cyan.500
        readonly property color brandSubtle:   "#0d4c52"   // deep cyan — selected row, white text clears AA
        readonly property color brandInk:      "#000000"   // black ink on bright-cyan fills
        readonly property color selectionUnfocused: "#3a3a3a"   // clearly-not-black neutral
        readonly property color cueRailIdle:    "#141414"
        readonly property color cueRailHover:   "#242424"
        readonly property color cueRailPreview: "#5c4a1e"   // active — saturated gold
        readonly property color cueRailLive:    "#5c1a18"   // active — saturated crimson
        readonly property color langHebrew:     "#67b0ff"   // bright blue
        readonly property color langGreek:      "#5ee88a"   // bright green
        readonly property color previewMuted:  "#8a7a4a"
        readonly property color liveMuted:     "#8a4a4a"
        readonly property color rowHoverBrand: Qt.rgba(34/255, 211/255, 238/255, 0.22)

        readonly property color live:          "#ff4d4d"   // bright red
        readonly property color liveSubtle:    "#3a0d0d"
        readonly property color preview:       "#e6c260"   // bright gold
        readonly property color previewSubtle: "#332a12"
        readonly property color goLive:        "#2ee66a"   // bright green
        readonly property color goLiveHover:   "#5cff8f"
        readonly property color goLivePressed: "#1fcc5a"
        readonly property color goLiveInk:     "#000000"
        readonly property color success:       "#3ae67f"
        readonly property color warning:       "#ffc93a"

        readonly property color typeSong:      "#ffc266"
        readonly property color typeScripture: "#66b0ff"
        readonly property color typeSermon:    "#d29bff"
        readonly property color typeVideo:     "#5ee88a"
        readonly property color typeMedia:     "#ffc93a"
        readonly property color typeNote:      "#c2c2c2"
    }

    // ── Dusk palette (warm low-blue dark) ───────────────────────────────
    // The warm sibling of Dark. Neutrals shift from blue-black to brown-black
    // and text is a warm off-white rather than cool gray — a low-blue-light
    // surface that preserves dark adaptation in a dim booth and is easier on
    // the eyes across a long rehearsal. Brand (cyan) and the go-live green
    // are intentionally NOT warmed: brand identity and the traffic-light "go"
    // semantic are fixed points. Warmth lives entirely in the neutral stack,
    // the text, and the broadcast red/gold — where it reinforces the
    // champagne-preview / crimson-live pairing rather than fighting it.
    readonly property QtObject _duskPalette: QtObject {
        readonly property color canvas:        "#14110d"   // warm near-black
        readonly property color elevated:      "#1c1813"
        readonly property color raised:        "#2a2419"
        readonly property color overlay:       "#2f281c"
        readonly property color borderSubtle:  "#2a2419"
        readonly property color borderStrong:  "#453b2a"

        readonly property color bgSidebar:     "#18140d"
        readonly property color bgContent:     "#1a160f"

        readonly property color bgMenu:        "#1f1a12"

        readonly property color textPrimary:   "#ede4d3"   // warm off-white — no clinical white glare
        readonly property color textSecondary: "#b5a892"
        readonly property color textTertiary:  "#8a7f6b"
        readonly property color textDisabled:  "#5f5747"
        readonly property color textTitle:     "#e0d6c3"

        // Brand carried over from Dark unchanged so brandInk (dark) stays
        // correct on the bright brandHover hover/selection fills.
        readonly property color brand:         "#1A767D"
        readonly property color brandHover:    "#3AC8D4"
        readonly property color brandPressed:  "#135E64"
        // Selected-row wash warmed off the cool deep-cyan the other darks use:
        // the brand teal nudged toward the warm-black surface so it reads as a
        // deep teal-green rather than a cold cyan patch. Same rationale as
        // Sepia — stays cool-family (clear of Preview-gold / Live-red) but sits
        // in the warm palette; the accent bar keeps full `brand` teal.
        // Pitched deeper/more saturated than a straight warm-nudge so the
        // FOCUSED selection out-reads `selectionUnfocused` (#2a2419) — an
        // earlier value sat below it and the active row looked fainter than an
        // inactive one.
        readonly property color brandSubtle:   "#173b31"
        readonly property color brandInk:      "#0a1f25"
        readonly property color selectionUnfocused: "#2a2419"   // == raised (warm)
        readonly property color cueRailIdle:    "#1a160f"
        readonly property color cueRailHover:   "#221c12"
        readonly property color cueRailPreview: "#4a3d28"   // warm gold — native to dusk
        readonly property color cueRailLive:    "#4d1918"
        readonly property color langHebrew:     "#60a5fa"
        readonly property color langGreek:      "#4ade80"
        readonly property color previewMuted:  "#5a5345"
        readonly property color liveMuted:     "#5a3a3a"
        readonly property color rowHoverBrand: Qt.rgba(26/255, 118/255, 125/255, 0.18)

        readonly property color live:          "#c14a42"   // warm-leaning crimson
        readonly property color liveSubtle:    "#301410"
        readonly property color preview:       "#d9bd85"   // warm champagne
        readonly property color previewSubtle: "#2e2617"
        readonly property color goLive:        "#22c55e"   // green stays semantic
        readonly property color goLiveHover:   "#3ad273"
        readonly property color goLivePressed: "#1cae54"
        readonly property color goLiveInk:     "#0a1f10"
        readonly property color success:       "#4fc285"
        readonly property color warning:       "#f0b341"

        readonly property color typeSong:      "#e0b073"
        readonly property color typeScripture: "#6fa8e6"
        readonly property color typeSermon:    "#c99cf0"
        readonly property color typeVideo:     "#6bbf8f"
        readonly property color typeMedia:     "#f0b341"
        readonly property color typeNote:      "#a89e88"
    }

    // ── Sepia palette (warm light / parchment) ──────────────────────────
    // The warm sibling of Light. Surfaces are warm parchment off-white
    // instead of clinical gray-white, text is a warm dark brown rather than
    // near-black — kinder for long scripture-reading sessions and a nod to
    // Crater's warm-gold heritage / scripture-parchment lineage (see the
    // brand notes in _darkPalette). Same inversion rules as Light: elevation
    // reads through borders/shadow, brand hue preserved (teal on cream),
    // hover/press darken, broadcast + schedule hues deepened for legibility
    // on a light surface.
    readonly property QtObject _sepiaPalette: QtObject {
        readonly property color canvas:        "#ebe3d0"   // parchment page
        readonly property color elevated:      "#f5efe0"   // panel — warm off-white
        readonly property color raised:        "#e2d8c0"
        readonly property color overlay:       "#e8dfc9"
        readonly property color borderSubtle:  "#d8cdb2"
        readonly property color borderStrong:  "#b8a988"

        readonly property color bgSidebar:     "#e6ddc8"
        readonly property color bgContent:     "#f0e9d8"

        readonly property color bgMenu:        "#f5efe0"

        readonly property color textPrimary:   "#3a3226"   // warm dark brown
        readonly property color textSecondary: "#5f5442"
        readonly property color textTertiary:  "#847661"
        readonly property color textDisabled:  "#a89a80"
        readonly property color textTitle:     "#2e2820"

        readonly property color brand:         "#1A767D"   // teal reads well on cream
        readonly property color brandHover:    "#135E64"   // darken = emphasis on light
        readonly property color brandPressed:  "#0E4A4F"
        // Selected-row wash. Kept in the cool/teal brand family (NOT warmed to
        // gold/tan) on purpose: a warm selection on parchment drifts toward the
        // Preview-gold / Warning-amber hues and starts reading as channel state
        // rather than "selected." But the pale mint clashed on cream, so this is
        // the brand teal dissolved ~18% into the parchment canvas — a muted sage
        // that belongs on the surface. The 2px selected-row accent bar stays
        // full `brand` teal to carry brand identity.
        readonly property color brandSubtle:   "#c5cfc1"   // brand-in-parchment — sage selection wash
        readonly property color brandInk:      "#0a1f25"
        readonly property color selectionUnfocused: "#ddd2ba"   // warm gray — selected, unfocused
        readonly property color cueRailIdle:    "#ddd2b8"
        readonly property color cueRailHover:   "#d6cab0"
        readonly property color cueRailPreview: "#e4cf9a"   // active — deeper gold
        readonly property color cueRailLive:    "#e8bcae"   // active — deeper red
        readonly property color langHebrew:     "#1d4ed8"   // deep blue on cream
        readonly property color langGreek:      "#15803d"   // deep green on cream
        readonly property color previewMuted:  "#c2b184"
        readonly property color liveMuted:     "#cba9a0"
        readonly property color rowHoverBrand: Qt.rgba(26/255, 118/255, 125/255, 0.12)

        readonly property color live:          "#b23a2c"   // crimson, legible on cream
        readonly property color liveSubtle:    "#f0d9d0"
        readonly property color preview:       "#a6742f"   // deep amber, legible on cream
        readonly property color previewSubtle: "#f0e4c8"
        readonly property color goLive:        "#16a34a"   // deeper green for light bg
        readonly property color goLiveHover:   "#1eb257"
        readonly property color goLivePressed: "#12833c"
        readonly property color goLiveInk:     "#f0fff5"
        readonly property color success:       "#15803d"
        readonly property color warning:       "#b45309"

        readonly property color typeSong:      "#9c6b32"
        readonly property color typeScripture: "#2563cc"
        readonly property color typeSermon:    "#8b30d9"
        readonly property color typeVideo:     "#15803d"
        readonly property color typeMedia:     "#a15c08"
        readonly property color typeNote:      "#6b6152"
    }

    // ════════════════════════════════════════════════════════════════════
    //  Tier 2 — established third-party palettes
    //  Faithful ports of well-known editor themes. Each keeps its own
    //  neutral stack and text ramp; only the *broadcast* semantics (live =
    //  red, goLive = green, preview = warm) and the contrast-aware primary
    //  ink are held fixed so the console still reads the same regardless of
    //  skin. brandInk stays a DARK ink in every palette: PrimaryButton auto-
    //  picks white on a deep brand fill (hslLightness < 0.45) and only falls
    //  back to brandInk on a bright fill (the brand or its brandHover) — so
    //  each brand/brandHover is pushed clear of the ~0.45 mushy middle.
    // ════════════════════════════════════════════════════════════════════

    // ── Nord (arctic, blue-gray dark) ───────────────────────────────────
    // Polar Night surfaces + Snow Storm text + a Frost cyan brand (nord8).
    // Frost is a *light* hue, so the primary button carries dark ink on it.
    // Aurora supplies the broadcast/schedule accents (red/yellow/green/
    // orange/purple).
    readonly property QtObject _nordPalette: QtObject {
        readonly property color canvas:        "#2e3440"   // nord0
        readonly property color elevated:      "#333a47"
        readonly property color raised:        "#3b4252"   // nord1
        readonly property color overlay:       "#434c5e"   // nord2 — hover wash
        readonly property color borderSubtle:  "#3b4252"   // nord1
        readonly property color borderStrong:  "#4c566a"   // nord3
        readonly property color bgSidebar:     "#2b303b"
        readonly property color bgContent:     "#2e3440"
        readonly property color bgMenu:        "#373e4c"
        readonly property color textPrimary:   "#eceff4"   // nord6
        readonly property color textSecondary: "#d8dee9"   // nord4
        readonly property color textTertiary:  "#8b97ac"
        readonly property color textDisabled:  "#667085"
        readonly property color textTitle:     "#e5e9f0"   // nord5
        readonly property color brand:         "#88c0d0"   // nord8 frost — light hue → dark ink
        readonly property color brandHover:    "#9fd0dd"
        readonly property color brandPressed:  "#6ba3b5"
        readonly property color brandSubtle:   "#35505a"   // deep frost wash — selected row
        readonly property color brandInk:      "#1c2a30"
        readonly property color selectionUnfocused: "#3b4252"   // == nord1
        readonly property color cueRailIdle:    "#333a47"
        readonly property color cueRailHover:   "#3d4552"
        readonly property color cueRailPreview: "#4d4531"
        readonly property color cueRailLive:    "#4d2f33"
        readonly property color langHebrew:     "#81a1c1"   // nord9
        readonly property color langGreek:      "#a3be8c"   // nord14
        readonly property color previewMuted:  "#6b6353"
        readonly property color liveMuted:     "#6b4a4e"
        readonly property color rowHoverBrand: Qt.rgba(136/255, 192/255, 208/255, 0.14)
        readonly property color live:          "#bf616a"   // nord11
        readonly property color liveSubtle:    "#3a2427"
        readonly property color preview:       "#ebcb8b"   // nord13
        readonly property color previewSubtle: "#3a3323"
        readonly property color goLive:        "#a3be8c"   // nord14 — light green → dark ink
        readonly property color goLiveHover:   "#b5cca0"
        readonly property color goLivePressed: "#8fac78"
        readonly property color goLiveInk:     "#1a2416"
        readonly property color success:       "#a3be8c"
        readonly property color warning:       "#ebcb8b"
        readonly property color typeSong:      "#d08770"   // nord12
        readonly property color typeScripture: "#81a1c1"   // nord9
        readonly property color typeSermon:    "#b48ead"   // nord15
        readonly property color typeVideo:     "#a3be8c"   // nord14
        readonly property color typeMedia:     "#ebcb8b"   // nord13
        readonly property color typeNote:      "#9aa5b8"
    }

    // ── Solarized Dark (Ethan Schoonover) ───────────────────────────────
    // base03 surfaces + base0/base1 text. Brand is Solarized cyan (deep
    // enough for white auto-ink, and it keeps Crater's teal identity). The
    // whole neutral stack is teal-tinted, so the selection wash is pushed to
    // a brighter, more saturated cyan to still read against it.
    readonly property QtObject _solarizedDarkPalette: QtObject {
        readonly property color canvas:        "#002b36"   // base03
        readonly property color elevated:      "#073642"   // base02
        readonly property color raised:        "#0a4653"
        readonly property color overlay:       "#0e4d5b"
        readonly property color borderSubtle:  "#073642"   // base02
        readonly property color borderStrong:  "#17505d"
        readonly property color bgSidebar:     "#00252e"
        readonly property color bgContent:     "#002b36"
        readonly property color bgMenu:        "#063a46"
        readonly property color textPrimary:   "#a7b3b3"
        readonly property color textSecondary: "#839496"   // base0
        readonly property color textTertiary:  "#657b83"   // base00
        readonly property color textDisabled:  "#495a60"
        readonly property color textTitle:     "#c1cbca"
        readonly property color brand:         "#2aa198"   // cyan — deep → white auto-ink
        readonly property color brandHover:    "#3cb9af"
        readonly property color brandPressed:  "#1f8177"
        readonly property color brandSubtle:   "#155c54"   // brighter cyan wash over the teal neutrals
        readonly property color brandInk:      "#002b30"
        readonly property color selectionUnfocused: "#0f4e56"
        readonly property color cueRailIdle:    "#063a46"
        readonly property color cueRailHover:   "#0a4653"
        readonly property color cueRailPreview: "#3f3a1a"
        readonly property color cueRailLive:    "#45201f"
        readonly property color langHebrew:     "#268bd2"   // blue
        readonly property color langGreek:      "#859900"   // green
        readonly property color previewMuted:  "#6b6440"
        readonly property color liveMuted:     "#6b4340"
        readonly property color rowHoverBrand: Qt.rgba(42/255, 161/255, 152/255, 0.16)
        readonly property color live:          "#dc322f"   // red
        readonly property color liveSubtle:    "#3a1615"
        readonly property color preview:       "#c49a2e"   // yellow, lifted for card legibility
        readonly property color previewSubtle: "#332c12"
        readonly property color goLive:        "#859900"   // green — dark olive → light ink
        readonly property color goLiveHover:   "#96ab0a"
        readonly property color goLivePressed: "#6f8000"
        readonly property color goLiveInk:     "#f2f7e2"
        readonly property color success:       "#859900"
        readonly property color warning:       "#b58900"
        readonly property color typeSong:      "#cb4b16"   // orange
        readonly property color typeScripture: "#268bd2"   // blue
        readonly property color typeSermon:    "#6c71c4"   // violet
        readonly property color typeVideo:     "#859900"   // green
        readonly property color typeMedia:     "#b58900"   // yellow
        readonly property color typeNote:      "#839496"   // base0
    }

    // ── Solarized Light (Ethan Schoonover) ──────────────────────────────
    // base3 parchment surfaces + base01/base02 text. Same cyan brand as the
    // dark variant (deep teal reads well on cream); hover/press darken for
    // emphasis-on-light, and the selection wash flips to a pale sage-cyan.
    readonly property QtObject _solarizedLightPalette: QtObject {
        readonly property color canvas:        "#eee8d5"   // base2
        readonly property color elevated:      "#fdf6e3"   // base3
        readonly property color raised:        "#e6dfc8"
        readonly property color overlay:       "#e9e2cc"
        readonly property color borderSubtle:  "#ddd6c1"
        readonly property color borderStrong:  "#c4bda8"
        readonly property color bgSidebar:     "#e9e3cf"
        readonly property color bgContent:     "#f5eeda"
        readonly property color bgMenu:        "#fdf6e3"
        readonly property color textPrimary:   "#3d4d4a"
        readonly property color textSecondary: "#586e75"   // base01
        readonly property color textTertiary:  "#7d8c8c"
        readonly property color textDisabled:  "#a8b3ac"
        readonly property color textTitle:     "#002b36"   // base03
        readonly property color brand:         "#2aa198"   // cyan — deep → white auto-ink
        readonly property color brandHover:    "#1f8177"   // darken = emphasis on light
        readonly property color brandPressed:  "#196a62"
        readonly property color brandSubtle:   "#cfe4de"   // pale sage-cyan selection wash
        readonly property color brandInk:      "#002b30"
        readonly property color selectionUnfocused: "#ddd6c1"
        readonly property color cueRailIdle:    "#e2dbc5"
        readonly property color cueRailHover:   "#dcd5be"
        readonly property color cueRailPreview: "#e8d7a0"
        readonly property color cueRailLive:    "#ecc9b5"
        readonly property color langHebrew:     "#268bd2"   // blue
        readonly property color langGreek:      "#5b7300"   // deep green on cream
        readonly property color previewMuted:  "#b3a778"
        readonly property color liveMuted:     "#c2a29a"
        readonly property color rowHoverBrand: Qt.rgba(42/255, 161/255, 152/255, 0.12)
        readonly property color live:          "#cb2f2c"   // red, legible on cream
        readonly property color liveSubtle:    "#f2dcd6"
        readonly property color preview:       "#a97e12"   // deep gold on cream
        readonly property color previewSubtle: "#f2e8c8"
        readonly property color goLive:        "#6a8000"   // deep olive green for cream
        readonly property color goLiveHover:   "#789000"
        readonly property color goLivePressed: "#566800"
        readonly property color goLiveInk:     "#f2f7e2"
        readonly property color success:       "#5b7300"
        readonly property color warning:       "#b58900"
        readonly property color typeSong:      "#b5551a"   // orange, deeper
        readonly property color typeScripture: "#1f6fb0"   // blue, deeper
        readonly property color typeSermon:    "#5559b0"   // violet, deeper
        readonly property color typeVideo:     "#5b7300"   // green
        readonly property color typeMedia:     "#a97e12"   // gold
        readonly property color typeNote:      "#6c7a7a"
    }

    // ── Gruvbox (retro warm dark) ───────────────────────────────────────
    // bg0/bg1 surfaces + fg1 warm-cream text. Brand is Gruvbox's muted
    // blue-teal (#458588) — deep enough for white auto-ink and closest in
    // spirit to Crater's teal. Bright Gruvbox accents drive broadcast +
    // schedule tints.
    readonly property QtObject _gruvboxPalette: QtObject {
        readonly property color canvas:        "#282828"   // bg0
        readonly property color elevated:      "#32302f"   // bg0_s
        readonly property color raised:        "#3c3836"   // bg1
        readonly property color overlay:       "#504945"   // bg2 — hover wash
        readonly property color borderSubtle:  "#3c3836"   // bg1
        readonly property color borderStrong:  "#504945"   // bg2
        readonly property color bgSidebar:     "#242423"
        readonly property color bgContent:     "#282828"
        readonly property color bgMenu:        "#363433"
        readonly property color textPrimary:   "#ebdbb2"   // fg1
        readonly property color textSecondary: "#d5c4a1"   // fg2
        readonly property color textTertiary:  "#a89984"   // fg4
        readonly property color textDisabled:  "#7c6f64"   // bg4
        readonly property color textTitle:     "#fbf1c7"   // fg0
        readonly property color brand:         "#458588"   // gruvbox blue/teal — deep → white auto-ink
        readonly property color brandHover:    "#83a598"   // gruvbox bright blue lift
        readonly property color brandPressed:  "#366b6e"
        readonly property color brandSubtle:   "#2f4442"   // deep teal wash — selected row
        readonly property color brandInk:      "#16211f"
        readonly property color selectionUnfocused: "#3c3836"   // == bg1
        readonly property color cueRailIdle:    "#333130"
        readonly property color cueRailHover:   "#3c3836"
        readonly property color cueRailPreview: "#4a3f24"
        readonly property color cueRailLive:    "#4a2620"
        readonly property color langHebrew:     "#83a598"   // bright blue
        readonly property color langGreek:      "#b8bb26"   // bright green
        readonly property color previewMuted:  "#6b5f42"
        readonly property color liveMuted:     "#6b4038"
        readonly property color rowHoverBrand: Qt.rgba(69/255, 133/255, 136/255, 0.18)
        readonly property color live:          "#fb4934"   // bright red
        readonly property color liveSubtle:    "#3a1a15"
        readonly property color preview:       "#fabd2f"   // bright yellow-gold
        readonly property color previewSubtle: "#3a2f14"
        readonly property color goLive:        "#b8bb26"   // bright lime — light → dark ink
        readonly property color goLiveHover:   "#c9cc3a"
        readonly property color goLivePressed: "#9a9d1e"
        readonly property color goLiveInk:     "#1e2410"
        readonly property color success:       "#b8bb26"
        readonly property color warning:       "#fabd2f"
        readonly property color typeSong:      "#fe8019"   // orange
        readonly property color typeScripture: "#83a598"   // blue
        readonly property color typeSermon:    "#d3869b"   // purple
        readonly property color typeVideo:     "#8ec07c"   // aqua
        readonly property color typeMedia:     "#fabd2f"   // yellow
        readonly property color typeNote:      "#a89984"   // fg4
    }

    // ── Dracula (vibrant purple dark) ───────────────────────────────────
    // #282a36 surfaces + #f8f8f2 text + the signature purple brand (#bd93f9,
    // a light hue → dark ink). Dracula's own selection color (#44475a) is
    // reused verbatim for the unfocused-selection gray.
    readonly property QtObject _draculaPalette: QtObject {
        readonly property color canvas:        "#282a36"   // background
        readonly property color elevated:      "#2f3240"
        readonly property color raised:        "#383b4a"
        readonly property color overlay:       "#3e4154"   // hover wash
        readonly property color borderSubtle:  "#383b4a"
        readonly property color borderStrong:  "#4d5066"
        readonly property color bgSidebar:     "#24262f"
        readonly property color bgContent:     "#282a36"
        readonly property color bgMenu:        "#343746"
        readonly property color textPrimary:   "#f8f8f2"   // foreground
        readonly property color textSecondary: "#b8bcd0"
        readonly property color textTertiary:  "#8b8fb0"
        readonly property color textDisabled:  "#6272a4"   // comment
        readonly property color textTitle:     "#ffffff"
        readonly property color brand:         "#bd93f9"   // purple — light hue → dark ink
        readonly property color brandHover:    "#cbaafb"
        readonly property color brandPressed:  "#a577e8"
        readonly property color brandSubtle:   "#3d3357"   // deep purple wash — selected row
        readonly property color brandInk:      "#1e1630"
        readonly property color selectionUnfocused: "#44475a"   // Dracula's own selection color
        readonly property color cueRailIdle:    "#313442"
        readonly property color cueRailHover:   "#3a3d4d"
        readonly property color cueRailPreview: "#4a4326"
        readonly property color cueRailLive:    "#4a2630"
        readonly property color langHebrew:     "#8be9fd"   // cyan
        readonly property color langGreek:      "#50fa7b"   // green
        readonly property color previewMuted:  "#6b6452"
        readonly property color liveMuted:     "#6b4550"
        readonly property color rowHoverBrand: Qt.rgba(189/255, 147/255, 249/255, 0.14)
        readonly property color live:          "#ff5555"   // red
        readonly property color liveSubtle:    "#3d1c1c"
        readonly property color preview:       "#f1fa8c"   // yellow
        readonly property color previewSubtle: "#35371c"
        readonly property color goLive:        "#50fa7b"   // green — light → dark ink
        readonly property color goLiveHover:   "#6ffb92"
        readonly property color goLivePressed: "#3ee066"
        readonly property color goLiveInk:     "#0d2614"
        readonly property color success:       "#50fa7b"
        readonly property color warning:       "#ffb86c"   // orange
        readonly property color typeSong:      "#ffb86c"   // orange
        readonly property color typeScripture: "#8be9fd"   // cyan
        readonly property color typeSermon:    "#bd93f9"   // purple
        readonly property color typeVideo:     "#50fa7b"   // green
        readonly property color typeMedia:     "#f1fa8c"   // yellow
        readonly property color typeNote:      "#6272a4"   // comment
    }

    // ════════════════════════════════════════════════════════════════════
    //  Tier 3 — brand-hue variants of Dark
    //  These keep Dark's exact neutral stack, text ramp, broadcast, and
    //  schedule tints, and swap ONLY the brand family (brand / brandHover /
    //  brandPressed / brandSubtle / brandInk / rowHoverBrand). The brand is
    //  chosen deep enough (hslLightness < 0.45) that the primary button
    //  auto-picks white ink on it; brandHover lifts to a bright tint so the
    //  ink flips to the dark brandInk on hover — the same white→dark flip the
    //  default Dark theme already does with its cyan brand.
    // ════════════════════════════════════════════════════════════════════

    // ── Royal Purple ────────────────────────────────────────────────────
    // Deep violet brand (violet-800) on Dark's neutrals. There's a mild hue
    // kinship with the purple `typeSermon` schedule tag, but they never share
    // a surface (chrome/selection vs a small list tag), so the reads stay
    // separable.
    readonly property QtObject _royalPurplePalette: QtObject {
        readonly property color canvas:        "#111111"
        readonly property color elevated:      "#18181b"
        readonly property color raised:        "#27272a"
        readonly property color overlay:       "#2a2a28"
        readonly property color borderSubtle:  "#27272a"
        readonly property color borderStrong:  "#3f3f46"
        readonly property color bgSidebar:     "#14141a"
        readonly property color bgContent:     "#16161a"
        readonly property color bgMenu:        "#1a1a1d"
        readonly property color textPrimary:   "#e4e4e7"
        readonly property color textSecondary: "#a1a1aa"
        readonly property color textTertiary:  "#71717a"
        readonly property color textDisabled:  "#52525b"
        readonly property color textTitle:     "#d4d4d8"
        readonly property color brand:         "#5b21b6"   // violet-800 — deep → white auto-ink
        readonly property color brandHover:    "#a78bfa"   // violet-400 bright lift → dark ink
        readonly property color brandPressed:  "#4c1d95"   // violet-900
        readonly property color brandSubtle:   "#2c2148"   // deep violet wash — selected row
        readonly property color brandInk:      "#1c1030"
        readonly property color selectionUnfocused: "#27272a"
        readonly property color cueRailIdle:    "#1c1c20"
        readonly property color cueRailHover:   "#22222a"
        readonly property color cueRailPreview: "#4a3d28"
        readonly property color cueRailLive:    "#4d1918"
        readonly property color langHebrew:     "#60a5fa"
        readonly property color langGreek:      "#4ade80"
        readonly property color previewMuted:  "#5a5345"
        readonly property color liveMuted:     "#5a3a3a"
        readonly property color rowHoverBrand: Qt.rgba(139/255, 92/255, 246/255, 0.16)
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

    // ── Amber / Gold ────────────────────────────────────────────────────
    // Rich goldenrod brand on Dark's neutrals — the warmest variant, and the
    // one with the most semantic tension: the gold selection accent shares a
    // temperature with Preview champagne, Warning amber, and the song/media
    // schedule tags. Kept deliberately deeper and more saturated than the
    // pale champagne Preview so the *selection* read stays distinct, but this
    // is the Tier-3 variant to drop first if the warm hues start to blur.
    readonly property QtObject _amberPalette: QtObject {
        readonly property color canvas:        "#111111"
        readonly property color elevated:      "#18181b"
        readonly property color raised:        "#27272a"
        readonly property color overlay:       "#2a2a28"
        readonly property color borderSubtle:  "#27272a"
        readonly property color borderStrong:  "#3f3f46"
        readonly property color bgSidebar:     "#14141a"
        readonly property color bgContent:     "#16161a"
        readonly property color bgMenu:        "#1a1a1d"
        readonly property color textPrimary:   "#e4e4e7"
        readonly property color textSecondary: "#a1a1aa"
        readonly property color textTertiary:  "#71717a"
        readonly property color textDisabled:  "#52525b"
        readonly property color textTitle:     "#d4d4d8"
        readonly property color brand:         "#d4a017"   // goldenrod — light → dark ink
        readonly property color brandHover:    "#eab308"   // amber-500 bright lift
        readonly property color brandPressed:  "#a67d0f"
        readonly property color brandSubtle:   "#3d3115"   // deep amber wash — selected row
        readonly property color brandInk:      "#241a02"
        readonly property color selectionUnfocused: "#27272a"
        readonly property color cueRailIdle:    "#1c1c20"
        readonly property color cueRailHover:   "#22222a"
        readonly property color cueRailPreview: "#4a3d28"
        readonly property color cueRailLive:    "#4d1918"
        readonly property color langHebrew:     "#60a5fa"
        readonly property color langGreek:      "#4ade80"
        readonly property color previewMuted:  "#5a5345"
        readonly property color liveMuted:     "#5a3a3a"
        readonly property color rowHoverBrand: Qt.rgba(212/255, 160/255, 23/255, 0.16)
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

    // ── Ecclesial Blue ──────────────────────────────────────────────────
    // Deep royal-blue brand (blue-800) on Dark's neutrals — a calm, liturgical
    // blue. brandHover lifts to blue-400; that light blue coincides with the
    // langHebrew / scripture blues, but again never on the same surface.
    readonly property QtObject _ecclesialBluePalette: QtObject {
        readonly property color canvas:        "#111111"
        readonly property color elevated:      "#18181b"
        readonly property color raised:        "#27272a"
        readonly property color overlay:       "#2a2a28"
        readonly property color borderSubtle:  "#27272a"
        readonly property color borderStrong:  "#3f3f46"
        readonly property color bgSidebar:     "#14141a"
        readonly property color bgContent:     "#16161a"
        readonly property color bgMenu:        "#1a1a1d"
        readonly property color textPrimary:   "#e4e4e7"
        readonly property color textSecondary: "#a1a1aa"
        readonly property color textTertiary:  "#71717a"
        readonly property color textDisabled:  "#52525b"
        readonly property color textTitle:     "#d4d4d8"
        readonly property color brand:         "#1e40af"   // blue-800 — deep → white auto-ink
        readonly property color brandHover:    "#60a5fa"   // blue-400 bright lift → dark ink
        readonly property color brandPressed:  "#1e3a8a"   // blue-900
        readonly property color brandSubtle:   "#182a4d"   // deep blue wash — selected row
        readonly property color brandInk:      "#0b1633"
        readonly property color selectionUnfocused: "#27272a"
        readonly property color cueRailIdle:    "#1c1c20"
        readonly property color cueRailHover:   "#22222a"
        readonly property color cueRailPreview: "#4a3d28"
        readonly property color cueRailLive:    "#4d1918"
        readonly property color langHebrew:     "#60a5fa"
        readonly property color langGreek:      "#4ade80"
        readonly property color previewMuted:  "#5a5345"
        readonly property color liveMuted:     "#5a3a3a"
        readonly property color rowHoverBrand: Qt.rgba(59/255, 130/255, 246/255, 0.16)
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
        // How far one arrow-button tick scrolls, in CONTENT PIXELS. Roughly
        // one schedule row plus its gap — small enough to land on the row you
        // meant, large enough that holding the button still covers ground.
        // AppScrollBar converts it into the fraction-of-content units
        // ScrollBar.stepSize actually wants; expressing it in pixels here is
        // what keeps a tick the same physical distance in a 12-row list and a
        // 12000-verse one.
        readonly property int scrollStep:        48
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
