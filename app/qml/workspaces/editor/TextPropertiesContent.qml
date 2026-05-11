import QtQuick
import Crater

import "./inputs" as Inputs
import "../../components" as Components

// All non-Transform properties for a Text node: color, typography,
// alignment, spacing, content linkage, auto-resize.
Column {
    id: root
    property var workspace
    property var node                // selected text node

    spacing: 4

    function _setStyle(f, v) { workspace.workingTheme.setNodeStyle(node.id, f, v); workspace.saveToHistory() }
    function _setData (f, v) { workspace.workingTheme.setNodeData (node.id, f, v); workspace.saveToHistory() }

    // ── Color ─────────────────────────────────────────────────────────
    AccordionSection {
        anchors.left: parent.left
        anchors.right: parent.right
        title: qsTr("Color")
        Item {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: Theme.space.md
            anchors.top: parent.top
            anchors.topMargin: Theme.space.sm
            height: 32
            Components.ColorSwatchInput {
                anchors.fill: parent
                label: qsTr("Text")
                value: (node && node.style && node.style.color) || "#ffffff"
                onColorPicked: function(c) { root._setStyle("color", c) }
            }
        }
    }

    // ── Typography ────────────────────────────────────────────────────
    AccordionSection {
        anchors.left: parent.left
        anchors.right: parent.right
        title: qsTr("Typography")
        Column {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.topMargin: Theme.space.sm
            anchors.margins: Theme.space.md
            spacing: 6

            // Font family — combo using cached families
            Item {
                anchors.left: parent.left
                anchors.right: parent.right
                height: 24
                Rectangle {
                    anchors.fill: parent
                    radius: Theme.radius.sm
                    color: Theme.color.canvas
                    border.color: Theme.color.borderStrong
                    border.width: 1
                    Text {
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        anchors.rightMargin: 22
                        verticalAlignment: Text.AlignVCenter
                        text: (node && node.style && node.style.fontFamily) || Theme.font.family
                        color: Theme.color.textPrimary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                        elide: Text.ElideRight
                    }
                    AppIcon {
                        anchors.right: parent.right
                        anchors.rightMargin: 6
                        anchors.verticalCenter: parent.verticalCenter
                        name: "chevron-down"
                        size: 12
                        color: Theme.color.textTertiary
                    }
                }
                // Click to cycle through 4 common families. Defers a true
                // dropdown (with Qt.fontFamilies()) to a follow-up so this
                // ships without a font enumeration cost on first paint.
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        const fams = ["Segoe UI Variable Display", "Funnel Sans", "Inter", "Georgia"]
                        const cur  = (root.node && root.node.style && root.node.style.fontFamily) || fams[0]
                        const idx  = fams.indexOf(cur)
                        const next = fams[(idx + 1) % fams.length]
                        root._setStyle("fontFamily", next)
                    }
                }
            }

            Row {
                anchors.left: parent.left
                anchors.right: parent.right
                spacing: 6
                Inputs.NumericInput {
                    width: (parent.width - 6) / 2
                    workspace: root.workspace
                    label: qsTr("Size"); suffix: "px"
                    min: 8; max: 400; step: 1
                    value: (node && node.style && node.style.fontPixelSize) || 48
                    onCommit: function(v) { root._setStyle("fontPixelSize", Math.round(v)) }
                }
                Inputs.NumericInput {
                    width: (parent.width - 6) / 2
                    workspace: root.workspace
                    label: qsTr("Weight"); step: 100
                    min: 100; max: 900
                    value: (node && node.style && node.style.fontWeight) || 500
                    onCommit: function(v) { root._setStyle("fontWeight", Math.round(v / 100) * 100) }
                }
            }

            Inputs.SimpleSlider {
                anchors.left: parent.left
                anchors.right: parent.right
                label: qsTr("Line")
                value: (node && node.style && node.style.lineHeightMultiplier) || 1.25
                min: 0.5; max: 3.0; step: 0.05
                onCommit: function(v) { root._setStyle("lineHeightMultiplier", v) }
            }
            Inputs.SimpleSlider {
                anchors.left: parent.left
                anchors.right: parent.right
                label: qsTr("Letter")
                value: (node && node.style && node.style.letterSpacing) || 0
                min: -2; max: 10; step: 0.1
                onCommit: function(v) { root._setStyle("letterSpacing", v) }
            }
        }
    }

    // ── Alignment ─────────────────────────────────────────────────────
    AccordionSection {
        anchors.left: parent.left
        anchors.right: parent.right
        title: qsTr("Alignment")
        Column {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: Theme.space.md
            anchors.topMargin: Theme.space.sm
            spacing: 6

            Inputs.SegmentedControl {
                anchors.left: parent.left
                anchors.right: parent.right
                height: 28
                options: [
                    { value: "left",   iconName: "align-left"   },
                    { value: "center", iconName: "align-center" },
                    { value: "right",  iconName: "align-right"  }
                ]
                current: (node && node.style && node.style.textAlign) || "center"
                onChanged: function(v) { root._setStyle("textAlign", v) }
            }
            Inputs.SegmentedControl {
                anchors.left: parent.left
                anchors.right: parent.right
                height: 28
                options: [
                    { value: "start",  iconName: "align-start-horizontal"   },
                    { value: "center", iconName: "align-center-horizontal"  },
                    { value: "end",    iconName: "align-end-horizontal"     }
                ]
                current: (node && node.style && node.style.verticalAlign) || "center"
                onChanged: function(v) { root._setStyle("verticalAlign", v) }
            }
            Inputs.SegmentedControl {
                anchors.left: parent.left
                anchors.right: parent.right
                height: 28
                options: [
                    { value: "none",       label: "Aa" },
                    { value: "uppercase",  label: "AA" },
                    { value: "lowercase",  label: "aa" },
                    { value: "capitalize", label: "Aa" }
                ]
                current: (node && node.style && node.style.textTransform) || "none"
                onChanged: function(v) { root._setStyle("textTransform", v) }
            }
        }
    }

    // ── Content ───────────────────────────────────────────────────────
    AccordionSection {
        anchors.left: parent.left
        anchors.right: parent.right
        title: qsTr("Content")
        Column {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: Theme.space.md
            anchors.topMargin: Theme.space.sm
            spacing: 6

            Inputs.SegmentedControl {
                anchors.left: parent.left
                anchors.right: parent.right
                height: 28
                options: [
                    { value: "scriptureRef",  label: qsTr("Ref")    },
                    { value: "scriptureText", label: qsTr("Verse")  },
                    { value: "lyric",         label: qsTr("Lyric")  },
                    { value: "custom",        label: qsTr("Custom") }
                ]
                current: (node && node.data && node.data.linkage) || "custom"
                onChanged: function(v) { root._setData("linkage", v) }
            }

            // Custom text editor (only when linkage === "custom")
            Rectangle {
                visible: node && node.data && node.data.linkage === "custom"
                anchors.left: parent.left
                anchors.right: parent.right
                height: 80
                radius: Theme.radius.sm
                color: Theme.color.canvas
                border.color: txtArea.activeFocus ? Theme.color.brand : Theme.color.borderStrong
                border.width: 1
                TextEdit {
                    id: txtArea
                    anchors.fill: parent
                    anchors.margins: 6
                    color: Theme.color.textPrimary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                    selectByMouse: true
                    wrapMode: TextEdit.Wrap
                    text: (node && node.data && node.data.text) || ""
                    onTextChanged: if (root.node && text !== (root.node.data && root.node.data.text))
                                       root._setData("text", text)
                    onActiveFocusChanged: root.workspace.inputFocused = activeFocus
                }
            }

            Row {
                anchors.left: parent.left
                anchors.right: parent.right
                spacing: 6
                Rectangle {
                    width: parent.width * 0.4
                    height: 24
                    radius: Theme.radius.sm
                    color: (node && node.data && node.data.autoResize) ? Theme.color.brandSubtle : Theme.color.canvas
                    border.color: Theme.color.borderStrong
                    border.width: 1
                    Row {
                        anchors.centerIn: parent; spacing: 4
                        AppIcon { name: (node && node.data && node.data.autoResize) ? "check" : "x"; size: 10
                            color: Theme.color.textPrimary }
                        Text {
                            text: qsTr("Auto-fit")
                            color: Theme.color.textSecondary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.smallSize
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root._setData("autoResize", !(root.node.data && root.node.data.autoResize))
                    }
                }
                Inputs.NumericInput {
                    width: parent.width * 0.6 - 6
                    workspace: root.workspace
                    label: qsTr("Max"); suffix: "px"
                    enabled: !!(node && node.data && node.data.autoResize)
                    min: 8; max: 400; step: 1
                    value: (node && node.data && node.data.maxFontSize) || 220
                    onCommit: function(v) { root._setData("maxFontSize", Math.round(v)) }
                }
            }
        }
    }
}
