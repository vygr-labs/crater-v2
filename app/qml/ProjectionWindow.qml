import QtQuick
import QtQuick.Window
import Crater

// Second-monitor output window. A separate QQuickWindow (NOT inside an
// ApplicationWindow), bound directly to ProjectionService Q_PROPERTYs — when
// projection state changes, Qt's binding engine re-evaluates and this window
// re-renders, no IPC, no Redux, no event bus. See plan's "Deviations from
// Electron" table for the rationale.
//
// As of tokens v2 the theme is a node graph (containers + texts positioned
// by percent on a canvas). This window letterboxes the canvas into the
// screen and Repeats node delegates inside that stage. Per-node fade is
// not animated — the entire content layer fades on go-live/page-change.
Window {
    id: projectionWindow

    // The screen index to target. Main.qml binds this to OutputService.
    property int screenIndex: 0

    screen: Qt.application.screens[screenIndex] || Qt.application.screens[0]

    flags: Qt.Window | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
    title: qsTr("Crater Projection")

    // Background color = first container's color, falling back to black.
    // Painted BEFORE the canvas stage so anything outside the letterbox
    // looks intentional (matte black, not theme color stretched).
    color: "#000000"

    onVisibleChanged: {
        if (visible) OutputService.notifyProjectionOpened()
        else         OutputService.notifyProjectionClosed()
    }

    // Reactive bindings to ProjectionService — stateChanged() fans into all
    // of these. Defensive `??` / `&&` chaining handles the moment before the
    // first theme is resolved (e.g. cold start, before any goLive call).
    readonly property var    _item      : ProjectionService.currentItem
    readonly property string _kind      : ProjectionService.contentKind
    readonly property int    _page      : ProjectionService.pageIndex
    readonly property var    _theme     : ProjectionService.currentTheme
    readonly property bool   _isClear   : ProjectionService.isClear
    readonly property bool   _showLogo  : ProjectionService.showLogo

    readonly property var    _tokens    : _theme && _theme.tokens ? _theme.tokens : ({})
    readonly property var    _canvas    : _tokens.canvas || ({ width: 1920, height: 1080 })
    readonly property var    _nodes     : _tokens.nodes  || []
    readonly property int    _transMs   : 280

    // ── Content resolution ──────────────────────────────────────────────
    // Live current page text — the actual lyric/verse content the
    // operator sent live. Text nodes with linkage=scriptureText or
    // linkage=lyric show this.
    readonly property string _pageText: {
        if (!_item) return ""
        const pages = _item.pages
        if (!pages || pages.length === 0) return ""
        const idx = Math.min(_page, pages.length - 1)
        const p = pages[idx]
        return (p && p.content) || ""
    }
    // Reference label (e.g. "John 3:16") for scripture items.
    readonly property string _refText: {
        if (!_item) return ""
        return _item.title || _item.reference || ""
    }

    function resolveText(node) {
        if (!node || node.kind !== "text") return ""
        const data = node.data || {}
        switch (data.linkage) {
            case "scriptureRef":  return _refText
            case "scriptureText": return _pageText
            case "lyric":         return _pageText
            case "custom":        return data.text || ""
        }
        return data.text || ""
    }

    // Pre-sort nodes by z so render order matches layer order. Recomputes
    // when _nodes changes — cheap for ≤50 nodes.
    readonly property var _sortedNodes: {
        const arr = _nodes.slice()
        arr.sort((a, b) => ((a.style && a.style.z) || 0) - ((b.style && b.style.z) || 0))
        return arr
    }

    // ── Stage: letterbox the canvas into the screen ─────────────────────
    Item {
        id: stage
        anchors.centerIn: parent
        readonly property real _scale: Math.min(parent.width  / projectionWindow._canvas.width,
                                                parent.height / projectionWindow._canvas.height)
        width:  projectionWindow._canvas.width  * _scale
        height: projectionWindow._canvas.height * _scale
        clip: true

        // Content layer — fades in/out on go-live, page-change, clear.
        Item {
            id: contentLayer
            anchors.fill: parent
            opacity: (projectionWindow._isClear || projectionWindow._showLogo) ? 0 : 1
            Behavior on opacity {
                NumberAnimation {
                    duration: projectionWindow._transMs
                    easing.type: Easing.InOutCubic
                }
            }

            Repeater {
                model: projectionWindow._sortedNodes
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
                        resolvedText: projectionWindow.resolveText(modelData)
                    }
                }
            }
        }

        // Logo overlay — sits above the content layer when toggled on.
        Text {
            id: logoText
            anchors.centerIn: parent
            visible: projectionWindow._showLogo && !projectionWindow._isClear
            opacity: visible ? 1.0 : 0.0
            text: "CRATER"
            color: "#ffffff"
            font.family: Theme.font.family
            font.pixelSize: 128
            font.weight: 900
            font.letterSpacing: 8

            Behavior on opacity {
                NumberAnimation {
                    duration: projectionWindow._transMs
                    easing.type: Easing.InOutCubic
                }
            }
        }
    }
}
