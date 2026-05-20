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
            NumericInput {
                width: (parent.width - 6) / 2
                workspace: root.workspace
                label: "X"; suffix: "%"
                min: 0; max: 100; step: 0.1
                value: (node && node.style && node.style.x) || 0
                onLive:   function(v) { root._liveStyle("x", v) }
                onCommit: function(v) { root._commitStyle("x", v) }
            }
            NumericInput {
                width: (parent.width - 6) / 2
                workspace: root.workspace
                label: "Y"; suffix: "%"
                min: 0; max: 100; step: 0.1
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
