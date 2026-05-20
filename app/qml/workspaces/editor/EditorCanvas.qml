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

    // Claim keyboard focus when the editor opens. The theme editor is a
    // full-screen workspace mounted over the (now hidden) operator
    // console — but opening it doesn't move focus, so activeFocusItem
    // stays on whatever console TextInput had focus (a tab search bar,
    // etc.). The workspace derives `inputFocused` from activeFocusItem,
    // so a leftover focused TextInput would gate every editor shortcut
    // (Ctrl+Z/Y, Delete, arrow-nudge) off. Grabbing focus onto this
    // plain Item — not a text widget — makes inputFocused read false so
    // the shortcuts are live from the moment the editor appears.
    // Qt.callLater defers past the construction cascade so the window
    // is fully active when we claim focus.
    Component.onCompleted: Qt.callLater(forceActiveFocus)

    // Checkerboard backdrop indicating "outside the canvas". Painted once
    // per resize into a single scene-graph quad. Two near-blacks so it
    // doesn't compete visually with theme content. Tile size of 16 matches
    // the Photoshop / Figma transparency-grid feel at editor zoom.
    Canvas {
        id: checker
        anchors.fill: parent
        renderStrategy: Canvas.Cooperative
        onPaint: {
            const ctx = getContext("2d")
            const t    = 16
            const cols = Math.ceil(width  / t) + 1
            const rows = Math.ceil(height / t) + 1
            // Base fill — guarantees coverage even if the row loop doesn't
            // overrun the visible area (sub-pixel rounding at high DPI).
            ctx.fillStyle = "#0a0a0a"
            ctx.fillRect(0, 0, width, height)
            ctx.fillStyle = "#141414"
            for (let r = 0; r < rows; ++r) {
                for (let c = 0; c < cols; ++c) {
                    if ((r + c) % 2 === 1)
                        ctx.fillRect(c * t, r * t, t, t)
                }
            }
        }
        onWidthChanged:  requestPaint()
        onHeightChanged: requestPaint()
    }

    Flickable {
        id: flick
        anchors.fill: parent
        // stage.width / stage.height already include the zoom factor (via
        // _scale = _baseScale * zoom). At zoom=1.0 the stage fits inside
        // flick, so we want contentWidth == flick.width — that anchors the
        // stage's center to the viewport's center. Only when zoomed in
        // should contentWidth grow past flick.width to enable scrolling.
        contentWidth:  Math.max(width,  stage.width  + 80)
        contentHeight: Math.max(height, stage.height + 80)
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

            // Click-outside-node to deselect; right-click opens the canvas
            // menu (add new node, frame all, reset zoom).
            RightClickArea {
                anchors.fill: parent
                z: -1
                // Clicking the canvas claims focus back from any text
                // input (name field, numeric input) so editor shortcuts
                // re-enable — MouseAreas don't take focus on their own.
                onLeftClicked:  { workspace.selectedNodeId = ""; root.forceActiveFocus() }
                onRightClicked: { workspace.selectedNodeId = ""; root.forceActiveFocus() }
                menuItems: [
                    { label: qsTr("Add text node"), iconName: "type",
                      action: function() {
                          const id = workspace.workingTheme.addNode("text")
                          if (id) { workspace.selectedNodeId = id; workspace.saveToHistory() }
                      } },
                    { label: qsTr("Add container"), iconName: "square",
                      action: function() {
                          const id = workspace.workingTheme.addNode("container")
                          if (id) { workspace.selectedNodeId = id; workspace.saveToHistory() }
                      } },
                    { separator: true },
                    { label: qsTr("Zoom in"),  iconName: "zoom-in",  kbd: "+",
                      action: function() {
                          workspace.zoom = Math.min(4.0,
                              Math.round((workspace.zoom + 0.1) * 10) / 10)
                      } },
                    { label: qsTr("Zoom out"), iconName: "zoom-out", kbd: "-",
                      action: function() {
                          workspace.zoom = Math.max(0.1,
                              Math.round((workspace.zoom - 0.1) * 10) / 10)
                      } },
                    { label: qsTr("Reset zoom"), iconName: "maximize-2", kbd: "0",
                      action: function() { workspace.zoom = 1.0 } }
                ]
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
