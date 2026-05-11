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
        "file-text":       "",
        "settings":        "",
        "arrow-up-right":  "",
        "list-ordered":    "",
        "menu":            "",
        "play":            "",

        // Panel headers
        "grid":            "",
        "eye":             "",
        "radio":           "",

        // Library tabs
        "music":           "",
        "book-open":       "",
        "film":            "",
        "palette":         "",

        // Library nav
        "folder":          "",
        "folders":         "",
        "heart":           "",

        // Inputs / actions
        "search":          "",
        "plus":            "",
        "x":               "",
        "check":           "",

        // Chevrons
        "chevron-down":    "",
        "chevron-up":      "",
        "chevron-left":    "",
        "chevron-right":   "",

        // Arrows
        "arrow-up":        "",
        "arrow-down":      "",
        "arrow-left":      "",
        "arrow-right":     "",

        // Status / feedback
        "circle":          "",
        "info":            "",
        "alert-triangle":  "",
        "alert-circle":    "",
        "loader":          "",

        // Editing / file
        "edit":            "",
        "trash":           "",
        "save":            "",
        "copy":            "",
        "download":        "",
        "upload":          "",
        "external-link":   "",

        // Output / display
        "monitor":         "",
        "tv":              "",
        "sun":             "",
        "moon":            "",
        "sliders":         "",
        "sparkles":        "",

        // Window chrome
        "maximize":        "",
        "minimize":        "",
        "more-horizontal": "",
        "more-vertical":   "",
        "grip-horizontal": "",
        "grip-vertical":   "",

        // People
        "user":            "",
        "users":           "",
        "home":            "",

        // Discovery
        "filter":          "",
        "tag":             "",
        "bookmark":        "",
        "book":            "",
        "refresh-cw":      "",

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

    function get(name) {
        return map[name] !== undefined ? map[name] : ""
    }
}
