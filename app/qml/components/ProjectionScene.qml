import QtQuick
import Crater

// Reusable projection scene — the canvas-native render surface shared by
// ProjectionWindow (audience display) and NdiCanvas (NDI broadcast in dual
// output mode).
//
// The content tree (letterbox + stage + theme nodes + media + logo) is a
// single live structure bound directly to ProjectionService. It always
// reflects the latest live content — no mediation, no imperative state.
//
// Transitions are an ADDITIVE overlay: a sibling ShaderEffectSource
// mirrors letterbox into a GPU texture. At transition kickoff we pin the
// SES (live: false) so its texture freezes at the outgoing frame, then
// animate its opacity 1 → 0 to dissolve into the live tree underneath,
// which has already updated reactively to the new content.
//
// outputKind selects which per-output settings the scene honors:
//   "primary" → transitionStyleForPrimary + transitionDurationMsForPrimary
//   "ndi"     → transitionStyleForNdi     + transitionDurationMsForNdi
//                (when outputMode==="dual"; in single mode NDI inherits
//                primary's scene wholesale, so these prefs aren't reached)
//   "stage"   → reserved for v1.1 multi-output stage monitor
//
// reduceMotion is the global accessibility override — when on, every
// output collapses to "cut" with 0 ms regardless of the per-output picks.
Item {
    id: scene

    property string outputKind: "primary"

    // Canvas-native render surface. NDI's grabber points at this so it
    // gets canvas-resolution pixels (1920×1080 by default) regardless of
    // how big the host window happens to be.
    property alias renderItem: stage

    // ── Per-output transition resolution ────────────────────────────────
    readonly property string _outStyle: {
        switch (outputKind) {
            case "ndi":   return SettingsService.transitionStyleForNdi
            case "stage": return SettingsService.transitionStyleForStage
            default:      return SettingsService.transitionStyleForPrimary
        }
    }
    readonly property int _outMs: {
        switch (outputKind) {
            case "ndi":   return SettingsService.transitionDurationMsForNdi
            case "stage": return SettingsService.transitionDurationMsForStage
            default:      return SettingsService.transitionDurationMsForPrimary
        }
    }
    readonly property string _style: SettingsService.reduceMotion ? "cut" : _outStyle
    readonly property int    _ms:    SettingsService.reduceMotion ? 0     : _outMs

    // Operator-facing duration for logo / clear-text fades. Couples to the
    // per-output style: picking "cut" collapses this to 0 so the entire
    // scene feels instant; otherwise inherits the per-output content
    // duration for consistent feel across the projection.
    readonly property int _transMs: _style === "cut" ? 0 : _ms

    // ── Reactive bindings to ProjectionService ──────────────────────────
    readonly property var    _item    : ProjectionService.currentItem
    readonly property string _kind    : ProjectionService.contentKind
    readonly property int    _page    : ProjectionService.pageIndex
    readonly property bool   _isClear : ProjectionService.isClear
    readonly property bool   _showLogo: ProjectionService.showLogo

    // True when the live item is itself a picture, movie, or PDF (vs a
    // song/scripture/presentation whose theme may have a media background).
    // For these, the entire stage = the media — no theme nodes overlay,
    // no no-theme fallback. The themed Repeater is gated off below.
    readonly property bool   _isMediaItem: {
        if (!_item) return false
        if (_kind === "image" || _kind === "video") {
            return (_item.mediaPath || "").length > 0
        }
        if (_kind === "pdf") {
            return (_item.mediaId || 0) > 0
        }
        return false
    }

    // Snapshot of the crop rectangle baked at goLive time. Songs/scriptures
    // always carry the identity {0,0,1,1}; only image/PDF items carry a
    // meaningful operator-authored crop.
    readonly property rect _cropRect: ProjectionService.cropRect

    // Theme resolution — bumps on default changes, theme adds/removes, the
    // outputMode toggle, and per-output theme writes.
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
        function onOutputModeChanged()         { scene._themeRevision++ }
        function onThemeIdForPrimaryChanged()  { scene._themeRevision++ }
        function onThemeIdForNdiChanged()      { scene._themeRevision++ }
        function onThemeIdForStageChanged()    { scene._themeRevision++ }
    }

    readonly property var _tokens : _theme && _theme.tokens ? _theme.tokens : ({})
    readonly property var _canvas : _tokens.canvas || ({ width: 1920, height: 1080 })
    readonly property var _nodes  : _tokens.nodes  || []

    // ── Content resolution ──────────────────────────────────────────────
    readonly property string _pageText: {
        if (!_item) return ""
        const pages = _item.pages
        if (!pages || pages.length === 0) return ""
        const idx = Math.min(_page, pages.length - 1)
        const p = pages[idx]
        return (p && p.content) || ""
    }
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

    readonly property var _sortedNodes: {
        const arr = _nodes.slice()
        arr.sort((a, b) => ((a.style && a.style.z) || 0) - ((b.style && b.style.z) || 0))
        return arr
    }

    // ── Letterbox: the visible canvas container ─────────────────────────
    Item {
        id: letterbox
        anchors.centerIn: parent
        readonly property real _scale: Math.min(parent.width  / scene._canvas.width,
                                                parent.height / scene._canvas.height)
        width:  scene._canvas.width  * _scale
        height: scene._canvas.height * _scale
        clip: true

        // ── Stage: the canvas-native render surface ─────────────────────
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

                MediaMonitor {
                    id: mediaItemMonitor
                    anchors.fill: parent
                    visible: scene._isMediaItem && (scene._kind === "image" || scene._kind === "video")
                    mediaKind: visible ? scene._kind : ""
                    mediaPath: visible ? (scene._item.mediaPath || "") : ""
                    muted:    scene.outputKind !== "primary"
                                || !OutputService.projectionOpen
                    crop: false
                    opacity: (scene._kind === "image"
                              && scene._cropRect !== Qt.rect(0, 0, 1, 1)) ? 0 : 1
                }

                Image {
                    id: imageCropApplier
                    anchors.fill: parent
                    visible: scene._isMediaItem
                             && scene._kind === "image"
                             && scene._cropRect !== Qt.rect(0, 0, 1, 1)
                    source: visible ? "file:///" + (scene._item.mediaPath || "") : ""
                    asynchronous: false
                    cache: true
                    fillMode: Image.PreserveAspectFit
                    sourceClipRect: {
                        if (!visible || sourceSize.width <= 0 || sourceSize.height <= 0) {
                            return Qt.rect(0, 0, 0, 0)
                        }
                        const c = scene._cropRect
                        return Qt.rect(c.x * sourceSize.width,
                                       c.y * sourceSize.height,
                                       c.width  * sourceSize.width,
                                       c.height * sourceSize.height)
                    }
                }

                Image {
                    id: pdfPageImage
                    anchors.fill: parent
                    visible: scene._isMediaItem && scene._kind === "pdf"
                    asynchronous: true
                    cache: true
                    retainWhileLoading: true
                    sourceSize.width:  stage.width
                    sourceSize.height: stage.height
                    source: {
                        if (!visible || !scene._item) return ""
                        const id   = Number(scene._item.mediaId || 0)
                        const page = Math.max(0, scene._page)
                        const c    = scene._cropRect
                        return "image://pdfpage/" + id
                             + "?page=" + page
                             + "&cx="   + c.x
                             + "&cy="   + c.y
                             + "&cw="   + c.width
                             + "&ch="   + c.height
                    }
                    fillMode: Image.PreserveAspectFit
                }

                Repeater {
                    model: scene._isMediaItem ? [] : scene._sortedNodes
                    delegate: Item {
                        id: nodeWrap
                        readonly property var _style: modelData.style || ({})
                        x:        stage.width  * ((_style.x      || 0) / 100)
                        y:        stage.height * ((_style.y      || 0) / 100)
                        width:    stage.width  * ((_style.width  || 0) / 100)
                        height:   stage.height * ((_style.height || 0) / 100)
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

            // ── Logo overlay ────────────────────────────────────────────
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

    // ────────────────────────────────────────────────────────────────────
    // Live → live content transitions (GPU-side snapshot overlay).
    //
    // A ShaderEffectSource sibling of letterbox continuously mirrors
    // letterbox into a GPU texture (live: true). At transition kickoff we
    // flip live: false to PIN the texture at the last-rendered frame
    // (= the outgoing content), set opacity to 1, and animate it → 0.
    // The live tree's bindings update naturally to the new content and
    // repaint underneath; the fade reveals it.
    //
    // Filter via _buildTag: ProjectionService.stateChanged fires for many
    // reasons (goLive, clear, page, logo, crop). We only want transitions
    // on item/page/crop/kind changes; logo and clear toggles have their
    // own per-element fades and would double-animate otherwise.

    function _itemIdentity(item, kind) {
        if (!item) return ""
        switch (kind) {
            case "song":
                return "song:" + (item.songId || 0)
            case "scripture": {
                const r = item.scriptureRef
                if (!r) return "scripture:" + (item.title || "")
                return "scripture:"
                     + (r.translationCode || "") + ":"
                     + (r.book || "")            + ":"
                     + (r.chapter || 0)          + ":"
                     + (r.verseStart || 0)       + "-"
                     + (r.verseEnd || 0)
            }
            case "image":
            case "video":
                return kind + ":" + (item.mediaPath || "")
            case "pdf":
                return "pdf:" + (item.mediaId || 0)
        }
        return kind + ":" + (item.title || "")
    }
    function _buildTag(item, kind, page, crop) {
        return scene._itemIdentity(item, kind)
             + "|" + kind
             + "|" + page
             + "|" + crop.x + "," + crop.y + "," + crop.width + "," + crop.height
    }
    property string _lastTag: ""

    Component.onCompleted: {
        // Seed the tag without firing a transition — the initial content
        // (which may already be live if the scene re-opens mid-service)
        // shouldn't animate in from black.
        scene._lastTag = scene._buildTag(scene._item, scene._kind,
                                         scene._page, scene._cropRect)
    }

    function _runTransition() {
        if (scene._style === "cut" || scene._ms <= 0) {
            outgoingSnapshot.opacity = 0
            outgoingSnapshot.live    = true
            stage.opacity            = 1   // always-restored after fadeBlack
            return
        }

        // Pin SES at the last-rendered frame (the outgoing content). The
        // GUI thread is in the middle of the stateChanged handler so the
        // live tree HAS NOT yet repainted with the new bindings — the SES
        // texture currently holds the outgoing frame.
        outgoingSnapshot.live    = false
        outgoingSnapshot.opacity = 1

        if (scene._style === "fadeBlack") {
            // Hide live tree underneath the snapshot for phase 1. When the
            // snapshot finishes fading to 0, the user sees the Window's
            // black background until phase 2 fades stage back to 1.
            stage.opacity = 0
            fadeBlackAnim.restart()
        } else {
            stage.opacity = 1   // ensure visible under the crossfade
            crossfadeAnim.restart()
        }
    }

    // GPU-resident snapshot of letterbox. Sibling of letterbox in the
    // declaration order so it renders on top.
    ShaderEffectSource {
        id: outgoingSnapshot
        anchors.fill: letterbox
        sourceItem: letterbox
        hideSource: false
        live: true
        opacity: 0
        visible: scene.visible
    }

    // Crossfade animation: single-property fade on the snapshot. The live
    // tree underneath stays at full opacity throughout — the visual
    // crossfade emerges from the snapshot dissolving over it.
    NumberAnimation {
        id: crossfadeAnim
        target: outgoingSnapshot
        property: "opacity"
        to: 0
        duration: scene._ms
        easing.type: Easing.InOutCubic
        onFinished: outgoingSnapshot.live = true
    }

    // Fade-through-black: snapshot fades over phase 1 (live tree is
    // hidden at opacity 0 underneath, so the user sees the snapshot
    // dissolving to the Window's black background). Phase 2 fades the
    // live tree from 0 back to 1, emerging from black. Each phase gets
    // half the total so the operator's mental model — "duration is how
    // long the whole transition takes" — holds across styles.
    SequentialAnimation {
        id: fadeBlackAnim
        NumberAnimation {
            target: outgoingSnapshot
            property: "opacity"
            to: 0
            duration: Math.max(1, scene._ms / 2)
            easing.type: Easing.InOutCubic
        }
        NumberAnimation {
            target: stage
            property: "opacity"
            to: 1
            duration: Math.max(1, scene._ms / 2)
            easing.type: Easing.InOutCubic
        }
        onFinished: outgoingSnapshot.live = true
    }

    // Item/page/crop/kind changes trigger transitions. logo/clear toggles
    // also fire stateChanged but don't change the tag, so _runTransition
    // is skipped — those continue to use their own per-element fades.
    //
    // Back-to-back transitions (operator clicks faster than _ms) DO NOT
    // interrupt the in-flight animation. Qt's Animation.stop() doesn't
    // fire onFinished, so interrupting would leave the SES pinned at the
    // OLD-OLD frame from before the current transition (producing the
    // "cut to a slide that isn't in the song" visual). Letting the fade
    // complete is also better UX: the live tree's bindings update
    // instantly, so the in-flight fade dissolves into the LATEST content
    // and intermediate clicks are visually skipped.
    Connections {
        target: ProjectionService
        function onStateChanged() {
            const newTag = scene._buildTag(scene._item, scene._kind,
                                           scene._page, scene._cropRect)
            if (newTag === scene._lastTag) return
            scene._lastTag = newTag
            if (crossfadeAnim.running || fadeBlackAnim.running) return
            scene._runTransition()
        }
    }
}
