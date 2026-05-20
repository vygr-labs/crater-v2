import QtQuick
import Crater

// Figma-style spacing overlay for the theme editor canvas.
//
// With a node selected, Alt+hovering a *different* node draws the four
// edge-gap measurements between the selected node and the hovered one,
// labelled in the theme's canvas pixels. Pure view — it reads node
// geometry off the WorkingTheme and never mutates anything, so it has
// no interaction with undo/history.
//
// Mounted inside EditorCanvas's `stage` (the canvas-native-coordinate
// Item), filling it, above the node delegates.
Item {
    id: overlay

    property var  workspace
    property real stageW: 0          // stage pixel size (canvas px × zoom)
    property real stageH: 0
    property real canvasW: 1920      // theme canvas resolution — for labels
    property real canvasH: 1080

    // Measurement accent — a dedicated pink, distinct from `live` crimson
    // (which carries destructive / on-air meaning) so a measurement line
    // never reads as an error. Matches the measure-overlay colour
    // convention in Figma / Sketch. Scoped to this file rather than
    // promoted to a Theme token — it has exactly one consumer.
    readonly property color _measure: "#ff4d6d"

    // ── Source + target nodes ───────────────────────────────────────────
    readonly property var _sel: (workspace && workspace.selectedNodeId)
        ? workspace.workingTheme.node(workspace.selectedNodeId) : null
    readonly property var _tgt: (workspace && workspace.hoveredNodeId)
        ? workspace.workingTheme.node(workspace.hoveredNodeId) : null

    visible: !!workspace && workspace.measureAlt
          && !!_sel && !!_tgt
          && workspace.selectedNodeId !== workspace.hoveredNodeId

    // Non-interactive — never eats hover/click meant for the nodes below.
    enabled: false

    // Selected / target style maps (geometry in percent of canvas).
    readonly property var _s: _sel && _sel.style ? _sel.style : ({})
    readonly property var _t: _tgt && _tgt.style ? _tgt.style : ({})

    // Percent → canvas-pixel rounding for the labels.
    function _pxX(pct) { return Math.round(pct / 100 * canvasW) }
    function _pxY(pct) { return Math.round(pct / 100 * canvasH) }

    // ── Measurement segments ────────────────────────────────────────────
    // The display depends on how the selected node S and the hovered
    // node T sit relative to each other:
    //
    //   • Separated on an axis  → draw the GAP between their nearest
    //     edges on that axis. Separated on BOTH axes (diagonally apart)
    //     → an L: a horizontal gap segment + a vertical one, meeting at
    //     S's nearest corner — "the gap to the nearest corner."
    //   • Overlapping on both axes (nested / intersecting) → draw the
    //     four edge insets — the padding between matching edges.
    //
    // Segment shape: { horiz, a, b, pos, label } — a line from `a` to `b`
    // along its axis, offset to `pos` on the cross axis. All values in
    // stage pixels except `label` (canvas pixels).
    readonly property var _segments: {
        if (!visible) return []

        // Edges in percent space.
        const sL = (_s.x || 0), sR = sL + (_s.width  || 0)
        const sT = (_s.y || 0), sB = sT + (_s.height || 0)
        const tL = (_t.x || 0), tR = tL + (_t.width  || 0)
        const tT = (_t.y || 0), tB = tT + (_t.height || 0)

        // percent → stage pixels
        const PX = function(p) { return stageW * p / 100 }
        const PY = function(p) { return stageH * p / 100 }

        // Axis gaps (percent). 0 ⇒ the rects overlap on that axis.
        // xa/xb, ya/yb capture the gap span's start/end edge.
        let xGap = 0, xa = 0, xb = 0
        if (sR < tL)      { xGap = tL - sR; xa = sR; xb = tL }
        else if (tR < sL) { xGap = sL - tR; xa = tR; xb = sL }
        let yGap = 0, ya = 0, yb = 0
        if (sB < tT)      { yGap = tT - sB; ya = sB; yb = tT }
        else if (tB < sT) { yGap = sT - tB; ya = tB; yb = sT }

        const out = []

        if (xGap > 0 || yGap > 0) {
            // ── Separated: gap segment(s) ──
            if (xGap > 0) {
                // Horizontal segment's Y: aligned to S's near edge when
                // also Y-separated (the L corner); centered in the shared
                // Y band when the rects overlap vertically.
                const yPos = (yGap > 0) ? (sB < tT ? sB : sT)
                                        : (Math.max(sT, tT) + Math.min(sB, tB)) / 2
                out.push({ horiz: true, a: PX(xa), b: PX(xb), pos: PY(yPos),
                           label: _pxX(xGap) })
            }
            if (yGap > 0) {
                const xPos = (xGap > 0) ? (sR < tL ? sR : sL)
                                        : (Math.max(sL, tL) + Math.min(sR, tR)) / 2
                out.push({ horiz: false, a: PY(ya), b: PY(yb), pos: PX(xPos),
                           label: _pxY(yGap) })
            }
        } else {
            // ── Overlapping / nested: four edge insets ──
            // Magnitudes — the line position already conveys which side.
            const cy = PY((sT + sB) / 2)
            const cx = PX((sL + sR) / 2)
            out.push({ horiz: true,  a: PX(tL), b: PX(sL), pos: cy,
                       label: _pxX(Math.abs(sL - tL)) })
            out.push({ horiz: true,  a: PX(sR), b: PX(tR), pos: cy,
                       label: _pxX(Math.abs(tR - sR)) })
            out.push({ horiz: false, a: PY(tT), b: PY(sT), pos: cx,
                       label: _pxY(Math.abs(sT - tT)) })
            out.push({ horiz: false, a: PY(sB), b: PY(tB), pos: cx,
                       label: _pxY(Math.abs(tB - sB)) })
        }
        return out
    }

    Repeater {
        model: overlay._segments
        delegate: Item {
            readonly property bool  _h:   modelData.horiz
            readonly property real  _lo:  Math.min(modelData.a, modelData.b)
            readonly property real  _hi:  Math.max(modelData.a, modelData.b)
            readonly property real  _len: _hi - _lo

            // A zero-length gap has nothing to show — collapse it.
            visible: _len > 0.5

            x:      _h ? _lo          : modelData.pos
            y:      _h ? modelData.pos : _lo
            width:  _h ? _len : 1
            height: _h ? 1    : _len

            // The measurement line itself.
            Rectangle { anchors.fill: parent; color: overlay._measure }

            // Perpendicular end caps — small ticks at each end so the
            // segment reads as a measured span, not an arbitrary line.
            Rectangle {
                color: overlay._measure
                width:  _h ? 1 : 7
                height: _h ? 7 : 1
                x: _h ? -0.5 : -3
                y: _h ? -3   : -0.5
            }
            Rectangle {
                color: overlay._measure
                width:  _h ? 1 : 7
                height: _h ? 7 : 1
                x: _h ? parent.width - 0.5 : -3
                y: _h ? -3 : parent.height - 0.5
            }

            // Pixel-value chip, centered on the segment.
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                width:  _lbl.implicitWidth  + 8
                height: _lbl.implicitHeight + 4
                radius: 0
                color: overlay._measure
                Text {
                    id: _lbl
                    anchors.centerIn: parent
                    text: modelData.label
                    color: "#ffffff"
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.microSize
                    font.weight: Theme.font.weightSemiBold
                }
            }
        }
    }
}
