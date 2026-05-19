import QtQuick
import Crater

// Reusable projection scene — the canvas-native render surface shared by
// ProjectionWindow (audience display) and NdiCanvas (NDI broadcast in dual
// output mode). Reads from ProjectionService for content, resolves theme
// via AppState.resolveItemTheme(item, outputKind), letterboxes the canvas
// into the parent, and exposes the inner `stage` Item via `renderItem`
// so external consumers (NDI grabber today; future recording / multi-
// output sinks) can pull canvas-resolution frames regardless of how the
// scene is letterboxed into its host window.
//
// outputKind selects which per-output theme override the scene honors:
//   "primary" → SettingsService.themeIdForPrimary (always-on)
//   "ndi"     → SettingsService.themeIdForNdi when outputMode==="dual",
//               otherwise falls back to themeIdForPrimary (so a single-
//               mode NDI scene matches what the projection window shows)
//   "stage"   → reserved for v1.1 multi-output stage monitor
//
// The same component instantiates in both consumer windows; only the
// outputKind property differs. That keeps the rendering source-of-truth
// singular even as the two outputs can render different themes.
Item {
    id: scene

    property string outputKind: "primary"

    // Mirrors original ProjectionWindow value — operator-facing transition
    // speed for go-live / page-change / logo fades.
    readonly property int _transMs: 280

    // Canvas-native render surface. NDI's grabber points at this so it
    // gets canvas-resolution pixels (1920×1080 by default) regardless of
    // how big the host window happens to be.
    property alias renderItem: stage

    // ── Reactive bindings to ProjectionService ──────────────────────────
    readonly property var    _item    : ProjectionService.currentItem
    readonly property string _kind    : ProjectionService.contentKind
    readonly property int    _page    : ProjectionService.pageIndex
    readonly property bool   _isClear : ProjectionService.isClear
    readonly property bool   _showLogo: ProjectionService.showLogo

    // True when the live item is itself a picture or movie (vs a
    // song/scripture/presentation whose theme may have a media background).
    // For these, the entire stage = the media — no theme nodes overlay,
    // no no-theme fallback. The themed Repeater is gated off below.
    readonly property bool   _isMediaItem:
        _item && (_kind === "image" || _kind === "video")
              && (_item.mediaPath || "").length > 0

    // Theme resolution — bumps on default changes, theme adds/removes, the
    // outputMode toggle, and per-output theme writes. AppState.resolveItemTheme
    // is invoked with this scene's outputKind so dual-mode NDI sees its own
    // pinned theme while the primary projection sees its own — without either
    // side requiring a re-Go-Live.
    property int _themeRevision: 0
    readonly property var _theme: {
        _themeRevision
        return AppState.resolveItemTheme(_item, outputKind)
    }

    Connections {
        target: ThemeService
        function onDefaultsChanged()  { scene._themeRevision++ }
        function onAllThemesChanged() { scene._themeRevision++ }
    }
    Connections {
        target: SettingsService
        // Each of these can flip which slot resolveItemTheme picks; bump
        // the revision so both ProjectionScene instances re-resolve in lock-
        // step when the operator changes any per-output assignment.
        function onOutputModeChanged()         { scene._themeRevision++ }
        function onThemeIdForPrimaryChanged()  { scene._themeRevision++ }
        function onThemeIdForNdiChanged()      { scene._themeRevision++ }
        function onThemeIdForStageChanged()    { scene._themeRevision++ }
    }

    readonly property var _tokens : _theme && _theme.tokens ? _theme.tokens : ({})
    readonly property var _canvas : _tokens.canvas || ({ width: 1920, height: 1080 })
    readonly property var _nodes  : _tokens.nodes  || []

    // ── Content resolution ──────────────────────────────────────────────
    // Live current page text — what the operator sent live. Text nodes with
    // linkage=scriptureText or linkage=lyric show this.
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

    // ── Letterbox: the *visible* canvas container ───────────────────────
    // Scaled to fit the host while preserving the canvas aspect ratio.
    // For NdiCanvas (host sized 1920×1080) this collapses to a 1:1 scale;
    // for ProjectionWindow it shrinks the canvas into whatever windowed
    // thumbnail / fullscreen geometry is in play.
    Item {
        id: letterbox
        anchors.centerIn: parent
        readonly property real _scale: Math.min(parent.width  / scene._canvas.width,
                                                parent.height / scene._canvas.height)
        width:  scene._canvas.width  * _scale
        height: scene._canvas.height * _scale
        clip: true

        // ── Stage: the *canvas-native* render surface ───────────────────
        // Always sized to theme canvas dimensions (typically 1920×1080).
        // `scale: letterbox._scale` shrinks/grows the visual rendering to
        // fit the letterbox without changing the logical size — children
        // inside continue to position themselves at canvas-native pixel
        // coordinates via percent-of-stage.{width,height}. grabToImage on
        // this Item returns canvas-native pixels regardless of how large
        // the actual display window is — that's the key decoupling: NDI
        // gets full-res frames even when the operator's monitor is showing
        // a 480×270 windowed preview.
        Item {
            id: stage
            width:  scene._canvas.width
            height: scene._canvas.height
            transformOrigin: Item.TopLeft
            scale: letterbox._scale

            // Content layer — fades on logo show/hide. `isClear` no longer
            // hides the whole stage; instead it hides only *text* nodes
            // (handled per-delegate below) so the theme background and any
            // non-text nodes remain visible. Logo overlay drives a full
            // content-layer fade because the logo is meant to replace the
            // entire scene visually.
            Item {
                id: contentLayer
                anchors.fill: parent
                opacity: scene._showLogo ? 0 : 1
                Behavior on opacity {
                    NumberAnimation {
                        duration: scene._transMs
                        easing.type: Easing.InOutCubic
                    }
                }

                // ── Media-item branch ────────────────────────────────
                // Renders when the live item is itself an image/video file.
                // Sits inside `stage` at canvas-native size — NDI's frame
                // grabber points at `stage`, so this is automatically part
                // of the captured frame. Inside `contentLayer`, so a logo
                // overlay still fades the media out via the contentLayer
                // opacity transition.
                //
                // `isClear` is not applied here: the current clear semantic
                // is "hide text nodes only; backgrounds and decorative
                // content remain visible" (matches the per-delegate text
                // gate below). A media item is by definition non-text, so
                // clearing leaves it visible.
                //
                // Audio routing: only the primary (audience-facing) scene
                // unmutes, and only while the projection window is actually
                // visible to the operator. The NDI scene leaves audio
                // muted — NDI carries its own audio channel at the SDK
                // layer; we don't want this player double-driving the
                // system audio bus. The shared MediaPlaybackService takes
                // the OR of all subscribers' wantsAudio, so muting here is
                // a real "this surface doesn't want audio" vote and the
                // Preview / Live mini-monitor votes still govern audio
                // when the projection is parked.
                MediaMonitor {
                    id: mediaItemMonitor
                    anchors.fill: parent
                    visible: scene._isMediaItem
                    mediaKind: visible ? scene._kind : ""
                    mediaPath: visible ? (scene._item.mediaPath || "") : ""
                    muted:    scene.outputKind !== "primary"
                                || !OutputService.projectionOpen
                    // Audience expectations: see the whole frame,
                    // letterboxed if needed. Operator can crop in v1.1 per
                    // media item if we add a fit-mode property.
                    crop: false
                }

                Repeater {
                    // For media items the stage = the media; theme nodes
                    // (which may still resolve through the per-output
                    // override path) would render *on top of* the video.
                    // Force the model empty in that case — the MediaMonitor
                    // sibling above is the only content.
                    model: scene._isMediaItem ? [] : scene._sortedNodes
                    delegate: Item {
                        readonly property var _style: modelData.style || ({})
                        x:        stage.width  * ((_style.x      || 0) / 100)
                        y:        stage.height * ((_style.y      || 0) / 100)
                        width:    stage.width  * ((_style.width  || 0) / 100)
                        height:   stage.height * ((_style.height || 0) / 100)
                        opacity:  _style.opacity !== undefined ? _style.opacity : 1
                        rotation: _style.rotation || 0

                        // Per-node "clear fader" — drops to 0 only when the
                        // node is a TEXT node AND the projection is cleared.
                        // Non-text nodes (image backgrounds, containers,
                        // decorative shapes) keep their parent opacity and
                        // remain visible. Separated from the outer Item's
                        // opacity so theme-editor edits to `style.opacity`
                        // continue to snap (no Behavior there), while the
                        // clear fade is animated here.
                        Item {
                            anchors.fill: parent
                            opacity: (scene._isClear && modelData.kind === "text") ? 0 : 1
                            Behavior on opacity {
                                NumberAnimation {
                                    duration: scene._transMs
                                    easing.type: Easing.InOutCubic
                                }
                            }

                            NodeRenderer {
                                anchors.fill: parent
                                node: modelData
                                resolvedText: scene.resolveText(modelData)
                            }
                        }
                    }
                }
            }

            // ── No-theme fallback ───────────────────────────────────────
            // Shown when a song/scripture goes live but the operator hasn't
            // set a default theme for that kind and no built-in matches.
            // Without this, the projection would be silently black —
            // confusing during a service. Mirrors Electron's NoThemeError.
            // Text-bearing kinds only — image/video items don't render
            // through the theme path.
            Text {
                id: noThemeText
                anchors.centerIn: parent
                anchors.margins: 40
                width: parent.width - 80
                visible: !scene._isClear
                      && !scene._showLogo
                      && (scene._kind === "song" || scene._kind === "scripture")
                      && (!scene._theme || (scene._theme.id || 0) === 0)
                text: qsTr("Default %1 theme has not been set").arg(scene._kind)
                           .toUpperCase()
                color: "#ffffff"
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                font.family: Theme.font.family
                font.pixelSize: 72
                font.weight: Theme.font.weightBold
            }

            // Logo overlay — sits above the content layer when toggled on.
            // LogoView renders the configured image OR video, or a "CRATER"
            // fallback when no logo path has been chosen. `active` gates
            // the video decoder; opacity drives the fade so the decoder
            // doesn't bounce on every fade tick.
            //
            // Logo visibility is independent of `isClear` — clearing only
            // hides text, so a logo toggled on stays visible through a
            // clear.
            LogoView {
                id: logoView
                anchors.fill: parent
                active: scene._showLogo
                opacity: scene._showLogo ? 1.0 : 0.0

                Behavior on opacity {
                    NumberAnimation {
                        duration: scene._transMs
                        easing.type: Easing.InOutCubic
                    }
                }
            }
        }
    }
}
