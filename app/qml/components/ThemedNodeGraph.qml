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
//   - dimHidden       : the theme editor's canvas only. Draws nodes the author
//                       hid (data.hidden) at 30% so they stay findable.
//
// The theme editor renders its canvas through this graph too, so a card
// looks the same there as on the output. It reads each node's laid-out rect
// back (layoutRectOf / layoutRoleOf) to put its selection chrome on it, and
// pushes per-node style edits through updateNode() so a drag doesn't rebuild
// every delegate the way reassigning `nodes` would.
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
    property bool dimHidden: false

    // ── Motion (data.motion, see NodeMotion.qml) ────────────────────────
    // motionEnabled: play the nodes' entry / exit specs. Off for thumbnails;
    //   the live output turns it on unless Reduce Motion is set.
    // shown: whether the theme is up. Only read when the theme has motion:
    //   the scene flips it to bring a motion theme in and take it out node
    //   by node, where a theme without motion is faded as one layer.
    // clearAll: Clear takes every node off, not only text (Settings >
    //   Projection > Clear hides).
    // swapText: a text change on a node that's in place fades the old text
    //   out and the new one in, instead of the whole layer crossfading. Only
    //   the live output sets it; the editor changes text as you type.
    property bool motionEnabled: false
    property bool shown: true
    property bool clearAll: false
    property bool swapText: false

    readonly property bool hasMotion: motionEnabled && _anyMotion(_sortedNodes)
    function _anyMotion(ns) {
        for (let i = 0; i < ns.length; i++) {
            const mo = ns[i].data && ns[i].data.motion
            if (mo && (mo.in || mo.out)) return true
        }
        return false
    }

    // How long the theme takes to come in or go out: the slowest node,
    // delays included. The scene waits this long before it calls a
    // transition done.
    function entryMs() { return _slowest(true) }
    function exitMs()  { return _slowest(false) }
    function _slowest(entry) {
        let ms = 0
        for (let i = 0; i < nodeRepeater.count; i++) {
            const it = nodeRepeater.itemAt(i)
            if (it) ms = Math.max(ms, it.motionItem.phaseMs(entry))
        }
        return ms
    }

    // Theme editor preview: play every node's entry (or exit) from the start.
    function replay(entry) {
        for (let i = 0; i < nodeRepeater.count; i++) {
            const it = nodeRepeater.itemAt(i)
            if (it) it.motionItem.replay(entry)
        }
    }

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
    // under short verses. Each node exposes its CONTENT rect — where its text
    // ACTUALLY renders after verticalAlign + auto-fit, not its box — as
    // contentTop / contentBottom on its delegate. Hug / stack align to
    // content, so a container can wrap auto-fit text without ever resizing
    // the text's box (which is what broke auto-fit in the first design).
    // Containers expose their whole box as content.
    //
    // Dependents read those properties straight off the source's delegate,
    // so a node's layout depends only on the nodes it names. (A shared map
    // with one revision counter made every stacked node depend on every
    // node's publish, its own included: moving it bumped the counter its
    // own position was computed from, a binding loop on every layout.)
    // _itemsRev only moves when a delegate comes or goes.
    property var _itemsById: ({})
    property int _itemsRev: 0
    // A node naming itself, or two nodes naming each other (A stacks on B
    // while B hugs A), can't be laid out: each edge would be computed from
    // the other. Those references are ignored and the nodes keep their
    // configured box.
    function _rectOf(id, selfId) {
        _itemsRev   // dep: the source's delegate may not exist yet
        if (!id || id === selfId) return null
        const it = _itemsById[id]
        if (!it || _names(it, selfId)) return null
        return { contentTop: it.contentTop, contentBottom: it.contentBottom }
    }
    function _names(item, id) {
        const ap = item._ap, ah = item._ah
        return (!!ap && ap.source === id)
            || (!!ah && (ah.source === id || ah.from === id || ah.to === id))
    }

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

    // ── Laid-out rects (read by the theme editor) ───────────────────────
    // Every delegate publishes the box it actually rendered at, in this
    // Item's pixels, after card stacking / hug / stack have been applied.
    property var _layoutRects: ({})
    property int _layoutRectsRev: 0
    function _publishLayoutRect(id, x, y, w, h) {
        if (!id) return
        const c = _layoutRects[id]
        if (c && Math.abs(c.x - x) < 0.01 && Math.abs(c.y - y) < 0.01
              && Math.abs(c.width - w) < 0.01 && Math.abs(c.height - h) < 0.01) return
        _layoutRects[id] = { x: x, y: y, width: w, height: h }
        _layoutRectsRev++
    }
    function layoutRectOf(id) { _layoutRectsRev; return _layoutRects[id] || null }   // dep

    // How a node's geometry is decided, which is what the editor needs to
    // know to pick its handles:
    //   "member" : placed and sized by the card that lists it
    //   "group"  : a card; its height hugs its members
    //   "hug"    : data.autoHeight, height follows content
    //   "stack"  : data.autoPosition, top follows another node
    //   ""       : plain percent box
    function layoutRoleOf(id) {
        if (_groupParentOf(id)) return "member"
        const ns = root._sortedNodes
        for (let i = 0; i < ns.length; i++) {
            if (ns[i].id !== id) continue
            const d = ns[i].data || {}
            if (d.group && d.group.members && d.group.members.length > 0) return "group"
            if (d.autoHeight)   return "hug"
            if (d.autoPosition) return "stack"
            return ""
        }
        return ""
    }

    // Swap one node's snapshot in place. Only for edits that leave the
    // layout wiring alone (style, text); a change to z, group, autoHeight or
    // autoPosition must go through `nodes` so ordering and roles recompute.
    function updateNode(n) {
        if (!n || !n.id) return
        for (let i = 0; i < nodeRepeater.count; i++) {
            const it = nodeRepeater.itemAt(i)
            if (it && it._nodeId === n.id) { it.node = n; return }
        }
    }

    // ── Themed node graph ───────────────────────────────────────────────
    // Each node renders inside its own delegate sized to its percent-of-stage
    // rectangle, with skew handled by a center-origin Matrix4x4 that matches
    // the editor's NodeDelegate.
    Repeater {
        id: nodeRepeater
        model: root._sortedNodes
        delegate: Item {
            id: nodeWrap
            // Starts as the model entry; updateNode() may replace it.
            property var node: modelData
            readonly property var    _style:  node.style || ({})
            readonly property var    _data:   node.data  || ({})
            readonly property string _nodeId: node.id || ""
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
                    const fr = root._rectOf(_ah.from, _nodeId), tr = root._rectOf(_ah.to, _nodeId)
                    if (fr && tr) return Math.max(0, (tr.contentBottom - fr.contentTop) + padT + padB)
                    return _baseH
                }
                if (_ah.source === "self" || _ah.source === _nodeId)
                    return Math.max(0, measuredPx + padT + padB)
                const sr = root._rectOf(_ah.source, _nodeId)
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
                    const sr = root._rectOf(_ap.source, _nodeId)
                    if (sr) {
                        const gap = _pct(_ap.gap)
                        if (_ap.place === "above") return sr.contentTop - gap - _cbRel
                        if (_ap.place === "below") return sr.contentBottom + gap - _ctRel
                    }
                    // source not measured yet → fall through
                }
                if (_ah) {
                    if (_ah.from && _ah.to) {
                        const fr = root._rectOf(_ah.from, _nodeId)
                        return fr ? (fr.contentTop - _pct(_ah.padTop)) : _baseY
                    }
                    if (!(_ah.source === "self" || _ah.source === _nodeId)) {
                        const sr = root._rectOf(_ah.source, _nodeId)
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

            // The CONTENT rect other nodes hug / stack against (containers
            // expose their whole box). See _rectOf. A card exposes the box
            // it hugs to, and a card member the slot the card gave it, so an
            // accent bar that hugs the card, or a label stacked above a
            // member, follows the card as its text grows.
            readonly property real contentTop:
                groupComp ? groupComp.top
              : _myLayout ? _myLayout.y
              : measuredPx <= 0 ? _effTop : _effTop + _ctRel
            readonly property real contentBottom:
                groupComp ? groupComp.top + groupComp.height
              : _myLayout ? _myLayout.y + measuredPx
              : measuredPx <= 0 ? _effTop + _effHeight : contentTop + measuredPx

            onYChanged:          _publishBox()
            onHeightChanged:     _publishBox()
            onMeasuredPxChanged: root._publishMeasured(_nodeId, measuredPx)   // for group stacking
            onXChanged:          _publishBox()
            onWidthChanged:      _publishBox()
            Component.onCompleted: {
                _displayText = _resolved
                if (_nodeId) {
                    root._itemsById[_nodeId] = nodeWrap
                    root._itemsRev++
                }
                root._publishMeasured(_nodeId, measuredPx)
                _publishBox()
            }
            Component.onDestruction: {
                if (root._itemsById[_nodeId] === nodeWrap) {
                    delete root._itemsById[_nodeId]
                    root._itemsRev++
                }
            }

            // The rendered box, for the editor's selection chrome.
            function _publishBox() { root._publishLayoutRect(_nodeId, x, y, width, height) }

            // Geometry: a group CONTAINER takes its hugged box from groupComp; a
            // group MEMBER takes its slot from the card (height = its content);
            // everything else uses the autoHeight / autoPosition result.
            x:        _myLayout ? _myLayout.x : _baseX
            y:        groupComp ? groupComp.top : (_myLayout ? _myLayout.y : _effTop)
            width:    _myLayout ? _myLayout.w : _baseW
            height:   groupComp ? groupComp.height : (_myLayout ? measuredPx : _effHeight)
            opacity:  (_style.opacity !== undefined ? _style.opacity : 1)
                      * ((root.dimHidden && _data.hidden) ? 0.3 : 1)
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

            // ── Verse swap ──────────────────────────────────────────────
            // With swapText on a motion theme, new text on a node that's in
            // place fades the old text out and the new text in (motion.swap,
            // default 160 ms out and 260 ms in) while the rest of the theme
            // stays put. Otherwise the text just lands, which is all a
            // theme without motion ever did here (its layer crossfades).
            readonly property string _resolved: root.resolveText(node)
            // Not bound to _resolved: a binding would show the new text
            // before the old one had faded out.
            property string _displayText: ""
            readonly property var _swapSpec: (_data.motion && _data.motion.swap) || ({})
            on_ResolvedChanged: {
                if (root.swapText && root.hasMotion && node.kind === "text"
                        && motionItem.settled && _displayText !== _resolved) {
                    swapAnim.restart()
                } else {
                    swapAnim.stop()
                    swapLayer.opacity = 1
                    _displayText = _resolved
                }
            }
            SequentialAnimation {
                id: swapAnim
                NumberAnimation {
                    target: swapLayer; property: "opacity"; to: 0
                    duration: Math.max(0, nodeWrap._swapSpec.out !== undefined ? nodeWrap._swapSpec.out : 160)
                    easing.type: Easing.InCubic
                }
                ScriptAction { script: nodeWrap._displayText = nodeWrap._resolved }
                NumberAnimation {
                    target: swapLayer; property: "opacity"; to: 1
                    duration: Math.max(0, nodeWrap._swapSpec.in !== undefined ? nodeWrap._swapSpec.in : 260)
                    easing.type: Easing.OutCubic
                }
            }

            // A card that changes height when its verse swaps eases to the
            // new size instead of jumping, and its members ride along. Only
            // once the theme is in place, so the first layout never slides.
            readonly property bool _smoothLayout: root.swapText && root.hasMotion
                && (groupComp !== null || _myLayout !== null || _ah !== null || _ap !== null)
                && motionItem.settled
            Behavior on y      { enabled: nodeWrap._smoothLayout; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
            Behavior on height { enabled: nodeWrap._smoothLayout; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

            property alias motionItem: motionItem

            // The other column of a split screen slide (ThemeTokens
            // deriveSplitNodes): the same text on the other side, bound to
            // the ...Right linkage or back from it. Null for everything else.
            readonly property int naturalFitPx: renderer.naturalFitPx
            readonly property var _splitPartner: {
                root._itemsRev   // dep: partners register as they're built
                const l = (node && node.kind === "text" && _data.linkage) || ""
                let other = ""
                if (l === "scriptureText" || l === "scriptureRef") other = _nodeId + "-right"
                else if ((l === "scriptureTextRight" || l === "scriptureRefRight") && _nodeId.endsWith("-right"))
                    other = _nodeId.slice(0, -6)
                if (!other) return null
                const p = root._itemsById[other]
                return (p && p.node && p.node.kind === "text") ? p : null
            }

            // Whether this node should be on screen. Clear takes text off,
            // or every node when clearAll is set. On a motion theme the
            // scene's `shown` brings the whole theme in and out as well.
            //
            // The fade or motion sits in its own Item, apart from the outer
            // Item's opacity, so theme-editor edits to style.opacity still
            // snap while Clear and motion animate. A node without a motion
            // spec fades over the scene's Clear duration, so a Cut gives an
            // instant clear.
            NodeMotion {
                id: motionItem
                anchors.fill: parent
                spec: nodeWrap._data.motion || null
                motionOn: root.motionEnabled
                fallbackMs: root.passiveFadeMs
                // Reads the node list, not root.hasMotion: the Repeater makes
                // a new theme's delegates before hasMotion has caught up, and
                // a node that read the stale value would start in place
                // instead of waiting to play its entry.
                wantIn: (!(root.motionEnabled && root._anyMotion(root._sortedNodes)) || root.shown)
                        && !(root.clearActive && (root.clearAll || nodeWrap.node.kind === "text"))

                Item {
                    id: swapLayer
                    anchors.fill: parent

                    NodeRenderer {
                        id: renderer
                        anchors.fill: parent
                        node: nodeWrap.node
                        resolvedText: nodeWrap._displayText
                        suppressAnimations: root.suppressAnimations
                        autoPlayVideos: root.autoPlayVideos
                        // In a card, the member's box is its hugged content height,
                        // so auto-fit must measure against its OWN configured height
                        // instead (its max region) — else fit↔box would loop.
                        fitHeightOverride: nodeWrap._myLayout ? nodeWrap._baseH : 0
                        // The two columns of a split screen slide read at one
                        // size: each is capped at the other's natural fit.
                        fitCap: nodeWrap._splitPartner ? nodeWrap._splitPartner.naturalFitPx : 0
                    }
                }
            }
        }
    }
}
