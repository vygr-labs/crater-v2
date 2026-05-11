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
        "file-text":       "",
        "settings":        "",
        "arrow-up-right":  "",
        "list-ordered":    "",
        "menu":            "",
        "play":            "",

        // Panel headers
        "grid":            "",
        "eye":             "",
        "radio":           "",

        // Library tabs
        "music":           "",
        "book-open":       "",
        "film":            "",
        "palette":         "",

        // Library nav
        "folder":          "",
        "folders":         "",
        "heart":           "",

        // Inputs / actions
        "search":          "",
        "plus":            "",
        "x":               "",
        "check":           "",

        // Chevrons
        "chevron-down":    "",
        "chevron-up":      "",
        "chevron-left":    "",
        "chevron-right":   "",

        // Arrows
        "arrow-up":        "",
        "arrow-down":      "",
        "arrow-left":      "",
        "arrow-right":     "",

        // Status / feedback
        "circle":          "",
        "info":            "",
        "alert-triangle":  "",
        "alert-circle":    "",
        "loader":          "",

        // Editing / file
        "edit":            "",
        "trash":           "",
        "save":            "",
        "copy":            "",
        "download":        "",
        "upload":          "",
        "external-link":   "",

        // Output / display
        "monitor":         "",
        "tv":              "",
        "sun":             "",
        "moon":            "",
        "sliders":         "",
        "sparkles":        "",

        // Window chrome
        "maximize":        "",
        "minimize":        "",
        "more-horizontal": "",
        "more-vertical":   "",
        "grip-horizontal": "",
        "grip-vertical":   "",

        // People
        "user":            "",
        "users":           "",
        "home":            "",

        // Discovery
        "filter":          "",
        "tag":             "",
        "bookmark":        "",
        "book":            "",
        "refresh-cw":      ""
    })

    function get(name) {
        return map[name] !== undefined ? map[name] : ""
    }
}
