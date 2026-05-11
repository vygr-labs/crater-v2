import QtQuick
import Crater

// Renders a theme into a non-interactive preview surface. Letterboxed to
// the theme's canvas aspect inside `anchors.fill`. Mock content is used for
// text nodes so the preview reads the same way for everyone — actual live
// content only appears in ProjectionWindow.
//
// Used by:
//   - ThemesTab tile bodies (small thumbnails, autoPlay videos OFF)
//   - The editor's canvas (full-size editing surface, autoPlay videos ON)
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

    function resolveText(node) {
        if (!node || node.kind !== "text") return ""
        const data = node.data || {}
        switch (data.linkage) {
            case "scriptureRef":  return mockScriptureRef
            case "scriptureText": return mockScriptureText
            case "lyric":         return mockLyric
            case "custom":        return data.text || ""
        }
        return data.text || ""
    }

    // Letterbox math — scale by the smaller axis so the canvas keeps its
    // aspect ratio regardless of parent shape.
    Item {
        id: stage
        anchors.centerIn: parent
        readonly property real _scale: Math.min(parent.width  / root._canvas.width,
                                                parent.height / root._canvas.height)
        width:  root._canvas.width  * _scale
        height: root._canvas.height * _scale
        clip: true

        // Sorted-by-z node list — Repeater respects model order, so we
        // pre-sort once per (re-) render. Cheap: <50 nodes.
        readonly property var _sortedNodes: {
            const arr = root._nodes.slice()
            arr.sort((a, b) => ((a.style && a.style.z) || 0) - ((b.style && b.style.z) || 0))
            return arr
        }

        Repeater {
            model: stage._sortedNodes
            delegate: Item {
                readonly property var _style: modelData.style || ({})
                x:        stage.width  * ((_style.x      || 0) / 100)
                y:        stage.height * ((_style.y      || 0) / 100)
                width:    stage.width  * ((_style.width  || 0) / 100)
                height:   stage.height * ((_style.height || 0) / 100)
                opacity:  _style.opacity !== undefined ? _style.opacity : 1
                rotation: _style.rotation || 0

                NodeRenderer {
                    anchors.fill: parent
                    node: modelData
                    resolvedText: root.resolveText(modelData)
                    suppressAnimations: true
                }
            }
        }
    }
}
