import QtQuick
import QtQuick.Window
import Crater

// Themed mini-monitor — renders a schedule item through the resolved
// theme (per-item override -> kind default), or via MediaMonitor when the
// item kind is image/video. Shared by PreviewPanel and LivePanel as the
// content layer of their bottom-of-pane monitors.
//
// Mirrors ProjectionWindow.qml's theme-resolution + node-render flow at a
// smaller geometry: nodes are placed and sized in canvas percentage,
// NodeRenderer paints each, and text linkages resolve to real item content
// (item.pages[pageIndex].content for lyric / scriptureText, item.title for
// scriptureRef). Per-fade animations are suppressed — the operator monitor
// reads better when content snaps rather than fades.
//
// Empty / "nothing live" / "display cleared" copy stays with the parent
// panel; this component only renders when handed an item.
Item {
    id: root

    // ── Inputs ──────────────────────────────────────────────────────────
    property var  item                  // canonical schedule item, or null
    property int  pageIndex: 0
    property bool autoPlayVideos: true  // theme-container video backgrounds
    property bool muted: true           // MediaMonitor audio (preview=true, live=false)
    property bool showLogo: false       // gate content while logo overlay is shown
    property bool isClear:  false       // gate content while output is cleared
    // Normalized crop rectangle applied to image / PDF rendering. Identity
    // {0,0,1,1} = no crop (full source). LivePanel passes
    // ProjectionService.cropRect so the live mini-monitor shows what the
    // audience sees (the section being displayed) rather than the full
    // source. PreviewPanel's mini-monitor hides entirely for croppable
    // media, so this defaults to identity for everyone else.
    property rect cropRect: Qt.rect(0, 0, 1, 1)

    // ── Derived state ───────────────────────────────────────────────────
    readonly property bool _hasItem: !!item
    readonly property string _kind: _hasItem ? (item.kind || "") : ""
    readonly property bool _isMedia:
        _hasItem
        && (_kind === "image" || _kind === "video")
        && (item.mediaPath || "").length > 0
    readonly property bool _isPdf:
        _hasItem && _kind === "pdf" && (item.mediaId || 0) > 0
    readonly property bool _hasCrop:
        cropRect.x !== 0 || cropRect.y !== 0
        || cropRect.width !== 1 || cropRect.height !== 1

    // ── Reactive theme resolution ───────────────────────────────────────
    // Same revision-bump pattern as ProjectionWindow: bumping the int
    // forces _theme to re-evaluate whenever the operator changes a
    // default-for-kind selection or adds/deletes any theme.
    property int _themeRevision: 0

    readonly property var _theme: {
        _themeRevision   // dependency
        return _hasItem ? AppState.resolveItemTheme(item) : null
    }

    Connections {
        target: ThemeService
        function onDefaultsChanged()  { root._themeRevision++ }
        function onAllThemesChanged() { root._themeRevision++ }
    }

    readonly property var _tokens: _theme && _theme.tokens ? _theme.tokens : ({})
    readonly property var _canvas: _tokens.canvas || ({ width: 1920, height: 1080 })
    readonly property var _nodes:  _tokens.nodes  || []

    // ── Linkage resolution (theme placeholder -> real item content) ─────
    readonly property string _pageText: {
        if (!_hasItem) return ""
        const pages = item.pages
        if (!pages || pages.length === 0) return ""
        const i = Math.max(0, Math.min(pageIndex, pages.length - 1))
        const p = pages[i]
        return (p && p.content) || ""
    }
    readonly property string _refText:
        _hasItem ? (item.title || item.reference || "") : ""

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

    // Pre-sort by z so render order matches layer order. Recomputes only
    // when _nodes changes — cheap for ≤50 nodes.
    readonly property var _sortedNodes: {
        const arr = _nodes.slice()
        arr.sort((a, b) =>
            ((a.style && a.style.z) || 0) - ((b.style && b.style.z) || 0))
        return arr
    }

    readonly property bool _showStage:
        _hasItem
        && !_isMedia
        && !_isPdf
        && !showLogo
        && _theme
        && (_theme.id || 0) > 0
        && _nodes.length > 0

    readonly property bool _showNoTheme:
        _hasItem
        && !_isMedia
        && !_isPdf
        && !isClear
        && !showLogo
        && (_kind === "song" || _kind === "scripture" || _kind === "presentation")
        && (!_theme || (_theme.id || 0) === 0 || _nodes.length === 0)

    // ── Theme stage (text-bearing kinds) ────────────────────────────────
    Item {
        id: stage
        anchors.centerIn: parent
        visible: root._showStage
        readonly property real _scale:
            Math.min(parent.width  / root._canvas.width,
                     parent.height / root._canvas.height)
        width:  root._canvas.width  * _scale
        height: root._canvas.height * _scale
        clip: true

        Repeater {
            model: stage.visible ? root._sortedNodes : []
            delegate: Item {
                readonly property var _style: modelData.style || ({})
                x:        stage.width  * ((_style.x      || 0) / 100)
                y:        stage.height * ((_style.y      || 0) / 100)
                width:    stage.width  * ((_style.width  || 0) / 100)
                height:   stage.height * ((_style.height || 0) / 100)
                opacity:  _style.opacity !== undefined ? _style.opacity : 1
                rotation: _style.rotation || 0

                // Text nodes hide instantly when isClear is true (mini-
                // monitor mirrors the projection's clear semantic, but
                // snaps because the operator monitor is intentionally
                // animation-free for fast feedback). Non-text nodes
                // (background images, containers, decorations) ignore
                // isClear and stay visible — matching the projection.
                visible: !(root.isClear && modelData.kind === "text")

                NodeRenderer {
                    anchors.fill: parent
                    node: modelData
                    resolvedText: root.resolveText(modelData)
                    suppressAnimations: true
                    autoPlayVideos: root.autoPlayVideos
                }
            }
        }
    }

    // ── Media branch (image/video kinds) ────────────────────────────────
    // Pure media items have no text — `isClear` is a no-op for them under
    // the new "hide text only" clear semantic. Visibility stays gated on
    // showLogo (logo fully replaces the scene) but ignores isClear.
    //
    // Crop handling: the MediaMonitor below renders the full source when
    // no crop is staged (the common case). When the LivePanel passes a
    // non-identity cropRect (operator committed a cropped section), the
    // mediaMonitor hides and `imageCropOverlay` renders the cropped sub-
    // region instead. This keeps MediaMonitor a single-purpose "render
    // this whole file" component without growing crop logic.
    MediaMonitor {
        anchors.fill: parent
        visible: root._isMedia && !root.showLogo && !(root._kind === "image" && root._hasCrop)
        mediaKind: visible ? root._kind : ""
        mediaPath: visible ? (root.item.mediaPath || "") : ""
        muted: root.muted
        crop:  false
    }

    // Cropped-image branch — paints only the operator-selected sub-region
    // of the image into the monitor. Used by LivePanel to show "the
    // section being displayed" rather than the full source. PreviewPanel
    // hides this monitor entirely for croppable media, so this only ever
    // activates on the live channel.
    Image {
        anchors.fill: parent
        visible: root._isMedia
                 && root._kind === "image"
                 && root._hasCrop
                 && !root.showLogo
        source: visible ? "file:///" + (root.item.mediaPath || "") : ""
        asynchronous: true
        cache: true
        fillMode: Image.PreserveAspectFit
        sourceClipRect: {
            if (!visible || sourceSize.width <= 0 || sourceSize.height <= 0) {
                return Qt.rect(0, 0, 0, 0)
            }
            const c = root.cropRect
            return Qt.rect(c.x * sourceSize.width,
                           c.y * sourceSize.height,
                           c.width  * sourceSize.width,
                           c.height * sourceSize.height)
        }
    }

    // ── PDF branch ──────────────────────────────────────────────────────
    // Renders the live page via the image://pdfpage/ provider. The crop
    // ride-along in the URL means pdfium re-rasterizes the sub-region at
    // this monitor's pixel size — text inside the crop stays crisp even
    // at thumbnail dimensions.
    Image {
        anchors.fill: parent
        visible: root._isPdf && !root.showLogo
        asynchronous: true
        cache: true
        // Bind sourceSize to the monitor's pixel size so we don't ask
        // pdfium for 4K when we only need ~280px wide.
        sourceSize.width:
            parent.width  > 0 ? Math.ceil(parent.width  * Screen.devicePixelRatio) : 512
        sourceSize.height:
            parent.height > 0 ? Math.ceil(parent.height * Screen.devicePixelRatio) : 288
        source: {
            if (!visible || !root._hasItem) return ""
            const id   = Number(root.item.mediaId || 0)
            const page = Math.max(0, root.pageIndex)
            const c    = root.cropRect
            return "image://pdfpage/" + id
                 + "?page=" + page
                 + "&cx="   + c.x
                 + "&cy="   + c.y
                 + "&cw="   + c.width
                 + "&ch="   + c.height
        }
        fillMode: Image.PreserveAspectFit
    }

    // ── Fallback when no theme exists for a text-bearing kind ───────────
    // Sized down from ProjectionWindow's full-screen "DEFAULT THEME NOT
    // SET" banner so it reads cleanly at mini-monitor scale, but uses the
    // same wording so the operator sees consistent messaging across
    // surfaces.
    Text {
        anchors.centerIn: parent
        anchors.margins: Theme.space.sm
        width: parent.width * 0.85
        visible: root._showNoTheme
        text: qsTr("No %1 theme set").arg(root._kind).toUpperCase()
        color: "#ffffff"
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        font.family: Theme.font.family
        font.pixelSize: 12
        font.weight: Theme.font.weightSemiBold
        font.letterSpacing: 1.0
        opacity: 0.85
    }
}
