pragma Singleton

import QtQuick

// Workspace presets and panel metadata.
//
// A workspace is a recursive tree of `row`/`column` containers and `panel`
// leaves. Every panel `id` here is also a key in `Main.qml`'s panelRegistry,
// which maps the id to a QML Component.
//
// Sizes are pixel hints for the panel's extent in its parent's direction
// (width for row children, height for column children). `stretch: true`
// claims any remaining space. `fixed: true` disables resizing.
//
// User-saved workspaces will live alongside these presets in
// `AppDataLocation/workspaces/*.json` once Customize mode ships.
QtObject {
    readonly property var presets: ({
        "classic": {
            "id":          "classic",
            "name":        "Classic",
            "description": "Three panes — Library, Schedule, Output. Familiar to EasyWorship users.",
            "root": {
                "type": "row",
                "children": [
                    { "type": "panel", "id": "library",  "size": 240 },
                    { "type": "panel", "id": "schedule", "stretch": true },
                    { "type": "panel", "id": "output",   "size": 380 }
                ]
            }
        },

        "studio": {
            "id":          "studio",
            "name":        "Studio",
            "description": "Slide grid as the centerpiece. Best for slide-heavy services.",
            "root": {
                "type": "row",
                "children": [
                    { "type": "panel", "id": "library-icons", "size": 56,  "fixed": true },
                    { "type": "panel", "id": "schedule",      "size": 280 },
                    { "type": "panel", "id": "slides",        "stretch": true },
                    { "type": "panel", "id": "output",        "size": 340 }
                ]
            }
        }
    })

    // Panel metadata — title for the (future) panel header chrome,
    // size constraints, default icons. Not all of these are shown in v1
    // since panels render their own chrome inside, but this is where
    // future Customize mode reads from.
    readonly property var panelInfo: ({
        "library":       { "title": "Library",       "icon": "✠", "minSize": 200 },
        "library-icons": { "title": "Library",       "icon": "✠", "minSize": 56  },
        "schedule":      { "title": "Schedule",      "icon": "≡", "minSize": 240 },
        "slides":        { "title": "Slides",        "icon": "▦", "minSize": 360 },
        "output":        { "title": "Output",        "icon": "○", "minSize": 280 }
    })

    readonly property string defaultPresetId: "classic"
}
