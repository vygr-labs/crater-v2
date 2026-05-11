import QtQuick
import Crater

import "./inputs" as Inputs

// Position + size + z-index, shared by Text and Container nodes.
Item {
    id: root
    property var workspace
    property var node               // selected node (QVariantMap)

    implicitHeight: col.implicitHeight + Theme.space.md * 2
    implicitWidth: parent ? parent.width : 320

    function _set(field, value) {
        workspace.workingTheme.setNodeStyle(node.id, field, value)
    }
    function _commit() { workspace.saveToHistory() }

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
            Inputs.NumericInput {
                width: (parent.width - 6) / 2
                workspace: root.workspace
                label: "X"; suffix: "%"
                min: 0; max: 100; step: 0.1
                value: (node && node.style && node.style.x) || 0
                onCommit: function(v) { root._set("x", v); root._commit() }
            }
            Inputs.NumericInput {
                width: (parent.width - 6) / 2
                workspace: root.workspace
                label: "Y"; suffix: "%"
                min: 0; max: 100; step: 0.1
                value: (node && node.style && node.style.y) || 0
                onCommit: function(v) { root._set("y", v); root._commit() }
            }
        }
        Row {
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: 6
            Inputs.NumericInput {
                width: (parent.width - 6) / 2
                workspace: root.workspace
                label: "W"; suffix: "%"
                min: 1; max: 100; step: 0.1
                value: (node && node.style && node.style.width) || 0
                onCommit: function(v) { root._set("width", v); root._commit() }
            }
            Inputs.NumericInput {
                width: (parent.width - 6) / 2
                workspace: root.workspace
                label: "H"; suffix: "%"
                min: 1; max: 100; step: 0.1
                value: (node && node.style && node.style.height) || 0
                onCommit: function(v) { root._set("height", v); root._commit() }
            }
        }
        Row {
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: 6
            Inputs.NumericInput {
                width: (parent.width - 6) / 2
                workspace: root.workspace
                label: "Z"; step: 1
                value: (node && node.style && node.style.z) || 0
                onCommit: function(v) { root._set("z", Math.round(v)); root._commit() }
            }
            Inputs.NumericInput {
                width: (parent.width - 6) / 2
                workspace: root.workspace
                label: "Rot"; suffix: "°"
                min: -360; max: 360; step: 1
                value: (node && node.style && node.style.rotation) || 0
                onCommit: function(v) { root._set("rotation", v); root._commit() }
            }
        }
        Inputs.SimpleSlider {
            anchors.left: parent.left
            anchors.right: parent.right
            label: qsTr("Opacity")
            value: node && node.style && node.style.opacity !== undefined ? node.style.opacity : 1.0
            min: 0; max: 1; step: 0.01
            onCommit: function(v) { root._set("opacity", v); root._commit() }
        }
    }
}
