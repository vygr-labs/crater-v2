import QtQuick
import Crater

// The editing canvas. Letterboxes the theme's canvas inside a Flickable +
// scale transform for zoom, then renders one NodeDelegate per node. Each
// delegate handles its own selection / drag / resize.
//
// Background: a tiled checkerboard so the operator can see container
// transparency, plus a flat rectangle inside the stage so the canvas itself
// has a distinct background from the editor chrome.
Item {
    id: root
    property var workspace

    readonly property var _wt:     workspace.workingTheme
    readonly property var _canvas: _wt.canvas || ({ width: 1920, height: 1080 })
    readonly property var _nodes:  _wt.nodes  || []

    // Checkerboard tile painted via a tiny 16x16 Image. Color tokens match
    // Photoshop / Figma's transparency grid — two near-blacks so it doesn't
    // compete with theme contents.
    Rectangle {
        anchors.fill: parent
        color: "#0a0a0a"
    }
    Repeater {
        // ≈8×4 tile coverage at default zoom; ListModel-less grid that
        // re-tiles on resize. Cheap; the ListView pattern is overkill.
        model: 200
        delegate: Rectangle {
            readonly property int _row: index / 20
            readonly property int _col: index % 20
            x: _col * 32
            y: _row * 32
            width: 32; height: 32
            color: (_row + _col) % 2 === 0 ? "#0a0a0a" : "#141414"
        }
    }

    Flickable {
        id: flick
        anchors.fill: parent
        contentWidth:  Math.max(width,  stage.width  * workspace.zoom + 200)
        contentHeight: Math.max(height, stage.height * workspace.zoom + 200)
        clip: true
        interactive: true

        Item {
            id: stage
            // Letterbox to canvas aspect at 80% of the smaller flick axis at
            // 1.0 zoom; then apply the zoom transform on top.
            readonly property real _baseScale: Math.min(
                (flick.width  - 80) / root._canvas.width,
                (flick.height - 80) / root._canvas.height)
            readonly property real _scale: _baseScale * workspace.zoom

            width:  root._canvas.width  * _scale
            height: root._canvas.height * _scale
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter:   parent.verticalCenter

            // Canvas surface (the theme's own background fill).
            Rectangle {
                anchors.fill: parent
                // First container's bg or black. Subtle but lets the operator
                // see the "frame" of their composition vs the editor chrome.
                color: {
                    for (let i = 0; i < root._nodes.length; ++i) {
                        const n = root._nodes[i]
                        if (n.kind === "container" && n.style && n.style.backgroundColor)
                            return n.style.backgroundColor
                    }
                    return "#000000"
                }
                border.color: Theme.color.borderStrong
                border.width: 1
            }

            // Click-outside-node to deselect.
            MouseArea {
                anchors.fill: parent
                onClicked: workspace.selectedNodeId = ""
                z: -1
            }

            // Nodes — pre-sorted by z so render order matches layer order.
            readonly property var _sortedNodes: {
                const arr = root._nodes.slice()
                arr.sort((a, b) => ((a.style && a.style.z) || 0) - ((b.style && b.style.z) || 0))
                return arr
            }

            Repeater {
                model: stage._sortedNodes
                delegate: NodeDelegate {
                    workspace: root.workspace
                    nodeId: modelData.id
                    stageW: stage.width
                    stageH: stage.height
                }
            }
        }
    }
}
