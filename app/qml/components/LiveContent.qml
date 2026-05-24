import QtQuick
import Crater

// One render layer for a frozen ProjectionService snapshot. ProjectionScene
// instantiates two of these (A/B) so live state changes crossfade between
// the outgoing snapshot and the incoming one. Reads from props — NOT from
// ProjectionService directly — which is the whole point: two layers can
// hold two different snapshots simultaneously while the parent animates
// their opacities.
//
// The render tree mirrors the previous monolithic contentLayer inside
// ProjectionScene (MediaMonitor / image crop applier / PDF page / theme
// node Repeater / no-theme fallback). Only the binding sources change:
// instead of `ProjectionService.currentItem`, it's `layer.item`; instead
// of `scene._isClear`, it's `layer.isClear`, and so on. Per-text-node
// clear fade is gone — the A/B swap on the parent IS the clear fade now.
Item {
    // Using `root` rather than `layer` — the latter collides with the
    // built-in `layer` attached property on every Item (Item.layer.enabled,
    // Item.layer.samples, etc.) and the QML compiler resolves a bare
    // `layer.foo` to that attached object first, which would mean none of
    // this Item's exposed properties are reachable via the id we'd want.
    id: root

    // ── Frozen snapshot of one ProjectionService state ──────────────────
    property var    item     : ({})
    property string kind     : ""
    property int    page     : 0
    property bool   isClear  : false
    property rect   cropRect : Qt.rect(0, 0, 1, 1)

    // Pass-throughs from the parent scene. outputKind drives theme
    // resolution + audio muting (NDI layer always muted — see notes inside
    // MediaMonitor below). themeRevision bumps when SettingsService theme
    // assignments change so the binding under `_theme` re-evaluates without
    // requiring a re-Go-Live.
    property string outputKind    : "primary"
    property int    themeRevision : 0

    // ── Derived ──────────────────────────────────────────────────────────
    readonly property bool _isMediaItem: {
        if (!item) return false
        if (kind === "image" || kind === "video") {
            return (item.mediaPath || "").length > 0
        }
        if (kind === "pdf") {
            return (item.mediaId || 0) > 0
        }
        return false
    }

    readonly property var _theme: {
        themeRevision
        return AppState.resolveItemTheme(item, outputKind)
    }
    readonly property var _tokens : _theme && _theme.tokens ? _theme.tokens : ({})
    readonly property var _nodes  : _tokens.nodes  || []

    readonly property string _pageText: {
        if (!item) return ""
        const pages = item.pages
        if (!pages || pages.length === 0) return ""
        const idx = Math.min(page, pages.length - 1)
        const p = pages[idx]
        return (p && p.content) || ""
    }
    readonly property string _refText: {
        if (!item) return ""
        return item.title || item.reference || ""
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

    // ── Media-item branch ────────────────────────────────────────────────
    // When the live item IS an image/video, this is the entire stage —
    // theme nodes are gated off below. PDF takes the parallel branch via
    // pdfPageImage. The opacity gate on the cropApplier sibling hides this
    // monitor when a non-default crop has been baked in.
    MediaMonitor {
        id: mediaItemMonitor
        anchors.fill: parent
        visible: root._isMediaItem && (root.kind === "image" || root.kind === "video")
        mediaKind: visible ? root.kind : ""
        mediaPath: visible ? (root.item.mediaPath || "") : ""
        // Only the audience-facing scene unmutes, and only while the
        // projection window is actually visible. NDI carries audio at the
        // SDK layer; we don't want this player double-driving the system
        // audio bus from the NDI scene. The shared MediaPlaybackService
        // takes the OR of all subscribers' wantsAudio votes, so muting
        // here is a real "this layer doesn't want audio."
        muted: root.outputKind !== "primary"
            || !OutputService.projectionOpen
        crop: false
        opacity: (root.kind === "image"
                  && root.cropRect !== Qt.rect(0, 0, 1, 1)) ? 0 : 1
    }

    // ── Image crop applier ───────────────────────────────────────────────
    // sourceClipRect lifts a sub-region into the full stage when the
    // operator has baked a crop in via Preview + Enter. See
    // ProjectionScene's prior commentary for why this lives alongside the
    // MediaMonitor rather than inside it.
    Image {
        id: imageCropApplier
        anchors.fill: parent
        visible: root._isMediaItem
                 && root.kind === "image"
                 && root.cropRect !== Qt.rect(0, 0, 1, 1)
        source: visible ? "file:///" + (root.item.mediaPath || "") : ""
        asynchronous: false
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

    // ── PDF page renderer ────────────────────────────────────────────────
    Image {
        id: pdfPageImage
        anchors.fill: parent
        visible: root._isMediaItem && root.kind === "pdf"
        asynchronous: true
        cache: true
        // Keep the previously rasterised page on the layer while the next
        // page/crop rasterises async — without retainWhileLoading the
        // audience would see a blank flash on every page change.
        retainWhileLoading: true
        sourceSize.width:  parent.width
        sourceSize.height: parent.height
        source: {
            if (!visible || !root.item) return ""
            const id   = Number(root.item.mediaId || 0)
            const pg   = Math.max(0, root.page)
            const c    = root.cropRect
            return "image://pdfpage/" + id
                 + "?page=" + pg
                 + "&cx="   + c.x
                 + "&cy="   + c.y
                 + "&cw="   + c.width
                 + "&ch="   + c.height
        }
        fillMode: Image.PreserveAspectFit
    }

    // ── Theme node tree ─────────────────────────────────────────────────
    // Empty model for media items — the stage IS the media; theme nodes
    // would render on top of the video, which we never want.
    Repeater {
        model: root._isMediaItem ? [] : root._sortedNodes
        delegate: Item {
            id: nodeWrap
            readonly property var _style: modelData.style || ({})
            x:        root.width  * ((_style.x      || 0) / 100)
            y:        root.height * ((_style.y      || 0) / 100)
            width:    root.width  * ((_style.width  || 0) / 100)
            height:   root.height * ((_style.height || 0) / 100)
            // Text nodes hidden when isClear is set; non-text nodes
            // (containers, image backgrounds) stay visible. Snaps —
            // the A/B crossfade on the parent provides the animation.
            opacity:  (root.isClear && modelData.kind === "text")
                ? 0
                : (_style.opacity !== undefined ? _style.opacity : 1)
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

            NodeRenderer {
                anchors.fill: parent
                node: modelData
                resolvedText: root.resolveText(modelData)
            }
        }
    }

    // ── No-theme fallback ────────────────────────────────────────────────
    // Operator dropped a song/scripture but never set a default theme for
    // that kind and no built-in matches — without this, the audience would
    // see silent black. Lives inside the layer (rather than as a scene
    // sibling) so it crossfades naturally on item/theme changes.
    Text {
        id: noThemeText
        anchors.centerIn: parent
        anchors.margins: 40
        width: parent.width - 80
        visible: !root.isClear
              && (root.kind === "song" || root.kind === "scripture")
              && (!root._theme || (root._theme.id || 0) === 0)
        text: qsTr("Default %1 theme has not been set").arg(root.kind)
                   .toUpperCase()
        color: "#ffffff"
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        font.family: Theme.font.family
        font.pixelSize: 72
        font.weight: Theme.font.weightBold
    }
}
