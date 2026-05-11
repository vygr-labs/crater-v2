import QtQuick
import Crater

// Renders a single theme node (Container or Text) into the rectangle it
// occupies. Used by ProjectionWindow, ThemePreview, and the EditorCanvas.
//
// `node` is one entry from theme.tokens.nodes — a QVariantMap shaped like
//   { id, kind: "container"|"text", style: {...}, data: {...} }.
// The caller is responsible for sizing this Item to the node's percentage
// position on the canvas; this component only paints inside `anchors.fill`.
//
// For text nodes, the caller passes `resolvedText` (already-resolved content
// according to data.linkage). NodeRenderer doesn't know about scripture /
// lyric / custom — that's the rendering shell's job. Keeps this component
// pure: same node + same resolvedText always produces the same pixels.
Item {
    id: nodeRoot
    property var    node           // QVariantMap; required
    property string resolvedText   // text content for text nodes (caller resolves)
    // Some callers (the editor) want to see content rendered without animations
    // mid-edit; live (ProjectionWindow) wants the smooth fade. Off by default.
    property bool   suppressAnimations: false

    readonly property bool _isText:      node && node.kind === "text"
    readonly property bool _isContainer: node && node.kind === "container"

    // ─── Container delegate ──────────────────────────────────────────────
    // Uniform radius for v1 — Qt 6's Rectangle.radius is a single value. The
    // 4 stored corner fields are averaged here; true per-corner rendering
    // requires a QQuickPaintedItem with QPainterPath and is deferred.
    Loader {
        anchors.fill: parent
        active: nodeRoot._isContainer
        sourceComponent: Component {
            Rectangle {
                readonly property var _style: nodeRoot.node.style || ({})
                readonly property var _data:  nodeRoot.node.data  || ({})

                color: _style.backgroundColor || "transparent"
                radius: ((_style.borderTopLeftRadius     || 0)
                       + (_style.borderTopRightRadius    || 0)
                       + (_style.borderBottomLeftRadius  || 0)
                       + (_style.borderBottomRightRadius || 0)) / 4
                clip: true

                // Media background — only mounted when mediaId is non-zero.
                // The Loader keeps us from doing a MediaService lookup every
                // render for plain-color containers.
                MediaBackgroundLoader {
                    anchors.fill: parent
                    mediaId: _data.mediaId || 0
                    bgOpacity: _data.bgOpacity !== undefined ? _data.bgOpacity : 1.0
                }

                // Overlay tint — sits above the media background to darken /
                // tint without affecting the picked color. Only when set.
                Rectangle {
                    anchors.fill: parent
                    color: _data.overlayColor || "transparent"
                    visible: !!_data.overlayColor
                }
            }
        }
    }

    // ─── Text delegate ───────────────────────────────────────────────────
    Loader {
        anchors.fill: parent
        active: nodeRoot._isText
        sourceComponent: Component {
            Text {
                readonly property var _style: nodeRoot.node.style || ({})
                readonly property var _data:  nodeRoot.node.data  || ({})

                text: nodeRoot.resolvedText
                color: _style.color || "#ffffff"
                font.family:        _style.fontFamily || Theme.font.family
                font.pixelSize:     _data.autoResize
                                  ? Math.max(8, _data.maxFontSize || 220)
                                  : (_style.fontPixelSize || 48)
                font.weight:        _style.fontWeight || Theme.font.weightMedium
                font.letterSpacing: _style.letterSpacing || 0
                lineHeight:         _style.lineHeightMultiplier || 1.25
                lineHeightMode:     Text.ProportionalHeight

                horizontalAlignment: _style.textAlign === "left"  ? Text.AlignLeft
                                   : _style.textAlign === "right" ? Text.AlignRight
                                                                  : Text.AlignHCenter
                verticalAlignment:   _style.verticalAlign === "start" ? Text.AlignTop
                                   : _style.verticalAlign === "end"   ? Text.AlignBottom
                                                                      : Text.AlignVCenter

                wrapMode: Text.WordWrap
                elide: Text.ElideNone

                // Auto-resize: ask QML's built-in Text.Fit to shrink to fit.
                // The maxFontSize cap is honored by setting font.pixelSize
                // above; QML reduces from there until height fits.
                fontSizeMode: _data.autoResize ? Text.Fit : Text.FixedSize
                minimumPixelSize: 8

                // textTransform via JS — QML Text doesn't have CSS text-transform.
                function _applyCase(s) {
                    switch (_style.textTransform) {
                        case "uppercase":  return (s || "").toUpperCase()
                        case "lowercase":  return (s || "").toLowerCase()
                        case "capitalize": return (s || "").replace(/\b\w/g, c => c.toUpperCase())
                        default:           return s
                    }
                }
                Component.onCompleted: text = _applyCase(nodeRoot.resolvedText)
                Connections {
                    target: nodeRoot
                    function onResolvedTextChanged() { text = _applyCase(nodeRoot.resolvedText) }
                }
            }
        }
    }
}
