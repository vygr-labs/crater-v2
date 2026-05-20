import QtQuick
import Crater

// Position + size + z-index, shared by Text and Container nodes.
Item {
    id: root
    property var workspace
    property var node               // selected node (QVariantMap)

    implicitHeight: col.implicitHeight + Theme.space.md * 2
    implicitWidth: parent ? parent.width : 320

    // Live: write canonical model directly — no history snapshot. The
    // model's nodeStyleChanged signal drives the canvas update (same path
    // existing edits already use). Commit: snapshot history only — live
    // already wrote the value. Result: per-keystroke canvas updates, one
    // undo step per editing session.
    function _liveStyle  (field, v) { workspace.workingTheme.setNodeStyle(node.id, field, v) }
    function _commitStyle(field, v) { workspace.saveToHistory() }

    Column {
        id: col
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: Theme.space.md
        anchors.top: parent.top
        anchors.topMargin: Theme.space.sm
        spacing: 6

        Row {
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: 6
            // X/Y allow off-canvas positioning (negative + > 100) — matches
            // the canvas drag and arrow-nudge ranges (-200..200). Lets the
            // operator stage off-screen reveals and slide-in transitions.
            NumericInput {
                width: (parent.width - 6) / 2
                workspace: root.workspace
                label: "X"; suffix: "%"
                min: -200; max: 200; step: 0.1
                value: (node && node.style && node.style.x) || 0
                onLive:   function(v) { root._liveStyle("x", v) }
                onCommit: function(v) { root._commitStyle("x", v) }
            }
            NumericInput {
                width: (parent.width - 6) / 2
                workspace: root.workspace
                label: "Y"; suffix: "%"
                min: -200; max: 200; step: 0.1
                value: (node && node.style && node.style.y) || 0
                onLive:   function(v) { root._liveStyle("y", v) }
                onCommit: function(v) { root._commitStyle("y", v) }
            }
        }
        Row {
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: 6
            NumericInput {
                width: (parent.width - 6) / 2
                workspace: root.workspace
                label: "W"; suffix: "%"
                min: 1; max: 100; step: 0.1
                value: (node && node.style && node.style.width) || 0
                onLive:   function(v) { root._liveStyle("width", v) }
                onCommit: function(v) { root._commitStyle("width", v) }
            }
            NumericInput {
                width: (parent.width - 6) / 2
                workspace: root.workspace
                label: "H"; suffix: "%"
                min: 1; max: 100; step: 0.1
                value: (node && node.style && node.style.height) || 0
                onLive:   function(v) { root._liveStyle("height", v) }
                onCommit: function(v) { root._commitStyle("height", v) }
            }
        }
        Row {
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: 6
            NumericInput {
                width: (parent.width - 6) / 2
                workspace: root.workspace
                label: "Z"; step: 1
                value: (node && node.style && node.style.z) || 0
                onLive:   function(v) { root._liveStyle("z", Math.round(v)) }
                onCommit: function(v) { root._commitStyle("z", Math.round(v)) }
            }
            NumericInput {
                width: (parent.width - 6) / 2
                workspace: root.workspace
                label: "Rot"; suffix: "°"
                min: -360; max: 360; step: 1
                value: (node && node.style && node.style.rotation) || 0
                onLive:   function(v) { root._liveStyle("rotation", v) }
                onCommit: function(v) { root._commitStyle("rotation", v) }
            }
        }
        // Skew — paired with Rot conceptually (both warp the node's
        // orientation in space). ±45° is the conventional design-tool
        // range; beyond that text shears so hard the layout becomes
        // unreadable. SkewX tilts vertically (italic effect); SkewY
        // tilts horizontally (card-flip effect). Both pivot from the
        // node's center, matching how Rot pivots.
        Row {
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: 6
            NumericInput {
                width: (parent.width - 6) / 2
                workspace: root.workspace
                label: qsTr("SkX"); suffix: "°"
                min: -45; max: 45; step: 1
                value: (node && node.style && node.style.skewX) || 0
                onLive:   function(v) { root._liveStyle("skewX", v) }
                onCommit: function(v) { root._commitStyle("skewX", v) }
            }
            NumericInput {
                width: (parent.width - 6) / 2
                workspace: root.workspace
                label: qsTr("SkY"); suffix: "°"
                min: -45; max: 45; step: 1
                value: (node && node.style && node.style.skewY) || 0
                onLive:   function(v) { root._liveStyle("skewY", v) }
                onCommit: function(v) { root._commitStyle("skewY", v) }
            }
        }

        SimpleSlider {
            anchors.left: parent.left
            anchors.right: parent.right
            label: qsTr("Opacity")
            value: node && node.style && node.style.opacity !== undefined ? node.style.opacity : 1.0
            min: 0; max: 1; step: 0.01
            onLive:   function(v) { root._liveStyle("opacity", v) }
            onCommit: function(v) { root._commitStyle("opacity", v) }
        }
    }
}
