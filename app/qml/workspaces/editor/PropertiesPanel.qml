import QtQuick
import Crater

// Right-hand properties panel — switches its body on the selected node's
// kind. Transform is shared (above the Loader). Bind to a re-fetched local
// `node` so per-field bindings re-evaluate on granular WorkingTheme signals.
Rectangle {
    id: root
    property var workspace
    color: Theme.color.bgSidebar

    Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 1
        color: Theme.color.borderSubtle
    }

    // Local node copy — refreshes on workspace's selectedNodeId change AND
    // on every granular mutation, so all input bindings see fresh values.
    //
    // IMPORTANT: localNode is a *binding*. Never assign to it imperatively
    // from a signal handler (that would clobber the binding and freeze the
    // panel on a stale node). Instead, _refreshTick is read inside the
    // binding expression and bumped from Connections — that re-fires the
    // whole expression without touching localNode itself.
    property int _refreshTick: 0
    readonly property var localNode: {
        _refreshTick   // dependency — force re-eval on mutation signals
        return workspace.selectedNodeId
            ? workspace.workingTheme.node(workspace.selectedNodeId)
            : null
    }

    Connections {
        target: workspace.workingTheme
        function onNodeStyleChanged(id, field) {
            if (id === workspace.selectedNodeId) root._refreshTick++
        }
        function onNodeDataChanged(id, field) {
            if (id === workspace.selectedNodeId) root._refreshTick++
        }
        function onNodesChanged() {
            root._refreshTick++
        }
    }

    Item {
        id: header
        height: 36
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 1
        Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Theme.space.lg
            text: qsTr("PROPERTIES")
            color: Theme.color.textTertiary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.microSize
            font.weight: Theme.font.weightSemiBold
            font.letterSpacing: 1.2
        }
    }

    Flickable {
        anchors.top: header.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 1
        contentWidth: width
        contentHeight: body.implicitHeight + 40
        clip: true
        interactive: true

        Column {
            id: body
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            spacing: 0

            // Empty-state when no selection
            Item {
                anchors.left: parent.left
                anchors.right: parent.right
                height: 120
                visible: !root.localNode
                Column {
                    anchors.centerIn: parent
                    spacing: Theme.space.sm
                    AppIcon { name: "move"; size: 32; color: Theme.color.textTertiary
                        anchors.horizontalCenter: parent.horizontalCenter }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: qsTr("Select a layer to edit")
                        color: Theme.color.textTertiary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                    }
                }
            }

            // Transform (shared)
            AccordionSection {
                anchors.left: parent.left
                anchors.right: parent.right
                visible: !!root.localNode
                title: qsTr("Transform")
                TransformProperties {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    workspace: root.workspace
                    node: root.localNode
                }
            }

            // Kind-specific
            Loader {
                anchors.left: parent.left
                anchors.right: parent.right
                active: !!root.localNode
                sourceComponent: !root.localNode ? null
                    : (root.localNode.kind === "text" ? textComp : containerComp)
            }

            Component {
                id: textComp
                TextPropertiesContent {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    workspace: root.workspace
                    node: root.localNode
                }
            }
            Component {
                id: containerComp
                ContainerPropertiesContent {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    workspace: root.workspace
                    node: root.localNode
                }
            }
        }
    }
}
