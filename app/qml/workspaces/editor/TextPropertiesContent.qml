import QtQuick
import Crater

// All non-Transform properties for a Text node: color, typography,
// alignment, spacing, content linkage, auto-resize.
Column {
    id: root
    property var workspace
    property var node                // selected text node

    spacing: 4

    function _setStyle(f, v) { workspace.workingTheme.setNodeStyle(node.id, f, v); workspace.saveToHistory() }
    function _setData (f, v) { workspace.workingTheme.setNodeData (node.id, f, v); workspace.saveToHistory() }

    // Live / commit pair for continuous inputs (numeric / slider). live
    // writes the canonical model directly (no history snapshot); commit
    // snapshots history once. Discrete inputs (SegmentedControl alignment,
    // checkbox autoResize, Combobox font family, TextEdit custom text)
    // keep using _setStyle / _setData since they're single-shot committed
    // actions, not interim — one click = one undo step.
    function _liveStyle  (f, v) { workspace.workingTheme.setNodeStyle(node.id, f, v) }
    function _commitStyle(f, v) { workspace.saveToHistory() }
    function _liveData   (f, v) { workspace.workingTheme.setNodeData (node.id, f, v) }
    function _commitData (f, v) { workspace.saveToHistory() }

    // System font enumeration cached at first construction. Qt.fontFamilies()
    // is ~50 ms on Windows; binding the Combobox to a fresh call on every
    // open would cost the user a noticeable beat. Read once, reuse forever.
    readonly property var _fontFamilies: Qt.fontFamilies()

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
            ColorSwatchInput {
                anchors.fill: parent
                label: qsTr("Text")
                value: (node && node.style && node.style.color) || "#ffffff"
                onColorPicked: function(c) { root._setStyle("color", c) }
            }
        }
    }

    // ── Typography ────────────────────────────────────────────────────
    AccordionSection {
        id: typographySection
        anchors.left: parent.left
        anchors.right: parent.right
        title: qsTr("Typography")
        // Lift the entire section above subsequent siblings whenever the
        // font combobox is open. QML renders sibling items in declaration
        // order with z as the tiebreaker — without this lift, Alignment /
        // Spacing / Content sections (declared after Typography) would
        // draw on top of the dropdown popover.
        z: fontCombobox._open ? 100 : 0
        Column {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.topMargin: Theme.space.sm
            anchors.margins: Theme.space.md
            spacing: 6

            // Font family — searchable dropdown. Qt.fontFamilies() is
            // cached in a readonly property so the (slow) first call only
            // happens once per editor session, not once per repaint.
            Combobox {
                id: fontCombobox
                anchors.left: parent.left
                anchors.right: parent.right
                placeholder: qsTr("Font family")
                value: (node && node.style && node.style.fontFamily) || Theme.font.family
                options: root._fontFamilies
                onValueSelected: function(v) { root._setStyle("fontFamily", v) }
            }

            Row {
                anchors.left: parent.left
                anchors.right: parent.right
                spacing: 6
                NumericInput {
                    width: (parent.width - 6) / 2
                    workspace: root.workspace
                    label: qsTr("Size"); suffix: "px"
                    min: 8; max: 400; step: 1
                    value: (node && node.style && node.style.fontPixelSize) || 48
                    onLive:   function(v) { root._liveStyle("fontPixelSize", Math.round(v)) }
                    onCommit: function(v) { root._commitStyle("fontPixelSize", Math.round(v)) }
                }
                NumericInput {
                    width: (parent.width - 6) / 2
                    workspace: root.workspace
                    label: qsTr("Weight"); step: 100
                    min: 100; max: 900
                    value: (node && node.style && node.style.fontWeight) || 500
                    onLive:   function(v) { root._liveStyle("fontWeight", Math.round(v / 100) * 100) }
                    onCommit: function(v) { root._commitStyle("fontWeight", Math.round(v / 100) * 100) }
                }
            }

            SimpleSlider {
                anchors.left: parent.left
                anchors.right: parent.right
                label: qsTr("Line")
                value: (node && node.style && node.style.lineHeightMultiplier) || 1.25
                min: 0.5; max: 3.0; step: 0.05
                onLive:   function(v) { root._liveStyle("lineHeightMultiplier", v) }
                onCommit: function(v) { root._commitStyle("lineHeightMultiplier", v) }
            }
            SimpleSlider {
                anchors.left: parent.left
                anchors.right: parent.right
                label: qsTr("Letter")
                value: (node && node.style && node.style.letterSpacing) || 0
                min: -2; max: 10; step: 0.1
                onLive:   function(v) { root._liveStyle("letterSpacing", v) }
                onCommit: function(v) { root._commitStyle("letterSpacing", v) }
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

            SegmentedControl {
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
            SegmentedControl {
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
            // Text-transform row. Each label shows what its transform produces
            // when applied to the pair "Ag" — so "none" stays "Ag", uppercase
            // becomes "AG", lowercase "ag", and capitalize "Tt" (title case).
            // The descender on `g` plus distinct title-case glyphs make every
            // option visually unique at a glance, avoiding the "Aa / Aa"
            // ambiguity between none and capitalize in the previous labeling.
            SegmentedControl {
                anchors.left: parent.left
                anchors.right: parent.right
                height: 28
                options: [
                    { value: "none",       label: "Ag" },
                    { value: "uppercase",  label: "AG" },
                    { value: "lowercase",  label: "ag" },
                    { value: "capitalize", label: "Tt" }
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

            SegmentedControl {
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
                height: 96
                radius: 0
                color: Theme.color.canvas
                border.color: txtArea.activeFocus ? Theme.color.brand : Theme.color.borderStrong
                border.width: 1
                TextEdit {
                    id: txtArea
                    anchors.fill: parent
                    anchors.margins: 8
                    color: Theme.color.textPrimary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize
                    selectByMouse: true
                    wrapMode: TextEdit.Wrap
                    text: (node && node.data && node.data.text) || ""
                    onTextChanged: if (root.node && text !== (root.node.data && root.node.data.text))
                                       root._setData("text", text)
                    onActiveFocusChanged: root.workspace.inputFocused = activeFocus
                }
            }

            // Auto-fit + Max-size row. The checkbox-style affordance is far
            // clearer than the previous "× / check" icon-as-toggle, which read
            // as a dismiss button in the OFF state. The Max input dims when
            // auto-fit is off — both visually (opacity) and functionally
            // (enabled = false) — so it's obvious which control governs which.
            Row {
                anchors.left: parent.left
                anchors.right: parent.right
                spacing: 8
                Item {
                    id: autoFitRow
                    width: 108
                    height: 32
                    readonly property bool _on: !!(node && node.data && node.data.autoResize)
                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 8
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 18; height: 18
                            radius: 0
                            color: autoFitRow._on ? Theme.color.brand : Theme.color.canvas
                            border.color: autoFitRow._on ? Theme.color.brand : Theme.color.borderStrong
                            border.width: 1
                            Behavior on color       { ColorAnimation { duration: Theme.motion.instant } }
                            Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }
                            AppIcon {
                                anchors.centerIn: parent
                                visible: autoFitRow._on
                                name: "check"; size: Theme.icon.sm
                                color: Theme.color.brandInk
                            }
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: qsTr("Auto-fit")
                            color: Theme.color.textSecondary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.bodySize
                            font.weight: Theme.font.weightMedium
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root._setData("autoResize",
                            !(root.node.data && root.node.data.autoResize))
                    }
                }
                NumericInput {
                    width: parent.width - 108 - 8
                    workspace: root.workspace
                    label: qsTr("Max"); suffix: "px"
                    enabled: !!(node && node.data && node.data.autoResize)
                    opacity: enabled ? 1 : 0.45
                    min: 8; max: 400; step: 1
                    value: (node && node.data && node.data.maxFontSize) || 220
                    onLive:   function(v) { root._liveData("maxFontSize", Math.round(v)) }
                    onCommit: function(v) { root._commitData("maxFontSize", Math.round(v)) }
                }
            }
        }
    }
}
