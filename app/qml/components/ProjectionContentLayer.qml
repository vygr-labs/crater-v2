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
        // Empty live channel (nothing committed yet → layerKind is "") must
        // render BLANK, not a default-theme background. The operator can now
        // open the audience window before pushing content (TopBar "Go Live"
        // only raises — see AppState.openProjector), and resolveItemTheme would
        // otherwise fall through to ThemeService.defaultFor("song") — line 271
        // defaults an empty item's kind to "song" — and paint that theme's
        // background on a screen that should be dark. The Live pane already
        // shows its "Nothing live" empty state in this case (it gates on
        // liveScheduleIndex / libraryLiveActive); returning an empty theme keeps
        // the projection in agreement. Any real commit sets a non-empty kind,
        // which restores normal resolution.
        if (!layerKind) return ({})
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

    // Composed "Book chapter:verse[-verse]" for the optional footer overlay.
    // Prefers the structured scriptureRef (drops the translation parenthetical
    // the title carries) and falls back to the title/reference.
    readonly property string _footerText: {
        if (layerKind !== "scripture" || !layerItem) return ""
        const r = layerItem.scriptureRef
        if (r && r.book) {
            let s = r.book + " " + r.chapter
            if (r.verseStart) {
                s += ":" + r.verseStart
                if (r.verseEnd && r.verseEnd !== r.verseStart) s += "-" + r.verseEnd
            }
            return s
        }
        return _refText
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

    // ── Themed node graph (shared with ThemePreview) ────────────────────
    // The node layout — group/card stacking, autoHeight (hug content), and
    // autoPosition (stack relative to) — lives in ThemedNodeGraph so the live
    // output and the ThemesTab thumbnails render through the SAME renderer.
    // They used to diverge: a card stacked its members live but the preview
    // showed every node at its pre-stack box, so card themes previewed wrong.
    // Suppressed when the live item is itself a media item (see _isMediaItem)
    // so theme nodes don't paint over the visible media — we feed it an empty
    // node list in that case. resolveText maps each text node's linkage to the
    // current live content; clearActive drives the per-text clear fade.
    ThemedNodeGraph {
        anchors.fill: parent
        nodes:          root._isMediaItem ? [] : root._nodes
        resolveTextFn:  node => root.resolveText(node)
        clearActive:    ProjectionService.isClear
        passiveFadeMs:  root.passiveFadeMs
        // Live output runs full motion (gradients animate, videos play).
        autoPlayVideos: true
    }

    // ── Scripture reference footer (global toggle) ──────────────────────
    // A render-time reference line, drawn on TOP of the theme regardless of
    // whether the theme authored its own reference node, so Settings >
    // Scripture > "Show book:chapter in footer" is always honored. Neutral
    // white-with-outline styling reads on both light and dark theme
    // backgrounds; sizes/positions relative to the (scaled) layer so it
    // tracks the output resolution. Hidden when blanked, matching the text
    // clear fade.
    Text {
        id: scriptureFooter
        visible: root.layerKind === "scripture"
                 && SettingsService.showScriptureFooter
                 && !ProjectionService.isClear
                 && text.length > 0
        text: root._footerText
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Math.round(root.height * 0.045)
        color: "#ffffff"
        style: Text.Outline
        styleColor: "#cc000000"
        font.family: Theme.font.family
        font.pixelSize: Math.max(12, Math.round(root.height * 0.030))
        font.weight: Theme.font.weightSemiBold
        opacity: 0.92
        Behavior on opacity { NumberAnimation { duration: root.passiveFadeMs } }
    }
}
