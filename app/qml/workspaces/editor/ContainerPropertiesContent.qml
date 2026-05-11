import QtQuick
import Crater

// Container-specific properties: background color/opacity, media bg, border radii.
Column {
    id: root
    property var workspace
    property var node

    spacing: 4

    function _setStyle(f, v) { workspace.workingTheme.setNodeStyle(node.id, f, v); workspace.saveToHistory() }
    function _setData (f, v) { workspace.workingTheme.setNodeData (node.id, f, v); workspace.saveToHistory() }

    // ── Background ────────────────────────────────────────────────────
    AccordionSection {
        anchors.left: parent.left
        anchors.right: parent.right
        title: qsTr("Background")
        Column {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: Theme.space.md
            anchors.topMargin: Theme.space.sm
            spacing: 6

            ColorSwatchInput {
                anchors.left: parent.left
                anchors.right: parent.right
                height: 32
                label: qsTr("Fill")
                value: (node && node.style && node.style.backgroundColor) || "#000000"
                onColorPicked: function(c) { root._setStyle("backgroundColor", c) }
            }

            SimpleSlider {
                anchors.left: parent.left
                anchors.right: parent.right
                label: qsTr("Media α")
                value: (node && node.data && node.data.bgOpacity !== undefined) ? node.data.bgOpacity : 1.0
                min: 0; max: 1; step: 0.05
                onCommit: function(v) { root._setData("bgOpacity", v) }
            }
        }
    }

    // ── Media ─────────────────────────────────────────────────────────
    AccordionSection {
        anchors.left: parent.left
        anchors.right: parent.right
        title: qsTr("Media")
        Column {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: Theme.space.md
            anchors.topMargin: Theme.space.sm
            spacing: 6

            readonly property var _media: (node && node.data && node.data.mediaId)
                ? MediaService.byId(node.data.mediaId) : null

            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                height: 40
                radius: Theme.radius.sm
                color: Theme.color.canvas
                border.color: Theme.color.borderStrong
                border.width: 1

                Row {
                    anchors.fill: parent
                    anchors.margins: 6
                    spacing: 6
                    Rectangle {
                        width: 32; height: 32; radius: Theme.radius.sm
                        color: Theme.color.elevated
                        Image {
                            visible: parent.parent.parent.parent._media
                                  && parent.parent.parent.parent._media.type === "image"
                            anchors.fill: parent
                            anchors.margins: 1
                            asynchronous: true
                            source: parent.parent.parent.parent._media
                                ? "file:///" + parent.parent.parent.parent._media.path
                                : ""
                            fillMode: Image.PreserveAspectCrop
                        }
                        AppIcon {
                            visible: !parent.parent.parent.parent._media
                                  || parent.parent.parent.parent._media.type !== "image"
                            anchors.centerIn: parent
                            name: parent.parent.parent.parent._media ? "film" : "image"
                            color: Theme.color.textTertiary
                            size: 14
                        }
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: parent.parent.parent._media
                            ? parent.parent.parent._media.title
                            : qsTr("No media")
                        color: Theme.color.textSecondary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                        elide: Text.ElideRight
                        width: parent.width - 80
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        // Cycle through available media as a v1 stand-in for a
                        // proper picker popover. Pressing repeatedly walks the
                        // library; first press clears (returns to mediaId=0).
                        const all = MediaService.allMedia
                        if (!all || all.length === 0) return
                        const cur = (root.node.data && root.node.data.mediaId) || 0
                        let nextId = 0
                        for (let i = 0; i < all.length; ++i) {
                            if (all[i].id === cur) {
                                nextId = (i + 1 < all.length) ? all[i + 1].id : 0
                                break
                            }
                        }
                        if (cur === 0 && all.length > 0) nextId = all[0].id
                        root._setData("mediaId", nextId === 0 ? null : nextId)
                    }
                }
            }
        }
    }

    // ── Border radius (per-corner) ────────────────────────────────────
    AccordionSection {
        anchors.left: parent.left
        anchors.right: parent.right
        title: qsTr("Border Radius")
        Column {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: Theme.space.md
            anchors.topMargin: Theme.space.sm
            spacing: 6

            Row {
                anchors.left: parent.left
                anchors.right: parent.right
                spacing: 6
                NumericInput {
                    width: (parent.width - 6) / 2
                    workspace: root.workspace
                    label: "TL"; suffix: "px"; min: 0; max: 200; step: 1
                    value: (node && node.style && node.style.borderTopLeftRadius) || 0
                    onCommit: function(v) { root._setStyle("borderTopLeftRadius", Math.round(v)) }
                }
                NumericInput {
                    width: (parent.width - 6) / 2
                    workspace: root.workspace
                    label: "TR"; suffix: "px"; min: 0; max: 200; step: 1
                    value: (node && node.style && node.style.borderTopRightRadius) || 0
                    onCommit: function(v) { root._setStyle("borderTopRightRadius", Math.round(v)) }
                }
            }
            Row {
                anchors.left: parent.left
                anchors.right: parent.right
                spacing: 6
                NumericInput {
                    width: (parent.width - 6) / 2
                    workspace: root.workspace
                    label: "BL"; suffix: "px"; min: 0; max: 200; step: 1
                    value: (node && node.style && node.style.borderBottomLeftRadius) || 0
                    onCommit: function(v) { root._setStyle("borderBottomLeftRadius", Math.round(v)) }
                }
                NumericInput {
                    width: (parent.width - 6) / 2
                    workspace: root.workspace
                    label: "BR"; suffix: "px"; min: 0; max: 200; step: 1
                    value: (node && node.style && node.style.borderBottomRightRadius) || 0
                    onCommit: function(v) { root._setStyle("borderBottomRightRadius", Math.round(v)) }
                }
            }
            Text {
                anchors.left: parent.left
                width: parent.width
                text: qsTr("Note: Qt renders uniform radius (avg of corners) for now.")
                color: Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.microSize
                wrapMode: Text.WordWrap
            }
        }
    }
}
