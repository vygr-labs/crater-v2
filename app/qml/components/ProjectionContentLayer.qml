import QtQuick
import Crater

// One renderable layer of the projection scene — image / video / PDF / theme
// nodes for a single (item, kind, page, cropRect) snapshot. Pure rendering:
// no logo, no clear-text fade, no opacity animation. The scene that owns the
// layer is responsible for fading between two of these instances during a
// transition.
//
// Why a reusable component (rather than inlining the rendering twice in
// ProjectionScene): the per-output transition controller needs an outgoing
// snapshot of the previous (item, kind, page) AND the incoming current one,
// rendered side-by-side, so it can crossfade between them. The cheapest way
// to express that is two instances of the same component, each holding its
// own input state. It also keeps audio mute and theme resolution scoped to a
// single layer rather than racing across two parallel renderers.
//
// Inputs are imperative state — the scene mutates them when a transition
// starts. They are NOT bound to ProjectionService here so that promoting
// "current" to "previous" is just a property copy rather than a binding
// rewire. The scene owns the lifecycle; this component just renders what
// it's told.
// Root id is `root`, NOT `layer` — every Item has a built-in `layer`
// attached property of type QQuickItemLayer (Qt's shader-effect opt-in).
// Using `id: layer` here would silently work for top-level child bindings
// (no scope nesting between binding and id) but get shadowed inside any
// nested Item, where `layer` resolves to the inner Item's OWN attached
// property — yielding `TypeError: Property 'X' of object QQuickItemLayer
// is not a function` for the Repeater delegate's clear-fade NodeRenderer
// binding `root.resolveText(modelData)`.
Item {
    id: root

    // ── Required input properties (set by the containing scene) ─────────
    // layerItem mirrors ProjectionService.currentItem's shape — a deep-copy
    // QVariantMap. Reading e.g. layerItem.mediaPath or layerItem.pages here
    // is safe because the scene snapshots whole maps, not bindings.
    property var    layerItem: ({})
    property string layerKind: ""
    property int    layerPage: 0
    property rect   layerCrop: Qt.rect(0, 0, 1, 1)

    // Which output this layer feeds — the OutputService registry id.
    // Drives per-output, per-kind theme resolution (AppState.resolveItemTheme
    // reads OutputService.themeIdFor(outputKind, item.kind)) and audio
    // routing (only the primary scene's current layer is allowed to drive
    // system audio).
    property string outputKind: "primary"

    // Bump-counter forwarded from the scene; rises when ThemeService
    // defaults change, when AllThemes refresh, or when an OutputBinding
    // mutates in the OutputService registry. Pulling it as a dependency
    // of _theme forces re-evaluation in lock-step with the scene's other
    // layer, so a theme edit doesn't leave the two layers out of sync.
    property int    themeRevision: 0

    // Scene sets this true on the current layer and false on the previous
    // (out-going) layer at transition kickoff. Mute follows so the outgoing
    // video frees the audio bus the instant a new item promotes — the
    // alternative (both layers fighting for audio) clicks.
    property bool   audioEnabled: false

    // Duration of passive (non-transition) opacity fades inside this layer
    // — specifically the per-text-node clear fade. Driven by the scene's
    // per-output passive-fade so a "cut" style yields an instant clear and
    // a long crossfade duration yields a matched clear feel. Default 280
    // keeps the historical behavior when this layer is used in isolation
    // (e.g. a future preview tile).
    property int    passiveFadeMs: 280

    // ── Theme resolution ────────────────────────────────────────────────
    // Reads through to AppState.resolveItemTheme so this layer honors the
    // outputKind-pinned theme. Depends on themeRevision so external
    // signals from ThemeService / SettingsService propagate in. `theme` is
    // intentionally public — the owning scene reads it to size its
    // letterbox to the current layer's canvas and to gate the no-theme
    // fallback message.
    readonly property var theme: {
        themeRevision  // dep
        return AppState.resolveItemTheme(layerItem, outputKind)
    }
    readonly property var _tokens : theme && theme.tokens ? theme.tokens : ({})
    readonly property var _canvas : _tokens.canvas || ({ width: 1920, height: 1080 })
    readonly property var _nodes  : _tokens.nodes  || []

    // ── Content classification ──────────────────────────────────────────
    // True when the live item is itself a picture / video / PDF (vs a
    // song/scripture whose theme may have a media background). For these
    // the stage = the media; theme nodes are suppressed so they don't
    // paint over the visible media.
    readonly property bool _isMediaItem: {
        if (!layerItem) return false
        if (layerKind === "image" || layerKind === "video") {
            return (layerItem.mediaPath || "").length > 0
        }
        if (layerKind === "pdf") {
            return (layerItem.mediaId || 0) > 0
        }
        return false
    }

    // ── Text resolution ─────────────────────────────────────────────────
    // The current page's text content, the reference label, and a helper
    // that maps a text node's linkage to the right string. Matches the
    // pre-extraction logic in ProjectionScene 1:1.
    readonly property string _pageText: {
        if (!layerItem) return ""
        const pages = layerItem.pages
        if (!pages || pages.length === 0) return ""
        const idx = Math.min(layerPage, pages.length - 1)
        const p = pages[idx]
        return (p && p.content) || ""
    }
    readonly property string _refText: {
        if (!layerItem) return ""
        return layerItem.title || layerItem.reference || ""
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
    // when _nodes changes — cheap for ≤50 nodes per theme.
    readonly property var _sortedNodes: {
        const arr = _nodes.slice()
        arr.sort((a, b) => ((a.style && a.style.z) || 0) - ((b.style && b.style.z) || 0))
        return arr
    }

    // ── Media-item branch ───────────────────────────────────────────────
    // Renders when layerKind is image/video and a mediaPath is present.
    // The MediaMonitor handles both kinds via its mediaKind switch. Sits
    // inside the layer at canvas-native size — when the scene scales the
    // stage Item this scales with it.
    MediaMonitor {
        id: mediaItemMonitor
        anchors.fill: parent
        visible: root._isMediaItem && (root.layerKind === "image" || root.layerKind === "video")
        mediaKind: visible ? root.layerKind : ""
        mediaPath: visible ? (root.layerItem.mediaPath || "") : ""
        // Audio routing: only when this layer is "current" AND its scene
        // is the primary AND the audience window is actually visible. The
        // outgoing layer always mutes (audioEnabled set false at transition
        // kickoff). Keeps the previous-layer video silent during the fade
        // so two videos never fight for the audio bus.
        muted: !root.audioEnabled
               || root.outputKind !== "primary"
               || !OutputService.projectionOpen
        crop: false
        // Hide when an image carries a non-identity crop — the
        // imageCropApplier below takes over so the crop happens at the
        // QML layer (sourceClipRect) rather than re-encoding the source.
        opacity: (root.layerKind === "image"
                  && root.layerCrop !== Qt.rect(0, 0, 1, 1)) ? 0 : 1
    }

    // ── Image crop applier ──────────────────────────────────────────────
    // For image items with a non-identity crop, render an Image that pulls
    // only the cropped sub-region into the full layer. sourceClipRect
    // (Qt 6.6+) crops in source-pixel space — combined with
    // PreserveAspectFit on a layer-shaped rectangle the cropped region
    // fills the canvas while keeping its own aspect (any aspect mismatch
    // letterboxes inside the canvas rather than stretching).
    Image {
        id: imageCropApplier
        anchors.fill: parent
        visible: root._isMediaItem
                 && root.layerKind === "image"
                 && root.layerCrop !== Qt.rect(0, 0, 1, 1)
        source: visible ? "file:///" + (root.layerItem.mediaPath || "") : ""
        // mediaItemMonitor has already pulled this URL, so the cache hits
        // synchronously here.
        asynchronous: false
        cache: true
        fillMode: Image.PreserveAspectFit
        sourceClipRect: {
            if (!visible || sourceSize.width <= 0 || sourceSize.height <= 0) {
                return Qt.rect(0, 0, 0, 0)
            }
            const c = root.layerCrop
            return Qt.rect(c.x * sourceSize.width,
                           c.y * sourceSize.height,
                           c.width  * sourceSize.width,
                           c.height * sourceSize.height)
        }
    }

    // ── PDF page renderer ───────────────────────────────────────────────
    // image://pdfpage/<id>?page=N&cx=...&cy=...&cw=...&ch=... routes through
    // PdfPageImageProvider, which calls MediaService::renderPdfPage. Cropping
    // is done at the rasterizer (pdfium re-renders at canvas DPI for the
    // cropped sub-region) rather than at the QML scenegraph — crisper text
    // inside cropped regions than sourceClipRect would give.
    Image {
        id: pdfPageImage
        anchors.fill: parent
        visible: root._isMediaItem && root.layerKind === "pdf"
        asynchronous: true
        cache: true
        // Keep the page currently on the projection output painted while
        // the next page / crop rasterizes — without this the audience sees
        // a blank frame for the full pdfium render on every page change.
        retainWhileLoading: true
        sourceSize.width:  width
        sourceSize.height: height
        source: {
            if (!visible || !root.layerItem) return ""
            const id   = Number(root.layerItem.mediaId || 0)
            const page = Math.max(0, root.layerPage)
            const c    = root.layerCrop
            return "image://pdfpage/" + id
                 + "?page=" + page
                 + "&cx="   + c.x
                 + "&cy="   + c.y
                 + "&cw="   + c.width
                 + "&ch="   + c.height
        }
        fillMode: Image.PreserveAspectFit
    }

    // ── Themed node graph ───────────────────────────────────────────────
    // Suppressed when the live item is itself a media item — see
    // _isMediaItem. Otherwise each node renders inside its own delegate
    // sized to its percent-of-stage rectangle, with skew handled by a
    // center-origin Matrix4x4 that matches the editor's NodeDelegate.
    Repeater {
        model: root._isMediaItem ? [] : root._sortedNodes
        delegate: Item {
            id: nodeWrap
            readonly property var _style: modelData.style || ({})
            x:        parent.width  * ((_style.x      || 0) / 100)
            y:        parent.height * ((_style.y      || 0) / 100)
            width:    parent.width  * ((_style.width  || 0) / 100)
            height:   parent.height * ((_style.height || 0) / 100)
            opacity:  _style.opacity !== undefined ? _style.opacity : 1
            rotation: _style.rotation || 0

            transform: Matrix4x4 {
                readonly property real _sx: (nodeWrap._style.skewX || 0) * Math.PI / 180
                readonly property real _sy: (nodeWrap._style.skewY || 0) * Math.PI / 180
                readonly property real _tx: Math.tan(_sx)
                readonly property real _ty: Math.tan(_sy)
                readonly property real _cx: nodeWrap.width  / 2
                readonly property real _cy: nodeWrap.height / 2
                matrix: Qt.matrix4x4(1,   _tx, 0, -_tx * _cy,
                                     _ty, 1,   0, -_ty * _cx,
                                     0,   0,   1, 0,
                                     0,   0,   0, 1)
            }

            // Per-node clear fade — drops to 0 only when this node is a
            // TEXT node AND the projection is cleared. Non-text nodes
            // (image backgrounds, decorative shapes) stay visible during
            // a clear. Separated from the outer Item's opacity so theme-
            // editor edits to style.opacity continue to snap (no Behavior
            // there), while clear is animated. Duration follows the
            // scene's passive-fade so cut style yields an instant clear.
            Item {
                anchors.fill: parent
                opacity: (ProjectionService.isClear && modelData.kind === "text") ? 0 : 1
                Behavior on opacity {
                    NumberAnimation {
                        duration: root.passiveFadeMs
                        easing.type: Easing.InOutCubic
                    }
                }

                NodeRenderer {
                    anchors.fill: parent
                    node: modelData
                    resolvedText: root.resolveText(modelData)
                }
            }
        }
    }
}
