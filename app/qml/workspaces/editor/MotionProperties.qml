// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2024-2026 Eyetu Kingsley. Part of Crater, see LICENSE and NOTICE.

import QtQuick
import Crater

// Motion for the selected layer: how it comes in, how it goes out, and for
// text, how a verse change swaps it. Writes data.motion (see NodeMotion.qml
// for what each field does). A layer with no motion fades with Clear, as
// every layer did before motion existed.
//
// Play entry / Play exit run the whole design on the canvas, since a
// layer's timing only means something next to the others.
Column {
    id: root
    property var workspace
    property var node

    spacing: 6

    readonly property bool _isText: !!node && node.kind === "text"

    readonly property var _typeOptions: [
        { label: qsTr("None"),  value: "none"  },
        { label: qsTr("Fade"),  value: "fade"  },
        { label: qsTr("Slide"), value: "slide" },
        { label: qsTr("Wipe"),  value: "wipe"  },
        { label: qsTr("Grow"),  value: "grow"  }
    ]
    readonly property var _edgeOptions: [
        { label: qsTr("From the bottom"), value: "bottom" },
        { label: qsTr("From the top"),    value: "top"    },
        { label: qsTr("From the left"),   value: "left"   },
        { label: qsTr("From the right"),  value: "right"  }
    ]
    readonly property var _growEdgeOptions: _edgeOptions.concat([
        { label: qsTr("From the middle"), value: "center" }
    ])
    readonly property var _easingOptions: [
        { label: qsTr("Smooth"),      value: "smooth" },
        { label: qsTr("Ease out"),    value: "out"    },
        { label: qsTr("Ease in"),     value: "in"     },
        { label: qsTr("Ease in and out"), value: "inOut" },
        { label: qsTr("Overshoot"),   value: "back"   },
        { label: qsTr("Linear"),      value: "linear" }
    ]
    function _labelOf(opts, v) {
        for (let i = 0; i < opts.length; i++)
            if (opts[i].value === v) return opts[i].label
        // A custom curve from a theme file ([x1, y1, x2, y2]).
        return Array.isArray(v) ? qsTr("Custom curve") : String(v)
    }
    // The lists show labels and hold labels as their value, the way the
    // settings pickers do, so the open list highlights the current pick.
    function _valueOf(opts, label) {
        for (let i = 0; i < opts.length; i++)
            if (opts[i].label === label) return opts[i].value
        return label
    }
    function _labels(opts) { return opts.map(function(o) { return o.label }) }

    // ── Reading and writing data.motion ─────────────────────────────────
    function _motion() {
        const m = node && node.data && node.data.motion
        return m ? JSON.parse(JSON.stringify(m)) : ({})
    }
    function _phase(key) {
        const m = node && node.data && node.data.motion
        return (m && m[key]) || null
    }
    // A layer whose motion ends up empty stores null, not {}, so the
    // design reads as having no motion at all.
    function _write(m, commit) {
        const empty = !m.in && !m.out && !m.swap
        workspace.workingTheme.setNodeData(node.id, "motion", empty ? null : m)
        if (commit) workspace.saveToHistory()
    }
    function _setType(key, type) {
        const m = _motion()
        if (type === "none") {
            delete m[key]
        } else {
            const entry = key === "in"
            const was = m[key] || {}
            const ph = {
                type: type,
                duration: was.duration !== undefined ? was.duration : (entry ? 500 : 320),
                delay: was.delay || 0,
                easing: was.easing !== undefined ? was.easing : (entry ? "smooth" : "in")
            }
            if (type !== "fade") ph.edge = (was.edge && (was.edge !== "center" || type === "grow"))
                                           ? was.edge : (type === "slide" ? "bottom" : "left")
            if (type === "slide") ph.distance = was.distance !== undefined ? was.distance : (entry ? 28 : 16)
            m[key] = ph
        }
        _write(m, true)
    }
    function _setField(key, field, value, commit) {
        const m = _motion()
        if (!m[key]) return
        m[key][field] = value
        _write(m, commit)
    }
    function _setSwap(field, value, commit) {
        const m = _motion()
        m.swap = m.swap || {}
        m.swap[field] = value
        _write(m, commit)
    }

    // ── Preview ─────────────────────────────────────────────────────────
    Row {
        spacing: Theme.space.sm
        GhostButton {
            text: qsTr("Play entry")
            onClicked: root.workspace.previewMotion(true)
        }
        GhostButton {
            text: qsTr("Play exit")
            onClicked: root.workspace.previewMotion(false)
        }
    }

    component Caption: Text {
        color: Theme.color.textTertiary
        font.family: Theme.font.family
        font.pixelSize: Theme.font.smallSize
    }

    // One phase: entry ("in") or exit ("out").
    component PhaseEditor: Column {
        id: pe
        property var editor
        property string key: "in"
        property string title: ""
        readonly property var phase: pe.editor ? pe.editor._phase(key) : null
        readonly property string type: phase ? (phase.type || "fade") : "none"
        anchors.left: parent ? parent.left : undefined
        anchors.right: parent ? parent.right : undefined
        spacing: 6

        Caption { text: pe.title; topPadding: Theme.space.sm }
        Combobox {
            id: typeBox
            anchors.left: parent.left
            anchors.right: parent.right
            searchable: false
            options: pe.editor._labels(pe.editor._typeOptions)
            value: pe.editor._labelOf(pe.editor._typeOptions, pe.type)
            onValueSelected: function(v) { pe.editor._setType(pe.key, pe.editor._valueOf(pe.editor._typeOptions, v)) }
        }
        Combobox {
            id: edgeBox
            visible: pe.type === "slide" || pe.type === "wipe" || pe.type === "grow"
            anchors.left: parent.left
            anchors.right: parent.right
            searchable: false
            options: pe.editor._labels(pe.type === "grow" ? pe.editor._growEdgeOptions : pe.editor._edgeOptions)
            value: pe.editor._labelOf(pe.editor._growEdgeOptions,
                                 (pe.phase && pe.phase.edge) || (pe.type === "slide" ? "bottom" : "left"))
            onValueSelected: function(v) { pe.editor._setField(pe.key, "edge", pe.editor._valueOf(pe.editor._growEdgeOptions, v), true) }
        }
        NumericInput {
            visible: pe.type === "slide"
            anchors.left: parent.left
            anchors.right: parent.right
            workspace: pe.editor.workspace
            label: qsTr("Distance"); suffix: "px"
            min: 0; max: 2000; step: 2
            value: (pe.phase && pe.phase.distance !== undefined) ? pe.phase.distance : (pe.key === "in" ? 28 : 16)
            onLive:   function(v) { pe.editor._setField(pe.key, "distance", Math.round(v), false) }
            onCommit: function(v) { pe.editor._setField(pe.key, "distance", Math.round(v), true) }
        }
        Row {
            visible: pe.type !== "none"
            spacing: 8
            NumericInput {
                width: (pe.width - 8) / 2
                workspace: pe.editor.workspace
                label: qsTr("Time"); suffix: "ms"
                min: 0; max: 5000; step: 20
                value: (pe.phase && pe.phase.duration !== undefined) ? pe.phase.duration : (pe.key === "in" ? 500 : 320)
                onLive:   function(v) { pe.editor._setField(pe.key, "duration", Math.round(v), false) }
                onCommit: function(v) { pe.editor._setField(pe.key, "duration", Math.round(v), true) }
            }
            NumericInput {
                width: (pe.width - 8) / 2
                workspace: pe.editor.workspace
                label: qsTr("Delay"); suffix: "ms"
                min: 0; max: 5000; step: 20
                value: (pe.phase && pe.phase.delay) || 0
                onLive:   function(v) { pe.editor._setField(pe.key, "delay", Math.round(v), false) }
                onCommit: function(v) { pe.editor._setField(pe.key, "delay", Math.round(v), true) }
            }
        }
        Combobox {
            id: easingBox
            visible: pe.type !== "none"
            anchors.left: parent.left
            anchors.right: parent.right
            searchable: false
            options: pe.editor._labels(pe.editor._easingOptions)
            value: pe.editor._labelOf(pe.editor._easingOptions,
                                 (pe.phase && pe.phase.easing !== undefined) ? pe.phase.easing
                                                                            : (pe.key === "in" ? "smooth" : "in"))
            onValueSelected: function(v) { pe.editor._setField(pe.key, "easing", pe.editor._valueOf(pe.editor._easingOptions, v), true) }
        }
    }

    // Entry stacks above exit and exit above the swap row, so each block's
    // lists open over the blocks below it. The section is the last one in
    // the panel, so nothing sits below the swap row.
    PhaseEditor { editor: root; key: "in";  title: qsTr("Comes in");  z: 2 }
    PhaseEditor { editor: root; key: "out"; title: qsTr("Goes out");  z: 1 }

    // Text only: a new verse or lyric on a design that stays up fades the
    // old text out and the new text in. Only on a design with motion.
    Column {
        visible: root._isText
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 6
        Caption { text: qsTr("New verse or lyric"); topPadding: Theme.space.sm }
        Row {
            spacing: 8
            NumericInput {
                width: (root.width - 8) / 2
                workspace: root.workspace
                label: qsTr("Out"); suffix: "ms"
                min: 0; max: 2000; step: 20
                value: { const s = root._motion().swap; return (s && s.out !== undefined) ? s.out : 160 }
                onLive:   function(v) { root._setSwap("out", Math.round(v), false) }
                onCommit: function(v) { root._setSwap("out", Math.round(v), true) }
            }
            NumericInput {
                width: (root.width - 8) / 2
                workspace: root.workspace
                label: qsTr("In"); suffix: "ms"
                min: 0; max: 2000; step: 20
                value: { const s = root._motion().swap; return (s && s.in !== undefined) ? s.in : 260 }
                onLive:   function(v) { root._setSwap("in", Math.round(v), false) }
                onCommit: function(v) { root._setSwap("in", Math.round(v), true) }
            }
        }
    }
}
