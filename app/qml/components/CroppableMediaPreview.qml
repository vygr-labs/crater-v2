import QtQuick
import Crater

// Interactive crop-and-commit surface for image / PDF media items.
//
// A selection rectangle is ALWAYS shown — it defaults to the full page and
// persists across page changes and PDF switches, so the operator tweaks one
// rectangle rather than redrawing per document. The rectangle is snapshotted
// into ProjectionService at goLive() time — never read live by the
// projection scene — so an accidental drag during a service can't reframe
// the audience output (the edit-then-commit model from ARCHITECTURE.md §3).
//
// Inputs:
//   • item       — schedule-shape item (kind in {"image","pdf"}, mediaPath,
//                  mediaId, pageCount). For PDFs `pageIndex` selects the page.
//   • pageIndex  — current PDF page (0-based). Ignored for images.
//   • aspectLockEnabled / aspectLockW / aspectLockH — when locked, a resize
//                  snaps the rectangle to that aspect (default 16:9, the
//                  projection canvas aspect). Hold Shift while dragging to
//                  draw/resize free-form.
//
// Outputs:
//   • cropRect   — normalized 0..1 within the PAINTED PAGE (not the component
//                  bounds). {0,0,1,1} = whole page. Read by PreviewPanel and
//                  passed to ProjectionService.goLiveWithCrop on Enter.
//   • cropActive — true when the rectangle is narrower than the full page
//                  (drives the "press Enter to send" hint).
//
// Coordinate model:
//   The source image is letterboxed inside the component (PreserveAspectFit).
//   `_contentRect` is the rectangle where the page actually paints — read
//   from the Image's paintedWidth/paintedHeight. ALL crop math is normalized
//   to `_contentRect`, so dragging is constrained to the page and a crop
//   never lands on the black letterbox bars.
//
// Mouse:
//   • Drag inside the rectangle  → move it.
//   • Drag a corner handle       → resize from that corner (aspect-locked
//                                  to 16:9 unless Shift is held).
//   • Drag an edge / edge handle → resize that one side, free-form. A
//                                  single-axis drag IS the free-form case,
//                                  so edge resizes ignore the aspect lock.
//   • Drag on bare page          → draw a fresh rectangle.
// PDF page navigation is NOT handled here — the host panel owns the page
// buttons and drives `pageIndex`. This keeps the component page-source
// agnostic and free of any AppState coupling.
//
// Keyboard (when focused):
//   • Arrows                 → move rectangle 10px.
//   • Shift+Arrows           → fine move 1px.
//   • Ctrl+Arrows            → resize from bottom-right 10px.
//   • Ctrl+Shift+Arrows      → fine resize 1px.
//   • Esc / Backspace        → reset rectangle to the full page.
//   • Enter / Return         → commit (emit commitRequested()).
Item {
    id: root

    // ── Inputs ──────────────────────────────────────────────────────────
    property var    item: null
    property int    pageIndex: 0
    property real   aspectLockW: 16
    property real   aspectLockH: 9
    property bool   aspectLockEnabled: true

    // ── Outputs ─────────────────────────────────────────────────────────
    readonly property rect cropRect: Qt.rect(_normX, _normY, _normW, _normH)
    // "Active" means a real sub-crop (not the full page). The hint chrome
    // and the eventual goLive crop only matter once the operator has
    // actually narrowed the rectangle.
    readonly property bool cropActive:
        _normX > 0.002 || _normY > 0.002
        || _normW < 0.998 || _normH < 0.998

    signal commitRequested()
    signal cropChanged()
    // Emitted on any direct interaction (a press on the surface). The host
    // panel uses this to claim keyboard-focus ownership — without it the
    // window-level Enter shortcut routes to the wrong panel and the crop
    // is committed through a non-crop-aware code path.
    signal interacted()

    // ── Crop state — normalized 0..1 within the painted page ────────────
    // Defaults to the whole page. Deliberately NOT reset on item / page
    // change: the operator asked to keep one persistent rectangle they can
    // edit, rather than redrawing it for every PDF.
    property real _normX: 0
    property real _normY: 0
    property real _normW: 1
    property real _normH: 1

    on_NormXChanged: cropChanged()
    on_NormYChanged: cropChanged()
    on_NormWChanged: cropChanged()
    on_NormHChanged: cropChanged()

    // ── Background ──────────────────────────────────────────────────────
    Rectangle {
        anchors.fill: parent
        color: "#000000"
    }

    // ── Source surface ──────────────────────────────────────────────────
    // One Image element; the source URL switches by kind. Images load the
    // file directly (matches MediaMonitor); PDFs route through the
    // image://pdfpage/ provider. Both PreserveAspectFit so the whole page
    // is visible — the crop rectangle, not the viewport, is what projects.
    Image {
        id: sourceImage
        anchors.fill: parent
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        cache: true
        // Hold the current page painted while the next one rasterizes — a
        // PDF page render runs on a worker thread, so without this the
        // cropper flashes black on every page change and PDF switch.
        retainWhileLoading: true
        source: {
            if (!root.item) return ""
            const k = root.item.kind || ""
            if (k === "image") {
                return root.item.mediaPath
                           ? "file:///" + root.item.mediaPath : ""
            }
            if (k === "pdf") {
                return root.item.mediaId
                    ? "image://pdfpage/" + Number(root.item.mediaId).toString()
                      + "?page=" + Math.max(0, root.pageIndex)
                    : ""
            }
            return ""
        }
        // Fixed render target — deliberately NOT bound to the cropper's
        // (animating) size. The host monitorWrap animates its width/height
        // when a PDF is selected (PreviewPanel monitorWrap Behavior); a
        // size-tracking sourceSize re-requested a render on every animation
        // frame and flooded the worker pool. A stable target = one render.
        sourceSize.width:  1920
        sourceSize.height: 1080
    }

    // ── Painted-content rectangle ───────────────────────────────────────
    // Where the page actually draws inside the component, post-letterbox.
    // Read from the Image's paintedWidth/paintedHeight so it's exact for
    // any page aspect. Falls back to full bounds before the image loads.
    readonly property rect _contentRect: {
        const pw = sourceImage.paintedWidth
        const ph = sourceImage.paintedHeight
        if (pw > 1 && ph > 1) {
            return Qt.rect((width - pw) / 2, (height - ph) / 2, pw, ph)
        }
        return Qt.rect(0, 0, Math.max(1, width), Math.max(1, height))
    }

    // ── Geometry helpers (normalized 0..1 of content ↔ pixels) ──────────
    function _pxX() { return _contentRect.x + _normX * _contentRect.width  }
    function _pxY() { return _contentRect.y + _normY * _contentRect.height }
    function _pxW() { return _normW * _contentRect.width  }
    function _pxH() { return _normH * _contentRect.height }

    function _setFromPx(px, py, pw, ph) {
        const cr = _contentRect
        if (cr.width <= 0 || cr.height <= 0) return
        // Clamp to the painted page — a crop never strays onto the bars.
        let x = Math.max(cr.x, Math.min(px, cr.x + cr.width))
        let y = Math.max(cr.y, Math.min(py, cr.y + cr.height))
        let w = Math.max(0, Math.min(pw, cr.x + cr.width  - x))
        let h = Math.max(0, Math.min(ph, cr.y + cr.height - y))
        // Refuse degenerate rectangles — snap a sub-4px drag back to full.
        if (w < 4 || h < 4) { resetCrop(); return }
        root._normX = (x - cr.x) / cr.width
        root._normY = (y - cr.y) / cr.height
        root._normW = w / cr.width
        root._normH = h / cr.height
    }

    // Aspect-snap. Treats (pw, ph) as the operator's freehand delta and
    // grows the dimension dragged further to keep the locked aspect.
    function _applyAspect(pw, ph) {
        if (!root.aspectLockEnabled
            || root.aspectLockW <= 0 || root.aspectLockH <= 0) {
            return Qt.size(pw, ph)
        }
        const target = root.aspectLockW / root.aspectLockH
        if (ph === 0) return Qt.size(pw, ph)
        const cur = Math.abs(pw / ph)
        if (Math.abs(cur - target) < 0.01) return Qt.size(pw, ph)
        if (Math.abs(pw / target) > Math.abs(ph)) {
            return Qt.size(pw, (pw < 0 ? -1 : 1) * Math.abs(pw) / target)
        }
        return Qt.size((ph < 0 ? -1 : 1) * Math.abs(ph) * target, ph)
    }

    function resetCrop() {
        root._normX = 0; root._normY = 0; root._normW = 1; root._normH = 1
    }

    // ── Dim overlay (outside the crop rectangle) ────────────────────────
    // Four bands around the rectangle. Hidden when the crop is the full
    // page (nothing to dim).
    Rectangle {
        visible: root.cropActive
        color: "#000000"; opacity: 0.55
        anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
        height: root._pxY()
    }
    Rectangle {
        visible: root.cropActive
        color: "#000000"; opacity: 0.55
        anchors.left: parent.left; anchors.right: parent.right
        y: root._pxY() + root._pxH()
        height: Math.max(0, parent.height - (root._pxY() + root._pxH()))
    }
    Rectangle {
        visible: root.cropActive
        color: "#000000"; opacity: 0.55
        x: 0; y: root._pxY()
        width: root._pxX(); height: root._pxH()
    }
    Rectangle {
        visible: root.cropActive
        color: "#000000"; opacity: 0.55
        x: root._pxX() + root._pxW(); y: root._pxY()
        width: Math.max(0, parent.width - (root._pxX() + root._pxW()))
        height: root._pxH()
    }

    // ── Crop rectangle outline + corner handles ─────────────────────────
    Rectangle {
        id: cropFrame
        x: root._pxX(); y: root._pxY()
        width: root._pxW(); height: root._pxH()
        color: "transparent"
        border.color: Theme.color.brandHover
        border.width: 2
    }

    Repeater {
        model: 4
        Rectangle {
            readonly property int  corner: index   // 0 TL, 1 TR, 2 BR, 3 BL
            readonly property real hs: 7
            x: (corner === 0 || corner === 3)
                   ? root._pxX() - hs
                   : root._pxX() + root._pxW() - hs
            y: (corner === 0 || corner === 1)
                   ? root._pxY() - hs
                   : root._pxY() + root._pxH() - hs
            width: hs * 2; height: hs * 2
            color: Theme.color.brandHover
            border.color: "#ffffff"; border.width: 1
        }
    }

    // ── Edge handles ────────────────────────────────────────────────────
    // 4 top · 5 right · 6 bottom · 7 left. Short bars centered on each
    // side, kept visually lighter than the square corner grips so the
    // corners still read as the primary handles. The whole edge is the
    // hit zone (see _hitTest) — the bar is only an affordance hint.
    Repeater {
        model: 4
        Rectangle {
            readonly property int  edge: index + 4
            readonly property bool horizontal: edge === 4 || edge === 6
            width:  horizontal ? 18 : 6
            height: horizontal ? 6  : 18
            x: {
                if (edge === 5) return root._pxX() + root._pxW() - width / 2
                if (edge === 7) return root._pxX() - width / 2
                return root._pxX() + root._pxW() / 2 - width / 2
            }
            y: {
                if (edge === 4) return root._pxY() - height / 2
                if (edge === 6) return root._pxY() + root._pxH() - height / 2
                return root._pxY() + root._pxH() / 2 - height / 2
            }
            color: Theme.color.brandHover
            border.color: "#ffffff"; border.width: 1
        }
    }

    // ── Drag interaction ────────────────────────────────────────────────
    MouseArea {
        id: dragArea
        anchors.fill: parent
        hoverEnabled: true   // so cursorShape tracks the hovered zone pre-click
        cursorShape: {
            // While a drag is live the handle is fixed — reflect `mode`
            // directly and skip re-hit-testing. Otherwise the pointer
            // drifting off the grip mid-drag would reclassify activeHandle.
            const m = (mode === "idle") ? _hitTest(Qt.point(mouseX, mouseY))
                                        : mode
            if (m === "resize") {
                // 0/2 are the ╲ corners, 1/3 the ╱ corners, 4/6 the
                // horizontal edges, 5/7 the vertical edges.
                if (activeHandle === 0 || activeHandle === 2) return Qt.SizeFDiagCursor
                if (activeHandle === 1 || activeHandle === 3) return Qt.SizeBDiagCursor
                if (activeHandle === 4 || activeHandle === 6) return Qt.SizeVerCursor
                return Qt.SizeHorCursor
            }
            if (m === "move") return Qt.SizeAllCursor
            return Qt.CrossCursor
        }

        property string mode: "idle"          // idle | draw | move | resize
        property int    activeHandle: -1       // 0-3 corners TL/TR/BR/BL · 4-7 edges T/R/B/L
        property real   startMouseX: 0
        property real   startMouseY: 0
        property real   startNx: 0
        property real   startNy: 0
        property real   startNw: 0
        property real   startNh: 0
        property bool   shiftHeld: false

        // Hit zones in priority order: 4 corners, then 4 edges, then the
        // interior (move), then bare page (draw). Edges are grabbable along
        // their entire span — not just at the midpoint bar — so framing a
        // crop never turns into hunting for a 6px grip.
        //
        // Corner vs. edge near a vertex: a corner's tolerance box overlaps
        // ~8px of both adjoining edges. A press a few px in from a corner
        // but flush along one edge used to read as a corner resize and snap
        // to the aspect lock — the operator drags a side and the rectangle
        // jumps to 16:9. A corner is now claimed only for a genuinely
        // DIAGONAL press (near the vertex on both axes AND balanced between
        // them); a press committed to one edge is imbalanced, falls through,
        // and is matched to the NEAREST edge line — which resizes free-form.
        function _hitTest(pt) {
            const x = root._pxX(), y = root._pxY()
            const w = root._pxW(), h = root._pxH()
            const tol = 8

            // Perpendicular offset from each of the four edge lines.
            const dTop    = Math.abs(pt.y - y)
            const dBottom = Math.abs(pt.y - (y + h))
            const dLeft   = Math.abs(pt.x - x)
            const dRight  = Math.abs(pt.x - (x + w))

            // A corner grab is diagonal: within tol of the vertex on both
            // axes, and roughly balanced between them (|dx - dy| <= 3). A
            // press flush along an edge is imbalanced (one offset near zero,
            // the other larger) — it fails the third test and drops to the
            // edge matching below, so a side drag never aspect-snaps.
            function _isCorner(dx, dy) {
                return dx <= tol && dy <= tol && Math.abs(dx - dy) <= 3
            }
            if (_isCorner(dLeft,  dTop))    { activeHandle = 0; return "resize" }
            if (_isCorner(dRight, dTop))    { activeHandle = 1; return "resize" }
            if (_isCorner(dRight, dBottom)) { activeHandle = 2; return "resize" }
            if (_isCorner(dLeft,  dBottom)) { activeHandle = 3; return "resize" }

            // Edges: 4 top · 5 right · 6 bottom · 7 left. onSpan keeps the
            // hit within the edge's run (tol slack each end). Among the
            // sides in range, pick the one whose line the press sits
            // closest to — not the first match — so a press flush on one
            // side near a corner isn't stolen by the adjacent side.
            const onSpanX = pt.x >= x - tol && pt.x <= x + w + tol
            const onSpanY = pt.y >= y - tol && pt.y <= y + h + tol
            let edge = -1, best = tol + 1
            if (onSpanX && dTop    < best) { best = dTop;    edge = 4 }
            if (onSpanY && dRight  < best) { best = dRight;  edge = 5 }
            if (onSpanX && dBottom < best) { best = dBottom; edge = 6 }
            if (onSpanY && dLeft   < best) { best = dLeft;   edge = 7 }
            if (edge !== -1) { activeHandle = edge; return "resize" }

            if (pt.x >= x && pt.x <= x + w && pt.y >= y && pt.y <= y + h) {
                return "move"
            }
            return "draw"
        }

        onPressed: function(mouse) {
            root.forceActiveFocus()
            root.interacted()        // host claims preview keyboard focus
            startMouseX = mouse.x
            startMouseY = mouse.y
            shiftHeld   = (mouse.modifiers & Qt.ShiftModifier) !== 0
            startNx = root._normX; startNy = root._normY
            startNw = root._normW; startNh = root._normH
            mode = _hitTest(Qt.point(mouse.x, mouse.y))
        }

        onPositionChanged: function(mouse) {
            if (mode === "idle") return
            const dx = mouse.x - startMouseX
            const dy = mouse.y - startMouseY
            const cr = root._contentRect

            if (mode === "draw") {
                let pw = dx, ph = dy
                if (!shiftHeld) {
                    const s = root._applyAspect(pw, ph)
                    pw = s.width; ph = s.height
                }
                const x0 = pw < 0 ? startMouseX + pw : startMouseX
                const y0 = ph < 0 ? startMouseY + ph : startMouseY
                root._setFromPx(x0, y0, Math.abs(pw), Math.abs(ph))
                return
            }
            if (mode === "move") {
                const px = cr.x + (startNx * cr.width)  + dx
                const py = cr.y + (startNy * cr.height) + dy
                root._setFromPx(px, py, startNw * cr.width, startNh * cr.height)
                return
            }
            if (mode === "resize") {
                let nx = startNx * cr.width
                let ny = startNy * cr.height
                let nw = startNw * cr.width
                let nh = startNh * cr.height
                // Corners (0-3) drive two sides at once; edges (4-7) drive
                // exactly one, leaving the other three pinned.
                if (activeHandle === 0)      { nx += dx; ny += dy; nw -= dx; nh -= dy }
                else if (activeHandle === 1) {           ny += dy; nw += dx; nh -= dy }
                else if (activeHandle === 2) {                     nw += dx; nh += dy }
                else if (activeHandle === 3) { nx += dx;           nw -= dx; nh += dy }
                else if (activeHandle === 4) {           ny += dy;           nh -= dy }
                else if (activeHandle === 5) {                     nw += dx           }
                else if (activeHandle === 6) {                               nh += dy }
                else if (activeHandle === 7) { nx += dx;           nw -= dx           }
                // Aspect lock is a CORNER-only behavior. An edge drag is
                // single-axis by nature — that IS the free-form case the
                // operator wants — so edges never snap, lock on or off.
                if (!shiftHeld && activeHandle <= 3) {
                    const s = root._applyAspect(nw, nh)
                    if (activeHandle === 0) {
                        nx = (startNx * cr.width)  + (startNw * cr.width)  - s.width
                        ny = (startNy * cr.height) + (startNh * cr.height) - s.height
                    } else if (activeHandle === 1) {
                        ny = (startNy * cr.height) + (startNh * cr.height) - s.height
                    } else if (activeHandle === 3) {
                        nx = (startNx * cr.width)  + (startNw * cr.width)  - s.width
                    }
                    nw = s.width; nh = s.height
                }
                root._setFromPx(cr.x + nx, cr.y + ny, nw, nh)
                return
            }
        }

        onReleased: { mode = "idle"; activeHandle = -1 }
    }

    // ── First-render loading indicator ──────────────────────────────────
    // A PDF's first render is slow: pdfium cold-starts on the first call
    // of the session, and every render reopens the document from disk
    // (renderPdfPageBlocking builds a fresh QPdfDocument — the thread-
    // safety choice from ARCHITECTURE §3). retainWhileLoading covers
    // page-to-page swaps by holding the previous frame, but a cold open
    // has no previous frame, so without this the operator faces a black
    // void for several seconds. Gated on `paintedHeight < 1` so it shows
    // only on cold load — page swaps keep the retained frame painted and
    // never trigger the spinner.
    Item {
        id: loadingOverlay
        anchors.fill: parent
        visible: root.item !== null
                 && sourceImage.status === Image.Loading
                 && sourceImage.paintedHeight < 1

        Column {
            anchors.centerIn: parent
            spacing: Theme.space.sm

            AppIcon {
                anchors.horizontalCenter: parent.horizontalCenter
                name: "loader"
                size: Theme.icon.lg
                color: Theme.color.textTertiary
                RotationAnimator on rotation {
                    running: loadingOverlay.visible
                    from: 0; to: 360
                    duration: 900
                    loops: Animation.Infinite
                }
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: qsTr("Rendering page…")
                color: Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
            }
        }
    }

    // ── Keyboard refinement ─────────────────────────────────────────────
    // No `focus: true` — the cropper must not steal focus from the library
    // search bar on load. It gains active focus only when clicked (the drag
    // MouseArea calls forceActiveFocus), and Keys handling works from that
    // point on. Until then, arrow keys fall through to the window-level
    // preview page-nav shortcuts.
    Keys.onPressed: function(event) {
        const cr = root._contentRect
        const fine   = (event.modifiers & Qt.ShiftModifier)   !== 0
        const resize = (event.modifiers & Qt.ControlModifier) !== 0
        const step   = fine ? 1 : 10
        let nx = root._normX * cr.width
        let ny = root._normY * cr.height
        let nw = root._normW * cr.width
        let nh = root._normH * cr.height
        let moved = false

        switch (event.key) {
        case Qt.Key_Escape:
        case Qt.Key_Backspace:
            root.resetCrop()
            event.accepted = true
            return
        case Qt.Key_Return:
        case Qt.Key_Enter:
            root.commitRequested()
            event.accepted = true
            return
        case Qt.Key_Left:
            if (resize) nw -= step; else nx -= step; moved = true; break
        case Qt.Key_Right:
            if (resize) nw += step; else nx += step; moved = true; break
        case Qt.Key_Up:
            if (resize) nh -= step; else ny -= step; moved = true; break
        case Qt.Key_Down:
            if (resize) nh += step; else ny += step; moved = true; break
        default:
            return
        }
        if (moved) {
            event.accepted = true
            root._setFromPx(cr.x + nx, cr.y + ny, nw, nh)
        }
    }
}
