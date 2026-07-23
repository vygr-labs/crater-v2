import QtQuick
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
        && (_kind === "song" || _kind === "scripture" || _kind === "presentation" || _kind === "strongs")
        && (!_theme || (_theme.id || 0) === 0 || _nodes.length === 0)

    // ── Theme stage (text-bearing kinds) ────────────────────────────────
    // Letterbox + canvas-NATIVE stage + a single `scale` transform — identical
    // to ProjectionScene. The old approach sized the stage to canvas×scale and
    // positioned nodes by percent, which left a node's absolute fontPixelSize
    // painted literally (a fixed-size reference rendered far too large at
    // monitor scale). Rendering native + scaling shrinks fixed font sizes in
    // proportion. The node layout — including group/card stacking — is
    // delegated to ThemedNodeGraph so this monitor is WYSIWYG against live.
    Item {
        id: letterbox
        anchors.centerIn: parent
        visible: root._showStage
        readonly property real _scale:
            Math.min(parent.width  / root._canvas.width,
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

            ThemedNodeGraph {
                anchors.fill: parent
                nodes:              root._showStage ? root._nodes : []
                resolveTextFn:      node => root.resolveText(node)
                autoPlayVideos:     root.autoPlayVideos
                suppressAnimations: true
                // The operator monitor mirrors the projection's clear semantic
                // but SNAPS rather than fades (animation-free for fast feedback)
                // — passiveFadeMs 0 makes the clear gate hide text instantly.
                clearActive:        root.isClear
                passiveFadeMs:      0
            }
        }
    }

    // ── Media branch (image/video kinds) ────────────────────────────────
    // Pure media items have no text — `isClear` is a no-op for them under
    // the new "hide text only" clear semantic. Visibility stays gated on
    // showLogo (logo fully replaces the scene) but ignores isClear.
    //
    // Fit / crop / loop / mute all ride on the item map (buildItemFromMedia
    // → MediaService display columns) and are handled inside MediaMonitor —
    // image AND video crop, fit resolution (incl. the "default" sentinel), and
    // per-item loop/force-mute. cropRect is the committed live crop (LivePanel
    // passes ProjectionService.cropRect); it matches the item's saved crop
    // once the cropper seeds from it.
    MediaMonitor {
        anchors.fill: parent
        visible: root._isMedia && !root.showLogo
        mediaKind: visible ? root._kind : ""
        mediaPath: visible ? (root.item.mediaPath || "") : ""
        fitMode:  root._hasItem ? (root.item.fitMode || "default") : "default"
        cropRect: root.cropRect
        loop:     root._hasItem && root.item.loopVideo !== undefined
                      ? root.item.loopVideo : true
        muted: root.muted || (root._hasItem && root.item.muted === true)
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
        // Hold the current live page painted while the next page/crop
        // rasterizes — without this the monitor flashes black on every
        // Go Live and page change while the worker render is in flight.
        retainWhileLoading: true
        // Fixed render target — deliberately NOT bound to the card's
        // (animating) pixel size. The live monitor card grows via a
        // NumberAnimation on Go Live (LivePanel monitorWrap Behavior); a
        // size-tracking sourceSize re-requested a fresh pdfium render on
        // every animation frame, flooding the worker pool so the real
        // page took seconds to surface. A stable target = exactly one
        // render; the Image scales it to the card via its own filtering.
        sourceSize.width:  1280
        sourceSize.height: 720
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
