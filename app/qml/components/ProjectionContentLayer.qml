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

    // ── Cross-node auto-layout (hug / stack) ────────────────────────────
    // A container can hug a text node's measured content height
    // (data.autoHeight), and any node can position relative to another
    // (data.autoPosition). Together these make a bottom-anchored lower-third
    // "card" whose height tracks the verse length, killing the dead space
    // under short verses. Each node publishes its computed pixel rect + its
    // measured content height here, keyed by node id; dependents read it.
    // _rectsRev forces re-evaluation (a plain JS map is not deeply reactive).
    // Per-layer (previousLayer / currentLayer each own one), which is correct —
    // each layer hugs its own content independently through a transition.
    property var _nodeRects: ({})
    property int _rectsRev: 0
    // Publishes a node's CONTENT rect — where its text ACTUALLY renders after
    // verticalAlign + auto-fit, not its box. Hug / stack align to content, so a
    // container can wrap auto-fit text without ever resizing the text's box
    // (which is what broke auto-fit in the first design). Containers publish
    // their whole box as content.
    function _publishRect(id, contentTop, contentBottom) {
        if (!id) return
        const c = _nodeRects[id]
        if (c && Math.abs(c.contentTop - contentTop) < 0.01
              && Math.abs(c.contentBottom - contentBottom) < 0.01) return
        _nodeRects[id] = { contentTop: contentTop, contentBottom: contentBottom }
        _rectsRev++
    }
    function _rectOf(id) { _rectsRev; return _nodeRects[id] || null }   // _rectsRev = dep

    // ── Group / card layout registries ──────────────────────────────────
    // A "group" container (data.group) stacks its member nodes, hugs the total,
    // and bottom-anchors. Members publish their measured content height here; the
    // container reads them, computes the stack + hugged card, and publishes each
    // member's position back. Two maps + revisions (plain JS maps aren't
    // reactive). This replaces the fragile cross-node content-rect reconstruction
    // for cards — the container owns the layout, so alignment is exact.
    property var _measuredH: ({})
    property int _measRev: 0
    function _publishMeasured(id, h) {
        if (!id) return
        if (_measuredH[id] !== undefined && Math.abs(_measuredH[id] - h) < 0.01) return
        _measuredH[id] = h; _measRev++
    }
    function _measuredHOf(id) { _measRev; return _measuredH[id] || 0 }   // _measRev = dep

    property var _memberLayout: ({})
    property int _layoutRev: 0
    function _publishMemberLayout(id, lay) {
        if (!id) return
        const c = _memberLayout[id]
        if (c && Math.abs(c.x - lay.x) < 0.01 && Math.abs(c.y - lay.y) < 0.01
              && Math.abs(c.w - lay.w) < 0.01) return
        _memberLayout[id] = { x: lay.x, y: lay.y, w: lay.w }; _layoutRev++
    }
    function _memberLayoutOf(id) { _layoutRev; return _memberLayout[id] || null }   // dep

    // Which group container (if any) lists this node id as a member.
    function _groupParentOf(id) {
        const ns = root._sortedNodes
        for (let i = 0; i < ns.length; i++) {
            const g = ns[i].data && ns[i].data.group
            if (g && g.members && g.members.indexOf(id) >= 0) return ns[i].id
        }
        return ""
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
            readonly property var    _style:  modelData.style || ({})
            readonly property var    _data:   modelData.data  || ({})
            readonly property string _nodeId: modelData.id || ""
            readonly property string _vAlign: _style.verticalAlign || "center"

            // Configured (authored) rect, in layer px.
            readonly property real _baseX: parent.width  * ((_style.x      || 0) / 100)
            readonly property real _baseY: parent.height * ((_style.y      || 0) / 100)
            readonly property real _baseW: parent.width  * ((_style.width  || 0) / 100)
            readonly property real _baseH: parent.height * ((_style.height || 0) / 100)

            // Measured text content height (px); 0 for containers.
            readonly property real measuredPx: renderer.contentHeightPx
            function _pct(v) { return parent.height * ((v || 0) / 100) }

            // ── Auto-height (hug content) ───────────────────────────────
            // Wraps another node's CONTENT (not box), so the hugged text keeps
            // auto-fitting. Forms (pads in %):
            //   { source:"<id>", padTop, padBottom }              wrap one node
            //   { from:"<id>", to:"<id>", padTop, padBottom }     span two nodes
            //   { source:"self", anchor, padTop, padBottom }      hug own content
            readonly property var  _ah: _data.autoHeight || null
            readonly property real _effHeight: {
                if (!_ah) return _baseH
                const padT = _pct(_ah.padTop), padB = _pct(_ah.padBottom)
                if (_ah.from && _ah.to) {
                    const fr = root._rectOf(_ah.from), tr = root._rectOf(_ah.to)
                    if (fr && tr) return Math.max(0, (tr.contentBottom - fr.contentTop) + padT + padB)
                    return _baseH
                }
                if (_ah.source === "self" || _ah.source === _nodeId)
                    return Math.max(0, measuredPx + padT + padB)
                const sr = root._rectOf(_ah.source)
                if (sr) return Math.max(0, (sr.contentBottom - sr.contentTop) + padT + padB)
                return _baseH
            }

            // This node's own content bottom / top, relative to its box top —
            // used to align THIS node's content edge in autoPosition, and to
            // publish its content rect. Driven by verticalAlign + measuredPx.
            readonly property real _cbRel:
                _vAlign === "end"   ? _effHeight
              : _vAlign === "start" ? measuredPx
                                    : (_effHeight + measuredPx) / 2
            readonly property real _ctRel:
                _vAlign === "end"   ? _effHeight - measuredPx
              : _vAlign === "start" ? 0
                                    : (_effHeight - measuredPx) / 2

            // ── Auto-position (stack relative to another node) ──────────
            // data.autoPosition = { place:"above"|"below", source:"<id>", gap }.
            // Aligns THIS node's content edge to the source's content edge.
            readonly property var  _ap: _data.autoPosition || null
            readonly property real _effTop: {
                if (_ap) {
                    const sr = root._rectOf(_ap.source)
                    if (sr) {
                        const gap = _pct(_ap.gap)
                        if (_ap.place === "above") return sr.contentTop - gap - _cbRel
                        if (_ap.place === "below") return sr.contentBottom + gap - _ctRel
                    }
                    // source not measured yet → fall through
                }
                if (_ah) {
                    if (_ah.from && _ah.to) {
                        const fr = root._rectOf(_ah.from)
                        return fr ? (fr.contentTop - _pct(_ah.padTop)) : _baseY
                    }
                    if (!(_ah.source === "self" || _ah.source === _nodeId)) {
                        const sr = root._rectOf(_ah.source)
                        return sr ? (sr.contentTop - _pct(_ah.padTop)) : _baseY
                    }
                    // self-hug → anchor to own configured box edge
                    const anchor = _ah.anchor || "bottom"
                    if (anchor === "bottom") return (_baseY + _baseH) - _effHeight
                    if (anchor === "center") return (_baseY + _baseH / 2) - _effHeight / 2
                    return _baseY   // "top"
                }
                return _baseY
            }

            // ── Group / card layout ─────────────────────────────────────
            // This node is a group CONTAINER when it has data.group: it stacks
            // its members by measured content, hugs the total, and bottom-anchors
            // to its configured box bottom. Members keep their own auto-fit
            // (bounded by their own height) and are positioned by the card.
            readonly property var _group: _data.group || null
            readonly property var _groupMembers: (_group && _group.members) ? _group.members : []
            readonly property var groupComp: {
                if (!_group || _groupMembers.length === 0) return null
                const padT = _pct(_group.padTop), padB = _pct(_group.padBottom)
                const padX = parent.width * ((_group.padX || 0) / 100)
                const gap  = _pct(_group.gap)
                const contentW = _baseW - 2 * padX
                const cardBottom = _baseY + _baseH      // bottom-anchored here
                let total = padT + padB + Math.max(0, _groupMembers.length - 1) * gap
                const heights = []
                for (let i = 0; i < _groupMembers.length; i++) {
                    const h = root._measuredHOf(_groupMembers[i])
                    heights.push(h); total += h
                }
                const cardTop = cardBottom - total
                const lay = {}
                let y = cardTop + padT
                for (let i = 0; i < _groupMembers.length; i++) {
                    lay[_groupMembers[i]] = { x: _baseX + padX, y: y, w: contentW }
                    y += heights[i] + gap
                }
                return { top: cardTop, height: total, layout: lay }
            }
            onGroupCompChanged: {
                if (!groupComp) return
                for (const mid in groupComp.layout)
                    root._publishMemberLayout(mid, groupComp.layout[mid])
            }

            // This node is a group MEMBER when some group lists it: its box +
            // position come from the card, and it auto-fits to its OWN height.
            readonly property string _groupParent: root._groupParentOf(_nodeId)
            readonly property var    _myLayout: _groupParent ? root._memberLayoutOf(_nodeId) : null

            // Publish the CONTENT rect (containers expose their whole box).
            // y / height are bound to _effTop / _effHeight, so onYChanged /
            // onHeightChanged catch geometry moves; onMeasuredPxChanged catches
            // a remeasure that didn't move this node's box. _publishRect de-dupes.
            function _publish() {
                const top = _effTop, h = _effHeight
                const cTop = (measuredPx <= 0) ? top : (top + _ctRel)
                const cBot = (measuredPx <= 0) ? (top + h) : (cTop + measuredPx)
                root._publishRect(_nodeId, cTop, cBot)
                root._publishMeasured(_nodeId, measuredPx)   // for group stacking
            }
            onYChanged:          _publish()
            onHeightChanged:     _publish()
            onMeasuredPxChanged: _publish()
            Component.onCompleted: _publish()

            // Geometry: a group CONTAINER takes its hugged box from groupComp; a
            // group MEMBER takes its slot from the card (height = its content);
            // everything else uses the autoHeight / autoPosition result.
            x:        _myLayout ? _myLayout.x : _baseX
            y:        groupComp ? groupComp.top : (_myLayout ? _myLayout.y : _effTop)
            width:    _myLayout ? _myLayout.w : _baseW
            height:   groupComp ? groupComp.height : (_myLayout ? measuredPx : _effHeight)
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
                    id: renderer
                    anchors.fill: parent
                    node: modelData
                    resolvedText: root.resolveText(modelData)
                    // In a card, the member's box is its hugged content height,
                    // so auto-fit must measure against its OWN configured height
                    // instead (its max region) — else fit↔box would loop.
                    fitHeightOverride: nodeWrap._myLayout ? nodeWrap._baseH : 0
                }
            }
        }
    }
}
