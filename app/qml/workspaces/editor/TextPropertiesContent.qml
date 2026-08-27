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

    // ── Content linkage ────────────────────────────────────────────────
    // What this text node actually shows at render time. Eight values do
    // not fit the segmented row this used to be: the properties panel is
    // 240 px wide and SegmentedControl divides that evenly with a label that
    // does not elide, so even a sixth option clipped its own text.
    //
    // Slide subtitle and slide right column are the v3 layout slots. Which
    // per-slide fields the slide editor offers is DERIVED by scanning a
    // design for exactly these linkages (crater::tokens::layoutSlots), so
    // setting one here is what makes that field appear on the slide — there
    // is no separate manifest to keep in step.
    //
    // The list is flat rather than scoped to the theme's kind on purpose.
    // Linkage is already cross-kind by design -- scriptureRef resolves to
    // the ITEM TITLE for every kind, which is how several song themes show
    // the song name -- so filtering by kind would hide a working technique
    // and orphan the linkage on any theme already using it.
    readonly property var _linkageOptions: [
        { label: qsTr("Reference / title"), value: "scriptureRef"          },
        { label: qsTr("Verse text"),        value: "scriptureText"         },
        { label: qsTr("Lyric"),             value: "lyric"                 },
        { label: qsTr("Slide title"),       value: "presentationTitle"     },
        { label: qsTr("Slide subtitle"),    value: "presentationSubtitle"  },
        { label: qsTr("Slide body"),        value: "presentationBody"      },
        { label: qsTr("Slide right column"), value: "presentationBodyRight" },
        { label: qsTr("Custom text"),       value: "custom"                }
    ]
    readonly property string _linkageLabel: {
        const cur = (node && node.data && node.data.linkage) || "custom"
        for (let i = 0; i < _linkageOptions.length; i++) {
            if (_linkageOptions[i].value === cur) return _linkageOptions[i].label
        }
        // A linkage this build does not know (theme authored by a newer
        // version) shows its raw key rather than silently reading as
        // "Custom text", which would invite the operator to overwrite it.
        return cur
    }

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

    // ── Auto-layout (stacking) helpers ─────────────────────────────────
    // Text keeps Auto-fit; the CONTAINER does the hugging (see Container
    // properties). Here a text node can stack ABOVE / BELOW another node's
    // content (data.autoPosition) — e.g. the reference riding above the verse.
    // Applies on the live output; the editor canvas shows the configured box.
    readonly property bool _hasPos: !!(node && node.data && node.data.autoPosition)
    readonly property string _posPlace: {
        const p = node && node.data && node.data.autoPosition
        return (p && p.place) || "none"
    }
    function _autoPosition() {
        const p = node && node.data && node.data.autoPosition
        return {
            place:  (p && p.place)  || "above",
            source: (p && p.source) || "",
            gap:    (p && p.gap !== undefined) ? p.gap : 2
        }
    }
    function _writeAutoPosition(p, commit) {
        workspace.workingTheme.setNodeData(node.id, "autoPosition", p)
        if (commit) workspace.saveToHistory()
    }
    function _setPosPlace(place) {
        if (place === "none") {
            workspace.workingTheme.setNodeData(node.id, "autoPosition", null)
            workspace.saveToHistory()
        } else {
            const p = _autoPosition(); p.place = place
            if (!p.source) p.source = _firstOtherNodeId()
            _writeAutoPosition(p, true)
        }
    }
    // Other nodes (any kind) this one can stack against, labelled by id.
    readonly property var _otherNodeOptions: {
        const nodes = (workspace && workspace.workingTheme && workspace.workingTheme.nodes) || []
        const out = []
        for (let i = 0; i < nodes.length; i++) {
            const n = nodes[i]
            if (!n || (node && n.id === node.id)) continue
            out.push({ label: n.id, value: n.id })
        }
        return out
    }
    function _firstOtherNodeId() {
        const o = _otherNodeOptions
        return o.length > 0 ? o[0].value : ""
    }

    // Font picker model — system fonts from Qt.fontFamilies() plus a
    // visual "imported" suffix on any family that came in through
    // FontService (a Crater-imported .ttf/.otf). The Combobox accepts
    // both bare strings and {label, value} objects (see Combobox.qml
    // header comment), so user-imported fonts get the suffixed label
    // while still selecting on the bare family name — the stored
    // tokens.style.fontFamily stays unchanged.
    //
    // Qt.fontFamilies() is ~50 ms on Windows. We rebuild only when
    // FontService.allFonts changes (add / remove); the function reads
    // both inputs, so binding to the property fires on either side's
    // notify signal automatically.
    readonly property var _fontFamilies: {
        const sys = Qt.fontFamilies()
        const userFonts = FontService.allFonts || []
        if (userFonts.length === 0) return sys

        // O(1) membership check. Build a set of family names that came
        // through FontService so the next loop can branch quickly.
        const userSet = {}
        for (let i = 0; i < userFonts.length; ++i) {
            userSet[userFonts[i].family] = true
        }

        const out = []
        for (let i = 0; i < sys.length; ++i) {
            const fam = sys[i]
            if (userSet[fam]) {
                out.push({ label: fam + qsTr(" · imported"), value: fam })
            } else {
                out.push(fam)
            }
        }
        return out
    }

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
                // Live during the drag, one undo step on close.
                onColorPicked: function(c) { root._liveStyle("color", c) }
                onCommitted:   function(c) { workspace.saveToHistory() }
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
                // Render each family in its own typeface so the operator can
                // eyeball fonts inline instead of selecting them one by one.
                previewFontFamily: true
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
                WeightSelect {
                    width: (parent.width - 6) / 2
                    label: qsTr("Weight")
                    value: (node && node.style && node.style.fontWeight) || 500
                    onLive:   function(v) { root._liveStyle("fontWeight", v) }
                    onCommit: function(v) { root._commitStyle("fontWeight", v) }
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

    // ── Shadow ────────────────────────────────────────────────────────
    AccordionSection {
        anchors.left: parent.left
        anchors.right: parent.right
        title: qsTr("Shadow")
        Column {
            id: shadowColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: Theme.space.md
            anchors.topMargin: Theme.space.sm
            spacing: 6

            // `textShadowColor` being a non-empty string is the schema's
            // "shadow on" sentinel — the renderer keys layer.enabled off the
            // same check, so this stays in sync. Toggling off clears the
            // color (X/Y/blur are left in place so re-toggling restores
            // whatever tuning the operator had).
            readonly property bool _on: {
                if (!node || !node.style) return false
                const c = node.style.textShadowColor
                return typeof c === "string" && c.length > 0
            }

            // Toggle row. Mirrors the Auto-fit checkbox styling in the
            // Content section so the editor reads as one component family.
            Item {
                id: shadowToggle
                anchors.left: parent.left
                width: 140
                height: 32
                Row {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 8
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 18; height: 18
                        radius: 0
                        color: shadowColumn._on ? Theme.color.brand : Theme.color.canvas
                        border.color: shadowColumn._on ? Theme.color.brand : Theme.color.borderStrong
                        border.width: 1
                        Behavior on color        { ColorAnimation { duration: Theme.motion.instant } }
                        Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }
                        AppIcon {
                            anchors.centerIn: parent
                            visible: shadowColumn._on
                            name: "check"; size: Theme.icon.sm
                            color: "#ffffff"   // check on the deep-teal box
                        }
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Drop shadow")
                        color: Theme.color.textSecondary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.bodySize
                        font.weight: Theme.font.weightMedium
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    // Toggle on: seed sensible defaults so the shadow reads
                    // as enabled the moment it's switched on, before the
                    // operator touches any input. Default blur of 8 px lands
                    // soft enough to read as a shadow rather than a duplicate
                    // text overlay. Toggle off: clear the color sentinel.
                    onClicked: {
                        if (shadowColumn._on) {
                            root._setStyle("textShadowColor", "")
                        } else {
                            const wt = workspace.workingTheme
                            wt.setNodeStyle(node.id, "textShadowColor", "#000000")
                            if (!(node && node.style && node.style.textShadowBlur))
                                wt.setNodeStyle(node.id, "textShadowBlur", 8)
                            workspace.saveToHistory()
                        }
                    }
                }
            }

            // X / Y offsets, blur, and color — dimmed and disabled when
            // shadow is off so the inputs stay visible (preserving the
            // operator's mental model of what's there to tune) without
            // suggesting they'd do anything in the off state.
            Row {
                anchors.left: parent.left
                anchors.right: parent.right
                spacing: 6
                opacity: shadowColumn._on ? 1 : 0.45
                enabled: shadowColumn._on
                NumericInput {
                    width: (parent.width - 6) / 2
                    workspace: root.workspace
                    label: qsTr("X"); suffix: "px"
                    min: -50; max: 50; step: 1
                    value: (node && node.style && node.style.textShadowOffsetX) || 0
                    onLive:   function(v) { root._liveStyle("textShadowOffsetX", Math.round(v)) }
                    onCommit: function(v) { root._commitStyle("textShadowOffsetX", Math.round(v)) }
                }
                NumericInput {
                    width: (parent.width - 6) / 2
                    workspace: root.workspace
                    label: qsTr("Y"); suffix: "px"
                    min: -50; max: 50; step: 1
                    value: (node && node.style && node.style.textShadowOffsetY) || 0
                    onLive:   function(v) { root._liveStyle("textShadowOffsetY", Math.round(v)) }
                    onCommit: function(v) { root._commitStyle("textShadowOffsetY", Math.round(v)) }
                }
            }

            SimpleSlider {
                anchors.left: parent.left
                anchors.right: parent.right
                label: qsTr("Blur")
                min: 0; max: 50; step: 1
                value: (node && node.style && node.style.textShadowBlur) || 0
                opacity: shadowColumn._on ? 1 : 0.45
                enabled: shadowColumn._on
                onLive:   function(v) { root._liveStyle("textShadowBlur", Math.round(v)) }
                onCommit: function(v) { root._commitStyle("textShadowBlur", Math.round(v)) }
            }

            ColorSwatchInput {
                anchors.left: parent.left
                anchors.right: parent.right
                height: 32
                label: qsTr("Color")
                opacity: shadowColumn._on ? 1 : 0.45
                enabled: shadowColumn._on
                value: (node && node.style && node.style.textShadowColor) || "#000000"
                // Live during the drag, one undo step on close.
                onColorPicked: function(c) { root._liveStyle("textShadowColor", c) }
                onCommitted:   function(c) { workspace.saveToHistory() }
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

            Combobox {
                anchors.left: parent.left
                anchors.right: parent.right
                searchable: false
                options: root._linkageOptions
                value: root._linkageLabel
                onValueSelected: function(v) { root._setData("linkage", v) }
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
                                color: "#ffffff"   // check on the deep-teal box
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

    // ── Auto-layout (stacking) ─────────────────────────────────────────
    // Text keeps Auto-fit; the CONTAINER does the hugging (see Container
    // properties). Here a text node can stack ABOVE / BELOW another node's
    // content — e.g. the reference riding above the verse. Applies on the live
    // output; the editor canvas shows the configured box.
    AccordionSection {
        id: layoutSection
        anchors.left: parent.left
        anchors.right: parent.right
        title: qsTr("Auto-layout")
        // Lift above sections below while the source combobox is open.
        z: posCombobox._open ? 100 : 0
        Column {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: Theme.space.md
            anchors.topMargin: Theme.space.sm
            spacing: 6

            // ── Stacking (above / below another node) ─────────────────
            Text {
                anchors.left: parent.left
                text: qsTr("Position")
                color: Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
            }
            SegmentedControl {
                anchors.left: parent.left
                anchors.right: parent.right
                height: 28
                options: [
                    { value: "none",  label: qsTr("Free")  },
                    { value: "above", label: qsTr("Above") },
                    { value: "below", label: qsTr("Below") }
                ]
                current: root._posPlace
                onChanged: function(v) { root._setPosPlace(v) }
            }

            Column {
                visible: root._hasPos && root._otherNodeOptions.length > 0
                anchors.left: parent.left
                anchors.right: parent.right
                spacing: 6

                Text {
                    text: qsTr("Relative to")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                }
                Combobox {
                    id: posCombobox
                    anchors.left: parent.left
                    anchors.right: parent.right
                    searchable: false
                    placeholder: qsTr("Select a node")
                    options: root._otherNodeOptions
                    value: root._autoPosition().source
                    onValueSelected: function(v) {
                        const p = root._autoPosition(); p.source = v; root._writeAutoPosition(p, true)
                    }
                }
                NumericInput {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    workspace: root.workspace
                    label: qsTr("Gap"); suffix: "%"
                    min: 0; max: 50; step: 0.5
                    value: root._autoPosition().gap
                    onLive:   function(v) { const p = root._autoPosition(); p.gap = Math.round(v * 10) / 10; root._writeAutoPosition(p, false) }
                    onCommit: function(v) { workspace.saveToHistory() }
                }
            }
        }
    }
}
