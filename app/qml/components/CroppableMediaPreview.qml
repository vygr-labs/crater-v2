import QtQuick
import QtQuick.Window
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
//   • Drag a corner handle       → resize from that corner.
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
        sourceSize.width:
            root.width  > 0 ? Math.ceil(root.width  * Screen.devicePixelRatio) : 1920
        sourceSize.height:
            root.height > 0 ? Math.ceil(root.height * Screen.devicePixelRatio) : 1080
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

    // ── Drag interaction ────────────────────────────────────────────────
    MouseArea {
        id: dragArea
        anchors.fill: parent
        hoverEnabled: true   // so cursorShape tracks the hovered zone pre-click
        cursorShape: {
            const m = _hitTest(Qt.point(mouseX, mouseY))
            if (m === "resize") return Qt.SizeFDiagCursor
            if (m === "move")   return Qt.SizeAllCursor
            return Qt.CrossCursor
        }

        property string mode: "idle"          // idle | draw | move | resize
        property int    activeCorner: -1
        property real   startMouseX: 0
        property real   startMouseY: 0
        property real   startNx: 0
        property real   startNy: 0
        property real   startNw: 0
        property real   startNh: 0
        property bool   shiftHeld: false

        function _hitTest(pt) {
            const x = root._pxX(), y = root._pxY()
            const w = root._pxW(), h = root._pxH()
            const corners = [
                Qt.point(x, y), Qt.point(x + w, y),
                Qt.point(x + w, y + h), Qt.point(x, y + h)
            ]
            for (let i = 0; i < 4; ++i) {
                if (Math.abs(pt.x - corners[i].x) <= 8
                 && Math.abs(pt.y - corners[i].y) <= 8) {
                    activeCorner = i
                    return "resize"
                }
            }
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
                if (activeCorner === 0)      { nx += dx; ny += dy; nw -= dx; nh -= dy }
                else if (activeCorner === 1) {           ny += dy; nw += dx; nh -= dy }
                else if (activeCorner === 2) {                     nw += dx; nh += dy }
                else if (activeCorner === 3) { nx += dx;           nw -= dx; nh += dy }
                if (!shiftHeld) {
                    const s = root._applyAspect(nw, nh)
                    if (activeCorner === 0) {
                        nx = (startNx * cr.width)  + (startNw * cr.width)  - s.width
                        ny = (startNy * cr.height) + (startNh * cr.height) - s.height
                    } else if (activeCorner === 1) {
                        ny = (startNy * cr.height) + (startNh * cr.height) - s.height
                    } else if (activeCorner === 3) {
                        nx = (startNx * cr.width)  + (startNw * cr.width)  - s.width
                    }
                    nw = s.width; nh = s.height
                }
                root._setFromPx(cr.x + nx, cr.y + ny, nw, nh)
                return
            }
        }

        onReleased: { mode = "idle"; activeCorner = -1 }
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
