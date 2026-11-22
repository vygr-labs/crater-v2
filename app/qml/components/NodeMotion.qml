// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2024-2026 Eyetu Kingsley. Part of Crater, see LICENSE and NOTICE.

import QtQuick

// Plays one theme node's entry and exit (data.motion.in / .out). The node's
// content goes inside; this Item fills the node's box.
//
// `wantIn` says whether the node should be on screen. When it flips, the
// matching phase plays: entry when it turns true, exit when it turns false.
// Progress `p` runs 0 (gone) to 1 (in place), and each type reads it its
// own way:
//
//   fade  : opacity
//   slide : opacity, plus an offset of `distance` canvas px toward `edge`
//           (an entry from the bottom rises, an exit to the bottom sinks)
//   wipe  : a clip that reveals from `edge`, nothing fades
//   grow  : a scale from `edge` (left/right/center stretch across, top and
//           bottom stretch down and up)
//
// A node with no spec for a phase fades over `fallbackMs`, which the graph
// sets to the output's Clear duration. That is also what every node does
// when motion is off (`motionOn` false): exactly the Clear fade text nodes
// always had, so a theme without motion looks the same as before.
//
// A node created while the graph is up appears in place without playing,
// and one created while hidden starts hidden, so rebuilding a layer never
// replays anything by itself. replay() is for the theme editor's preview.
Item {
    id: m

    property var  spec: null         // node.data.motion, or null
    property bool motionOn: false
    property bool wantIn: true
    property int  fallbackMs: 280
    default property alias content: inner.data

    // 0 = gone, 1 = in place. Set from Component.onCompleted and then only
    // by the animation, so it never has a binding to break.
    property real p: 1
    // Which phase the visuals read: true while coming in or in place.
    property bool entering: true
    readonly property bool running: delayTimer.running || moveStep.running
    // In place and not moving. The graph uses this to decide whether a text
    // change plays the swap fade or just lands.
    readonly property bool settled: p >= 0.999 && !running

    readonly property var _inSpec:  (motionOn && spec && spec.in)  ? spec.in  : null
    readonly property var _outSpec: (motionOn && spec && spec.out) ? spec.out : null
    readonly property var _phase:   entering ? _inSpec : _outSpec
    readonly property string _type: _phase ? (_phase.type || "fade") : "fade"
    readonly property string _edge: _phase ? (_phase.edge || _defaultEdge(_type)) : "bottom"
    readonly property real _distance: {
        if (!_phase) return 0
        if (_phase.distance !== undefined) return _phase.distance
        return entering ? 28 : 16
    }

    function _defaultEdge(type) { return type === "slide" ? "bottom" : "left" }

    // How long a phase takes, delay included. The graph adds these up to
    // know when a layer has finished coming in or going out.
    function phaseMs(entry) {
        const s = entry ? _inSpec : _outSpec
        if (!s) return fallbackMs
        return Math.max(0, s.delay || 0) + Math.max(0, _durationOf(s, entry))
    }
    function _durationOf(s, entry) {
        if (s.duration !== undefined) return s.duration
        return entry ? 500 : 320
    }

    // ── Easing ─────────────────────────────────────────────────────────
    // "smooth" is cubic-bezier(0.2, 0.8, 0.2, 1): fast off the mark and a
    // long settle, the curve broadcast lower thirds tend to use. A spec can
    // also give its own CSS cubic-bezier as [x1, y1, x2, y2].
    function _easingType(e) {
        if (Array.isArray(e)) return Easing.BezierSpline
        switch (e) {
            case "linear": return Easing.Linear
            case "in":     return Easing.InCubic
            case "out":    return Easing.OutCubic
            case "inOut":  return Easing.InOutCubic
            case "back":   return Easing.OutBack
        }
        return Easing.BezierSpline
    }
    function _curve(e) {
        const c = Array.isArray(e) ? e : [0.2, 0.8, 0.2, 1]
        return [c[0], c[1], c[2], c[3], 1, 1]
    }

    function _stop() {
        delayTimer.stop()
        moveStep.stop()
    }

    function _play(entry) {
        _stop()
        returnTimer.stop()
        _returnAfter = false
        entering = entry
        const s = entry ? _inSpec : _outSpec
        let delay = 0
        if (!s) {
            moveStep.duration = Math.max(0, fallbackMs)
            moveStep.easing.type = Easing.InOutCubic
        } else {
            const e = s.easing !== undefined ? s.easing : (entry ? "smooth" : "in")
            delay = Math.max(0, s.delay || 0)
            moveStep.duration = Math.max(0, _durationOf(s, entry))
            moveStep.easing.type = _easingType(e)
            if (moveStep.easing.type === Easing.BezierSpline)
                moveStep.easing.bezierCurve = _curve(e)
        }
        moveStep.to = entry ? 1 : 0
        if (delay > 0) {
            delayTimer.interval = delay
            delayTimer.start()
        } else if (moveStep.duration > 0) {
            moveStep.start()
        } else {
            p = moveStep.to
        }
    }

    // Theme editor preview: snap to the far end, then play toward this one.
    // An exit comes back into place a moment later, so the canvas isn't
    // left empty.
    property bool _returnAfter: false
    function replay(entry) {
        _stop()
        entering = entry
        p = entry ? 0 : 1
        _play(entry)
        _returnAfter = !entry
        if (!entry && !running) returnTimer.restart()
    }
    Timer {
        id: returnTimer
        interval: 700
        onTriggered: { m._returnAfter = false; m.entering = true; m.p = 1 }
    }

    onWantInChanged: _play(wantIn)
    // The starting state wins over anything that played while the node was
    // being built. wantIn can flip once during construction, and the
    // animation that started then would keep its captured start value and
    // write it back over this on its first frame.
    Component.onCompleted: { _stop(); entering = wantIn; p = wantIn ? 1 : 0 }

    // The delay is a Timer in front of a standalone animation, not a
    // PauseAnimation in a SequentialAnimation: restarting a group that was
    // stopped during its pause, with new durations, jumped the move almost
    // to its end, so a delayed entry that interrupted a delayed exit showed
    // up in place instead of playing.
    Timer {
        id: delayTimer
        onTriggered: {
            if (moveStep.duration > 0) moveStep.start()
            else m.p = moveStep.to
        }
    }
    NumberAnimation {
        id: moveStep
        target: m; property: "p"; duration: 0
        onFinished: if (m._returnAfter) returnTimer.restart()
    }

    // ── Visuals ────────────────────────────────────────────────────────
    readonly property bool _fades: _type === "fade" || _type === "slide"
    readonly property real _travel: (1 - p) * _distance
    readonly property bool _horizontalGrow:
        _edge === "left" || _edge === "right" || _edge === "center"

    opacity: _fades ? p : (p > 0 ? 1 : 0)

    // Wipe: a clip box that grows from the edge. The content inside is
    // shifted back by the same amount so it stays put while the box moves.
    // Clipping only while the wipe is partway keeps a shadow or outline that
    // spills past the node's box from being cut off once it's in place.
    Item {
        id: clipper
        readonly property bool wiping: m._type === "wipe" && m.p < 0.999
        readonly property real _w: m.width  * (wiping && m._horizontalGrow ? m.p : 1)
        readonly property real _h: m.height * (wiping && !m._horizontalGrow ? m.p : 1)
        clip: wiping
        width:  wiping ? _w : m.width
        height: wiping ? _h : m.height
        x: wiping && m._edge === "right"  ? m.width  - _w : 0
        y: wiping && m._edge === "bottom" ? m.height - _h : 0

        Item {
            id: inner
            x: -clipper.x
            y: -clipper.y
            width:  m.width
            height: m.height

            transform: [
                Translate {
                    x: m._type !== "slide" ? 0
                       : m._edge === "left" ? -m._travel : m._edge === "right" ? m._travel : 0
                    y: m._type !== "slide" ? 0
                       : m._edge === "top" ? -m._travel : m._edge === "bottom" ? m._travel : 0
                },
                Scale {
                    readonly property bool on: m._type === "grow"
                    origin.x: m._edge === "right" ? m.width : m._edge === "center" ? m.width / 2 : 0
                    origin.y: m._edge === "bottom" ? m.height : 0
                    xScale: on && m._horizontalGrow ? Math.max(0.0001, m.p) : 1
                    yScale: on && !m._horizontalGrow ? Math.max(0.0001, m.p) : 1
                }
            ]
        }
    }
}
