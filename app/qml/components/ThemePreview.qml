import QtQuick
import Crater

// Renders a theme into a non-interactive preview surface. Letterboxed to
// the theme's canvas aspect inside `anchors.fill`. Mock content is used for
// text nodes so the preview reads the same way for everyone — actual live
// content only appears in ProjectionWindow.
//
// Used by the ThemesTab tile bodies (small thumbnails, autoPlay videos OFF).
// The actual node layout — including group/card stacking + auto-layout — is
// delegated to ThemedNodeGraph, the SAME renderer ProjectionWindow's live
// output uses, so a thumbnail is a faithful preview of what will go live
// (cards stack and hug here exactly as they do on the projection output).
// The theme editor canvas does NOT use this; it has its own NodeDelegate
// rendering that intentionally shows each node at its raw configured box.
//
// Pass a Theme (value type with `.tokens` etc.) via the `theme` property.
Item {
    id: root
    property var  theme               // crater::Theme value
    property bool autoPlayVideos: false   // off for tiles, on for the editor

    readonly property var  _tokens: theme && theme.tokens ? theme.tokens : ({})
    readonly property var  _canvas: _tokens.canvas || ({ width: 1920, height: 1080 })
    readonly property var  _nodes:  _tokens.nodes  || []

    // Mock content for the live linkage values. Same mock strings shared by
    // every text node so the preview is deterministic per theme.
    readonly property string mockScriptureRef:  "John 3:16"
    readonly property string mockScriptureText: "For God so loved the world, that he gave his only begotten Son, that whosoever believeth in him should not perish, but have everlasting life."
    readonly property string mockLyric:         "Amazing grace, how sweet the sound\nThat saved a wretch like me"
    // Short heading, longer body -- a presentation tile has to show the
    // title/body SIZE relationship, which is the whole thing an operator
    // judges a presentation theme on at thumbnail scale.
    readonly property string mockSlideTitle:    "The God Who Pursues"
    readonly property string mockSlideBody:     "He does not wait at the edge of the far country.\nHe runs."

    function resolveText(node) {
        if (!node || node.kind !== "text") return ""
        const data = node.data || {}
        switch (data.linkage) {
            case "scriptureRef":      return mockScriptureRef
            case "scriptureText":     return mockScriptureText
            case "lyric":             return mockLyric
            case "presentationTitle": return mockSlideTitle
            case "presentationBody":  return mockSlideBody
            case "custom":            return data.text || ""
        }
        return data.text || ""
    }

    // Letterbox math — scale by the smaller axis so the canvas keeps its
    // aspect ratio regardless of parent shape.
    // Letterbox preserves the canvas aspect; the stage inside renders at
    // canvas-NATIVE pixels and is shrunk by a single `scale` transform — so a
    // node's absolute fontPixelSize (non-auto-fit text, e.g. a fixed-size
    // scripture reference) scales down in proportion with the canvas instead of
    // towering over a scaled-down box. Mirrors ProjectionScene's letterbox /
    // stage split exactly, which is why the thumbnail matches the live output.
    Item {
        id: letterbox
        anchors.centerIn: parent
        readonly property real _scale: Math.min(parent.width  / root._canvas.width,
                                                parent.height / root._canvas.height)
        width:  root._canvas.width  * _scale
        height: root._canvas.height * _scale
        clip: true

        Item {
            id: stage
            width:  root._canvas.width
            height: root._canvas.height
            transformOrigin: Item.TopLeft
            scale: letterbox._scale

            // The whole node graph, INCLUDING group/card stacking + auto-layout,
            // rendered by the same ThemedNodeGraph the live projection output
            // uses. Mock content (root.resolveText) keeps the thumbnail
            // deterministic; videos + gradient animation stay off for a grid.
            ThemedNodeGraph {
                anchors.fill: parent
                nodes:              root._nodes
                resolveTextFn:      node => root.resolveText(node)
                autoPlayVideos:     root.autoPlayVideos
                suppressAnimations: true
                // A preview is never in the projection "clear" state.
                clearActive:        false
            }
        }
    }
}
