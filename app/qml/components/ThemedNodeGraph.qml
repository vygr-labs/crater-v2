import QtQuick
import Crater

// The themed node graph — lays a theme's nodes (containers + text) out inside
// the rectangle it fills, INCLUDING the cross-node auto-layout: group/card
// stacking, autoHeight (hug content), and autoPosition (stack relative to
// another node). Extracted from ProjectionContentLayer so the live projection
// output and the ThemesTab thumbnails render through ONE renderer and can
// never drift apart again — that drift is exactly what made card-based themes
// preview wrong (nodes at their pre-stack boxes, overlapping) while looking
// correct on the live output.
//
// The caller sizes this Item to the canvas-scaled layer (anchors.fill a
// letterboxed stage / the live layer) and supplies:
//   - nodes           : the theme's node array (unsorted; sorted by z here)
//   - resolveTextFn   : function(node) -> string. Live maps linkage to the
//                       current ProjectionService content; the preview maps it
//                       to deterministic mock strings. Kept as a function so
//                       this component stays content-agnostic.
//   - autoPlayVideos  : false for thumbnail grids (don't spin up a video
//                       decoder + gradient animation per tile).
//   - suppressAnimations / clearActive / passiveFadeMs : see below.
//
// Percent-of-canvas geometry resolves against this Item's own width/height, so
// the caller is responsible only for sizing it to the canvas rectangle.
Item {
    id: root

    // ── Inputs ───────────────────────────────────────────────────────────
    property var  nodes: []
    property var  resolveTextFn: null
    property bool autoPlayVideos: true
    property bool suppressAnimations: false
    // Clear-fade gate. The live projection "clear" blanks text nodes (the
    // scene drives this from ProjectionService.isClear). Preview never clears.
    property bool clearActive: false
    property int  passiveFadeMs: 280

    function resolveText(node) {
        return root.resolveTextFn ? root.resolveTextFn(node) : ""
    }

    // Pre-sort nodes by z so render order matches layer order. Recomputes when
    // `nodes` changes — cheap for ≤50 nodes per theme.
    readonly property var _sortedNodes: {
        const arr = (root.nodes || []).slice()
        arr.sort((a, b) => ((a.style && a.style.z) || 0) - ((b.style && b.style.z) || 0))
        return arr
    }

    // ── Cross-node auto-layout (hug / stack) ────────────────────────────
    // A container can hug a text node's measured content height
    // (data.autoHeight), and any node can position relative to another
    // (data.autoPosition). Together these make a bottom-anchored lower-third
    // "card" whose height tracks the verse length, killing the dead space
    // under short verses. Each node publishes its computed pixel rect + its
    // measured content height here, keyed by node id; dependents read it.
    // _rectsRev forces re-evaluation (a plain JS map is not deeply reactive).
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
    // Each node renders inside its own delegate sized to its percent-of-stage
    // rectangle, with skew handled by a center-origin Matrix4x4 that matches
    // the editor's NodeDelegate.
    Repeater {
        model: root._sortedNodes
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
            // its members by measured content, hugs the total, and anchors the
            // hugged card inside its configured box. Members keep their own
            // auto-fit (bounded by their own height) and are positioned by the
            // card.
            //
            // data.group.anchor picks WHERE the hugged card sits in that box:
            //
            //   "bottom" (default) — the card's bottom edge pins to the box
            //     bottom and the card grows upward. This is the lower-third
            //     scripture/song card: the screen margin under the text is
            //     fixed, so a long verse eats space above rather than sliding
            //     the whole block down toward the screen edge.
            //
            //   "center" — the card centers vertically in the box and grows
            //     both ways. This is what slide content wants: a presentation
            //     with a title and two lines and a presentation with a title
            //     and eight lines should both look centered, not both hang
            //     from the same lower edge. Bottom-anchoring a title-only
            //     slide would drop a single heading to the floor of its box.
            //
            // Additive: an unrecognised or absent anchor keeps the original
            // bottom behaviour, so every existing theme lays out unchanged.
            readonly property var _group: _data.group || null
            readonly property var _groupMembers: (_group && _group.members) ? _group.members : []
            readonly property var groupComp: {
                if (!_group || _groupMembers.length === 0) return null
                const padT = _pct(_group.padTop), padB = _pct(_group.padBottom)
                const padX = parent.width * ((_group.padX || 0) / 100)
                const gap  = _pct(_group.gap)
                const contentW = _baseW - 2 * padX
                let total = padT + padB + Math.max(0, _groupMembers.length - 1) * gap
                const heights = []
                for (let i = 0; i < _groupMembers.length; i++) {
                    const h = root._measuredHOf(_groupMembers[i])
                    heights.push(h); total += h
                }
                // Anchor the hugged card inside the configured box. Only the
                // card's TOP is computed differently; everything downstream
                // (member stacking, published layout, the container's own
                // painted rect) reads cardTop, so the two modes share one path.
                const cardTop = (_group.anchor === "center")
                    ? (_baseY + (_baseH - total) / 2)
                    : (_baseY + _baseH - total)
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
            // TEXT node AND the projection is cleared (clearActive). Non-text
            // nodes (image backgrounds, decorative shapes) stay visible during
            // a clear. Separated from the outer Item's opacity so theme-editor
            // edits to style.opacity continue to snap (no Behavior there), while
            // clear is animated. Duration follows the scene's passive-fade so a
            // cut style yields an instant clear.
            Item {
                anchors.fill: parent
                opacity: (root.clearActive && modelData.kind === "text") ? 0 : 1
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
                    suppressAnimations: root.suppressAnimations
                    autoPlayVideos: root.autoPlayVideos
                    // In a card, the member's box is its hugged content height,
                    // so auto-fit must measure against its OWN configured height
                    // instead (its max region) — else fit↔box would loop.
                    fitHeightOverride: nodeWrap._myLayout ? nodeWrap._baseH : 0
                }
            }
        }
    }
}
