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
    // workingTheme.node(id) returns a value SNAPSHOT, not a live handle.
    // Bind only to the id and the snapshot freezes at whatever geometry
    // the node had when the id last changed — so dragging a node (which
    // fires nodeStyleChanged, not an id change) leaves the overlay
    // measuring its pre-drag position. _tick is bumped on every
    // WorkingTheme mutation and read inside the _sel / _tgt bindings, so
    // they re-fetch fresh geometry. Same pattern PropertiesPanel
    // (_refreshTick) and NodeDelegate use — node() is snapshot-based, so
    // every QML reader must subscribe to the mutation signals.
    property int _tick: 0
    Connections {
        target: workspace ? workspace.workingTheme : null
        function onNodeStyleChanged(id, field) { overlay._tick++ }
        function onNodeDataChanged(id, field)  { overlay._tick++ }
        function onNodesChanged()              { overlay._tick++ }
    }

    readonly property var _sel: {
        _tick   // dependency — re-fetch on any node mutation
        return (workspace && workspace.selectedNodeId)
            ? workspace.workingTheme.node(workspace.selectedNodeId) : null
    }
    readonly property var _tgt: {
        _tick
        return (workspace && workspace.hoveredNodeId)
            ? workspace.workingTheme.node(workspace.hoveredNodeId) : null
    }

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
    //   • Separated on an axis  → draw the GAP between the nearest edges.
    //     Separated on both axes → a horizontal + a vertical gap line.
    //   • Overlapping on both axes (nested) → draw the four edge insets.
    //
    // Cross-axis placement for the nested insets uses the centre of the
    // OVERLAP band — for nested boxes that is the inner box's centre, so
    // the inset lines run through the inner node regardless of which box
    // is the selected one.
    //
    // Segment shape: { horiz, a, b, pos, label } — a line from `a` to `b`
    // along its axis, offset to `pos` on the cross axis. Stage pixels
    // except `label` (canvas pixels).
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
            // Lines run through the overlap band's centre — i.e. the
            // inner box's centre — so they stay attached to the inner
            // node even when the outer box is the selected one.
            const cy = PY((Math.max(sT, tT) + Math.min(sB, tB)) / 2)
            const cx = PX((Math.max(sL, tL) + Math.min(sR, tR)) / 2)
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

    // Hovered node's box outline. The selected node already shows its
    // (cyan) selection chrome; the hovered node has none — so the inset
    // measurements appeared to span to nothing. Drawing the hovered box
    // makes the four insets visibly connect two rectangles, so a nested
    // overlap reads as "padding between these boxes" rather than a
    // mysterious set of numbers.
    Rectangle {
        x:      stageW * ((overlay._t.x || 0) / 100)
        y:      stageH * ((overlay._t.y || 0) / 100)
        width:  stageW * ((overlay._t.width  || 0) / 100)
        height: stageH * ((overlay._t.height || 0) / 100)
        color: "transparent"
        border.color: overlay._measure
        border.width: 1
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
