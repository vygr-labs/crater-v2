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
    // Whether container video backgrounds should auto-play. Defaults true so
    // ProjectionWindow and the editor canvas keep their existing behavior; a
    // small-tile caller (ThemePreview inside ThemesTab) flips this off so a
    // grid of dozens of theme thumbnails doesn't each spin up a video decoder.
    property bool   autoPlayVideos: true

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
                    autoPlay: nodeRoot.autoPlayVideos
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
    // We do our own binary-search fit instead of using Qt's `Text.Fit`.
    // `Text.Fit`'s internal fit predicate does not consistently honor the
    // `lineHeight` multiplier on multi-line wrapped text — the last line
    // ends up spilling below the box at non-1.0 multipliers. We binary-
    // search against a hidden probe whose `paintedHeight` reflects real
    // metrics under our exact font + lineHeight + wrap settings, matching
    // the behavior of the Electron build's TextFill.js (which measures via
    // DOM offsetHeight) but without the JS-round-trip cost.
    Loader {
        anchors.fill: parent
        active: nodeRoot._isText
        sourceComponent: Component {
            Item {
                id: textHost
                anchors.fill: parent

                readonly property var _style: nodeRoot.node.style || ({})
                readonly property var _data:  nodeRoot.node.data  || ({})

                // textTransform via JS — QML Text has no CSS text-transform.
                function _applyCase(s) {
                    switch (_style.textTransform) {
                        case "uppercase":  return (s || "").toUpperCase()
                        case "lowercase":  return (s || "").toLowerCase()
                        case "capitalize": return (s || "").replace(/\b\w/g, c => c.toUpperCase())
                        default:           return s
                    }
                }
                readonly property string _renderedText: _applyCase(nodeRoot.resolvedText)

                // Fitted pixel size. Updated by _refit() — kept as a plain
                // property (not a binding) so the binary search writing to
                // it doesn't clobber a live binding.
                property int _fittedSize: _style.fontPixelSize || 48

                // Hidden probe — mirrors layout-affecting properties of
                // visibleText so paintedHeight/Width report accurate metrics
                // at each trial pixelSize during binary search.
                Text {
                    id: probe
                    visible: false
                    text:               visibleText.text
                    font.family:        visibleText.font.family
                    font.weight:        visibleText.font.weight
                    font.italic:        visibleText.font.italic
                    font.letterSpacing: visibleText.font.letterSpacing
                    wrapMode:           visibleText.wrapMode
                    width:              visibleText.width
                    lineHeight:         visibleText.lineHeight
                    lineHeightMode:     visibleText.lineHeightMode
                }

                // Font metrics for the visible text — used to compute the
                // top-leading asymmetry compensation below.
                FontMetrics {
                    id: fm
                    font: visibleText.font
                }

                // Optical centering shift. Qt's `verticalAlignment: AlignVCenter`
                // centers the text *bounding box*, not the visible ink. The
                // box top sits at the font's ascent line, which is taller
                // than the cap top of capital letters by the font's internal
                // leading (room for accents). There is no equivalent reserve
                // below the descent line. Qt's lineHeight > 1.0 distribution
                // is symmetric (half-leading above and below each line), so
                // it does NOT contribute to net top/bottom asymmetry — the
                // only source is the above-cap reserve. We shift up by half
                // of it so the visible ink lands in the geometric center.
                readonly property real _opticalShift: {
                    const capHeight = fm.tightBoundingRect("M").height
                    const aboveCap  = Math.max(0, fm.ascent - capHeight)
                    return aboveCap / 2
                }

                function _refit() {
                    if (!_data.autoResize) {
                        // Track user-set pixel size when auto-resize is off.
                        _fittedSize = _style.fontPixelSize || 48
                        return
                    }
                    const w = textHost.width
                    const h = textHost.height
                    if (w <= 0 || h <= 0) return
                    const maxSize = Math.max(8, _data.maxFontSize || 220)
                    let lo = 8, hi = maxSize, best = 8
                    while (lo <= hi) {
                        const mid = (lo + hi) >> 1
                        probe.font.pixelSize = mid
                        if (probe.paintedHeight <= h && probe.paintedWidth <= w) {
                            best = mid
                            lo = mid + 1
                        } else {
                            hi = mid - 1
                        }
                    }
                    _fittedSize = best
                }

                // Debounce: many of these triggers fire in bursts during
                // a drag-resize. Coalesce to one fit per frame.
                Timer {
                    id: refitTimer
                    interval: 16
                    repeat: false
                    onTriggered: textHost._refit()
                }

                onWidthChanged:  refitTimer.restart()
                onHeightChanged: refitTimer.restart()
                Connections {
                    target: nodeRoot
                    function onNodeChanged()         { refitTimer.restart() }
                    function onResolvedTextChanged() { refitTimer.restart() }
                }
                Component.onCompleted: _refit()

                Text {
                    id: visibleText
                    // Span the full box horizontally, but anchor vertically
                    // via verticalCenter + offset so we can apply the
                    // optical-shift compensation. height remains parent.height
                    // so wrapMode and the binary-search probe agree on the
                    // available box.
                    anchors.left:   parent.left
                    anchors.right:  parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.verticalCenterOffset: -textHost._opticalShift
                    height: parent.height
                    text:               textHost._renderedText
                    color:              textHost._style.color || "#ffffff"
                    font.family:        textHost._style.fontFamily || Theme.font.family
                    font.pixelSize:     textHost._fittedSize
                    font.weight:        textHost._style.fontWeight || Theme.font.weightMedium
                    font.italic:        !!textHost._style.fontItalic
                    font.letterSpacing: textHost._style.letterSpacing || 0
                    lineHeight:         textHost._style.lineHeightMultiplier || 1.25
                    lineHeightMode:     Text.ProportionalHeight

                    horizontalAlignment: textHost._style.textAlign === "left"  ? Text.AlignLeft
                                       : textHost._style.textAlign === "right" ? Text.AlignRight
                                                                                : Text.AlignHCenter
                    verticalAlignment:   textHost._style.verticalAlign === "start" ? Text.AlignTop
                                       : textHost._style.verticalAlign === "end"   ? Text.AlignBottom
                                                                                    : Text.AlignVCenter

                    wrapMode: Text.WordWrap
                    elide: Text.ElideNone
                    fontSizeMode: Text.FixedSize
                }
            }
        }
    }
}
