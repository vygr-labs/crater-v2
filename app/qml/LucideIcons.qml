pragma Singleton

import QtQuick

// Lucide icon name → unicode codepoint mapping.
//
// The full Lucide font (~1500 icons) is bundled at qrc:/fonts/lucide.ttf
// and registered as font family "lucide" in main.cpp. To use any Lucide
// icon, add its name → codepoint here and reference via AppIcon.
//
// Codepoints sourced from lucide.css (shipped alongside the .ttf at
// qt/app/resources/fonts/lucide.css). To add an icon, grep that file for
// `.icon-<name>::before` and copy the `\eXXX` value here as `"\ueXXX"`.
QtObject {
    readonly property string fontFamily: "lucide"

    readonly property var map: ({
        // Top bar / chrome
        "file-text":       "\ue0cc",
        "settings":        "\ue154",
        "arrow-up-right":  "\ue04d",
        "list-ordered":    "\ue1d1",
        "menu":            "\ue115",
        "play":            "\ue13c",

        // Panel headers
        "grid":            "\ue0e9",
        "eye":             "\ue0ba",
        "radio":           "\ue142",

        // Library tabs
        "music":           "\ue122",
        "book-open":       "\ue05f",
        "film":            "\ue0d0",
        "palette":         "\ue1dd",

        // Library nav
        "folder":          "\ue0d7",
        "folders":         "\ue33f",
        "heart":           "\ue0f2",

        // Inputs / actions
        "search":          "\ue151",
        "plus":            "\ue13d",
        "x":               "\ue1b2",
        "check":           "\ue06c",

        // Chevrons
        "chevron-down":    "\ue06d",
        "chevron-up":      "\ue070",
        "chevron-left":    "\ue06e",
        "chevron-right":   "\ue06f",

        // Arrows
        "arrow-up":        "\ue04a",
        "arrow-down":      "\ue042",
        "arrow-left":      "\ue048",
        "arrow-right":     "\ue049",

        // Status / feedback
        "circle":          "\ue076",
        "info":            "\ue0f9",
        "alert-triangle":  "\ue193",
        "alert-circle":    "\ue077",
        "loader":          "\ue109",

        // Editing / file
        "edit":            "\ue172",
        "trash":           "\ue18d",
        "save":            "\ue14d",
        "copy":            "\ue09e",
        "download":        "\ue0b2",
        "upload":          "\ue19e",
        "external-link":   "\ue0b9",

        // Output / display
        "monitor":         "\ue11d",
        "tv":              "\ue195",
        "sun":             "\ue178",
        "moon":            "\ue11e",
        "sliders":         "\ue162",
        "sparkles":        "\ue412",

        // Window chrome
        "maximize":        "\ue112",
        "minimize":        "\ue11a",
        "more-horizontal": "\ue0b6",
        "more-vertical":   "\ue0b7",
        "grip-horizontal": "\ue0ea",
        "grip-vertical":   "\ue0eb",

        // People
        "user":            "\ue19f",
        "users":           "\ue1a4",
        "home":            "\ue0f5",

        // Discovery
        "filter":          "\ue0dc",
        "tag":             "\ue17f",
        "bookmark":        "\ue060",
        "book":            "\ue05e",
        "refresh-cw":      "\ue145",

        // Library tab additions (added when porting Electron UX) — these use
        // the \uXXXX escape form rather than literal PUA chars so they are
        // greppable and safe across encodings. Codepoints from lucide.css.
        "user-circle":        "",
        "clock":              "",
        "sort-asc":           "",
        "sort-desc":          "",
        "arrow-down-az":      "",
        "arrow-up-az":        "",
        "layout-grid":        "",
        "layout-list":        "",
        "list":               "",
        "grid-2x2":           "",
        "grid-3x3":           "",
        "grip":               "",

        // Scripture / book variants
        "book-2":             "",
        "book-text":          "",
        "book-marked":        "",
        "book-open-text":     "",
        "book-x":             "",
        "library":            "",
        "library-big":        "",
        "tree-pine":          "",

        // Media
        "image":              "",
        "image-off":          "",
        "images":             "",
        "video":              "",
        "video-off":          "",
        "cloud":              "",
        "cloud-upload":       "",
        "cloud-off":          "",
        "star":               "",
        "frame":              "",
        "expand":             "",

        // Editing / misc
        "edit-2":             "",
        "edit-3":             "",
        "pencil":             "",
        "trash-2":            "",
        "heart-off":          "",
        "search-x":           "",
        "minus":              "",
        "disc":               "",
        "disc-3":             "",
        "swatch-book":        "",
        "sliders-horizontal": "",
        "cast":               "",
        "antenna":            "",
        "signal":             "",
        "paint-bucket":       "",
        "tags":               "",
        "loader-circle":      ""
    })

    // ── Theme-editor icons (canvas + toolbar + properties panel) ─────────
    // Layered on top of `map` so we don't fight with the editor's display
    // sanitization of PUA characters embedded in literal strings (which
    // makes some entries above look empty even though they aren't). New
    // entries use \uXXXX escapes for greppability + cross-encoding safety.
    // Codepoints come from qt/app/resources/fonts/lucide.css.
    readonly property var themeEditorMap: ({
        "type":                    "",   // text node icon
        "square":                  "",   // container node icon
        "lock":                    "",
        "unlock":                  "",
        "undo":                    "",
        "redo":                    "",
        "align-left":              "",
        "align-center":            "",
        "align-right":             "",
        "align-start-horizontal":  "",   // align tops
        "align-center-horizontal": "",   // align middles
        "align-end-horizontal":    "",   // align bottoms
        "align-start-vertical":    "",   // align lefts
        "align-center-vertical":   "",   // align centers
        "align-end-vertical":      "",   // align rights
        "bring-to-front":          "",
        "send-to-back":            "",
        "zoom-in":                 "",
        "zoom-out":                "",
        "maximize-2":              "",
        "minimize-2":              "",
        "move":                    "",
        "eye-off":                 "",
        "chevrons-up":             "",
        "chevrons-down":           "",
        "crop":                    "",
        "droplet":                 "",
        "pipette":                 "",
        "paintbrush":              "",
        "rotate-ccw":              "",
        "rotate-cw":               ""
    })

    function get(name) {
        if (themeEditorMap[name] !== undefined) return themeEditorMap[name]
        return map[name] !== undefined ? map[name] : ""
    }
}
