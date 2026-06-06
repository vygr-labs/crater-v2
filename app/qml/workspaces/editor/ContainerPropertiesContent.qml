import QtQuick
import Crater

// Container-specific properties: background fill, media (with picker popover
// and per-media opacity), and corner radius.
//
// Design notes:
//   • Media-opacity lives in the Media section (not Background) because it
//     only affects the media layer rendered by MediaBackgroundLoader. Putting
//     it under "Fill" was confusing — operators dragged it expecting the
//     solid color to fade and saw nothing happen on a media-less container.
//   • Corner radius is a single uniform value. NodeRenderer averages the four
//     stored fields anyway (Qt 6 Rectangle only supports a uniform radius), so
//     exposing four inputs that all collapse to their average lied about the
//     output. We still write to all four schema fields — keeps the door open
//     for a future per-corner painter without a token migration.
Column {
    id: root
    property var workspace
    property var node

    spacing: 4

    function _setStyle(f, v) { workspace.workingTheme.setNodeStyle(node.id, f, v); workspace.saveToHistory() }
    function _setData (f, v) { workspace.workingTheme.setNodeData (node.id, f, v); workspace.saveToHistory() }

    // Live / commit pair — see TextPropertiesContent for rationale.
    // Discrete inputs (ColorSwatchInput Fill, media picker) keep
    // _setStyle/_setData; only continuous numeric/slider edits go through
    // the live/commit split.
    function _liveStyle  (f, v) { workspace.workingTheme.setNodeStyle(node.id, f, v) }
    function _commitStyle(f, v) { workspace.saveToHistory() }
    function _liveData   (f, v) { workspace.workingTheme.setNodeData (node.id, f, v) }
    function _commitData (f, v) { workspace.saveToHistory() }

    // Resolve the current media so visibility / preview bindings can read off
    // a single source. `_media` is null when no media is picked OR when the
    // referenced id was removed from the library; both cases collapse the
    // media-only inputs to keep the panel quiet.
    readonly property var _media: (node && node.data && node.data.mediaId)
        ? MediaService.byId(node.data.mediaId) : null

    // ── Gradient fill helpers ──────────────────────────────────────────
    // The gradient lives as a nested map at data.fill.gradient. setNodeData
    // only writes whole top-level data fields, so every edit reads the current
    // gradient, patches one key, and writes the entire `fill` object back.
    // _gradient() always returns a fully-defaulted spec so partial / legacy
    // data still edits cleanly.
    readonly property bool _isGradient:
        !!(node && node.data && node.data.fill && node.data.fill.type === "gradient")
    readonly property string _gradStyle: {
        const g = node && node.data && node.data.fill && node.data.fill.gradient
        return (g && g.style) || "mesh"
    }
    // Only conic and mesh use the time clock — linear / radial are static
    // clamped ramps — so the Animate / Speed controls surface for those two.
    readonly property bool _animatable: _gradStyle === "conic" || _gradStyle === "mesh"
    // The color-stop Repeater is modelled on the stop COUNT, not the colors
    // array. ColorPicker commits live on every drag tick, so keying the model
    // on the colors would rebuild the rows mid-drag and destroy the very popover
    // being dragged — the press then falls through to the canvas behind. Keying
    // on count means only add / remove rebuilds; each row reads its own color by
    // index (a binding on `node`), updating in place without a rebuild. This
    // also makes angle / speed drags (which never change the count) free.
    readonly property int _stopCount: {
        const g = node && node.data && node.data.fill && node.data.fill.gradient
        return (g && g.colors && g.colors.length >= 2) ? g.colors.length : 3
    }
    function _stopColorAt(i) {
        const g = node && node.data && node.data.fill && node.data.fill.gradient
        return (g && g.colors && g.colors[i] !== undefined) ? g.colors[i] : "#ffffff"
    }

    function _gradient() {
        const g = node && node.data && node.data.fill && node.data.fill.gradient
        return {
            style:   (g && g.style) || "mesh",
            colors:  (g && g.colors && g.colors.length >= 2)
                         ? g.colors.slice() : ["#1e3a8a", "#7c3aed", "#db2777"],
            angle:   (g && g.angle) || 0,
            speed:   (g && g.speed   !== undefined) ? g.speed   : 1.0,
            animate: (g && g.animate !== undefined) ? g.animate : true
        }
    }
    // commit=true snapshots one undo step; live edits (angle / speed drag) pass
    // false and let the input's onCommit call saveToHistory once at release.
    function _writeGradient(g, commit) {
        workspace.workingTheme.setNodeData(node.id, "fill",
            { type: "gradient", gradient: g })
        if (commit) workspace.saveToHistory()
    }


    // ── Group / card helpers ───────────────────────────────────────────
    // A container becomes a card (data.group): it stacks its member nodes, hugs
    // the total, and bottom-anchors. The recommended layout mechanic — the card
    // owns positioning, so alignment is exact. Supersedes the hug controls.
    readonly property bool _isCard: !!(node && node.data && node.data.group)
    readonly property var _members: {
        const g = node && node.data && node.data.group
        return (g && g.members) ? g.members : []
    }
    function _group() {
        const g = node && node.data && node.data.group
        return {
            members:   (g && g.members) ? g.members.slice() : [],
            gap:       (g && g.gap       !== undefined) ? g.gap       : 1.5,
            padTop:    (g && g.padTop    !== undefined) ? g.padTop    : 4,
            padBottom: (g && g.padBottom !== undefined) ? g.padBottom : 4,
            padX:      (g && g.padX      !== undefined) ? g.padX      : 8,
            anchor:    (g && g.anchor) || "bottom"
        }
    }
    function _writeGroup(grp, commit) {
        workspace.workingTheme.setNodeData(node.id, "group", grp)
        if (commit) workspace.saveToHistory()
    }
    function _setCard(on) {
        if (on) {
            // Group supersedes the single-node hug; clear it to avoid conflict.
            workspace.workingTheme.setNodeData(node.id, "autoHeight", null)
            _writeGroup(_group(), true)
        } else {
            workspace.workingTheme.setNodeData(node.id, "group", null)
            workspace.saveToHistory()
        }
    }
    function _addMember(id) {
        const grp = _group()
        if (id && grp.members.indexOf(id) < 0) { grp.members.push(id); _writeGroup(grp, true) }
    }
    function _removeMember(i) {
        const grp = _group()
        if (i >= 0 && i < grp.members.length) { grp.members.splice(i, 1); _writeGroup(grp, true) }
    }
    function _moveMember(i, delta) {
        const grp = _group(); const j = i + delta
        if (j < 0 || j >= grp.members.length) return
        const t = grp.members[i]; grp.members[i] = grp.members[j]; grp.members[j] = t
        _writeGroup(grp, true)
    }
    // Nodes not yet members (and not self), for the "Add member" picker.
    readonly property var _nonMemberOptions: {
        const nodes = (workspace && workspace.workingTheme && workspace.workingTheme.nodes) || []
        const mem = _members
        const out = []
        for (let i = 0; i < nodes.length; i++) {
            const n = nodes[i]
            if (!n || n.id === node.id) continue
            if (mem.indexOf(n.id) >= 0) continue
            out.push({ label: n.id, value: n.id })
        }
        return out
    }

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

            // Fill type — Solid uses the color picker; Gradient swaps in the
            // animated GradientFill and reveals its controls below. The first
            // switch to Gradient seeds a default mesh; switching back to Solid
            // keeps the gradient spec so re-selecting restores it.
            SegmentedControl {
                anchors.left: parent.left
                anchors.right: parent.right
                height: 28
                options: [
                    { value: "solid",    label: qsTr("Solid")    },
                    { value: "gradient", label: qsTr("Gradient") }
                ]
                current: root._isGradient ? "gradient" : "solid"
                onChanged: function(v) {
                    const fill = (node.data && node.data.fill) || ({})
                    if (v === "gradient") {
                        root._setData("fill", {
                            type: "gradient",
                            gradient: fill.gradient || {
                                style: "mesh",
                                colors: ["#1e3a8a", "#7c3aed", "#db2777"],
                                angle: 0, speed: 1.0, animate: true
                            }
                        })
                    } else {
                        root._setData("fill", { type: "solid", gradient: fill.gradient || null })
                    }
                }
            }

            // ── Solid fill ────────────────────────────────────────────
            ColorSwatchInput {
                anchors.left: parent.left
                anchors.right: parent.right
                height: 32
                visible: !root._isGradient
                label: qsTr("Fill")
                value: (node && node.style && node.style.backgroundColor) || "#000000"
                // Live during the drag, one undo step on close (see the
                // live/commit split — the color picker is a drag input).
                onColorPicked: function(c) { root._liveStyle("backgroundColor", c) }
                onCommitted:   function(c) { workspace.saveToHistory() }
            }

            // ── Gradient fill ─────────────────────────────────────────
            Column {
                anchors.left: parent.left
                anchors.right: parent.right
                visible: root._isGradient
                spacing: 6

                // Style — mesh is the flowing "aurora" blend; the others are
                // classic directional ramps.
                SegmentedControl {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: 28
                    options: [
                        { value: "linear", label: qsTr("Linear") },
                        { value: "radial", label: qsTr("Radial") },
                        { value: "conic",  label: qsTr("Conic")  },
                        { value: "mesh",   label: qsTr("Mesh")   }
                    ]
                    current: root._gradStyle
                    onChanged: function(v) {
                        const g = root._gradient(); g.style = v; root._writeGradient(g, true)
                    }
                }

                // Color stops — 2..6. Each row is a swatch + remove; the Add
                // button hides once six stops exist.
                Column {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    spacing: 6

                    Repeater {
                        model: root._stopCount
                        delegate: Row {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            spacing: 6
                            ColorSwatchInput {
                                width: parent.width - 34
                                height: 32
                                label: qsTr("Stop %1").arg(index + 1)
                                value: root._stopColorAt(index)
                                // Live during the drag (commit=false → no
                                // history); one undo step on close.
                                onColorPicked: function(c) {
                                    const g = root._gradient(); g.colors[index] = c
                                    root._writeGradient(g, false)
                                }
                                onCommitted: function(c) { workspace.saveToHistory() }
                            }
                            IconButton {
                                anchors.verticalCenter: parent.verticalCenter
                                iconName: "trash"
                                iconSize: Theme.icon.sm
                                enabled: root._stopCount > 2
                                opacity: enabled ? 1 : 0.35
                                onClicked: {
                                    const g = root._gradient()
                                    if (g.colors.length > 2) {
                                        g.colors.splice(index, 1)
                                        root._writeGradient(g, true)
                                    }
                                }
                            }
                        }
                    }

                    GhostButton {
                        visible: root._stopCount < 6
                        text: qsTr("Add color")
                        iconName: "plus"
                        onClicked: {
                            const g = root._gradient()
                            if (g.colors.length < 6) {
                                g.colors.push("#ffffff")
                                root._writeGradient(g, true)
                            }
                        }
                    }
                }

                // Angle — only linear / conic have a direction; radial and mesh
                // ignore it, so it's hidden for those.
                NumericInput {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    visible: root._gradStyle === "linear" || root._gradStyle === "conic"
                    workspace: root.workspace
                    label: qsTr("Angle"); suffix: "°"
                    min: 0; max: 360; step: 1
                    value: {
                        const g = node && node.data && node.data.fill && node.data.fill.gradient
                        return (g && g.angle) || 0
                    }
                    onLive:   function(v) { const g = root._gradient(); g.angle = Math.round(v); root._writeGradient(g, false) }
                    onCommit: function(v) { workspace.saveToHistory() }
                }

                // Animate toggle — mirrors the editor's other checkbox rows
                // (Auto-fit / Drop shadow). Speed dims out when animation is off.
                Item {
                    id: animateRow
                    anchors.left: parent.left
                    width: 120
                    height: 32
                    visible: root._animatable
                    readonly property bool _on: {
                        const g = node && node.data && node.data.fill && node.data.fill.gradient
                        return !g || g.animate !== false
                    }
                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 8
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 18; height: 18; radius: 0
                            color: animateRow._on ? Theme.color.brand : Theme.color.canvas
                            border.color: animateRow._on ? Theme.color.brand : Theme.color.borderStrong
                            border.width: 1
                            AppIcon {
                                anchors.centerIn: parent
                                visible: animateRow._on
                                name: "check"; size: Theme.icon.sm
                                color: Theme.color.brandInk
                            }
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: qsTr("Animate")
                            color: Theme.color.textSecondary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.bodySize
                            font.weight: Theme.font.weightMedium
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            const g = root._gradient()
                            g.animate = !(g.animate !== false)
                            root._writeGradient(g, true)
                        }
                    }
                }

                SimpleSlider {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    visible: root._animatable && animateRow._on
                    label: qsTr("Speed")
                    value: {
                        const g = node && node.data && node.data.fill && node.data.fill.gradient
                        return (g && g.speed !== undefined) ? g.speed : 1.0
                    }
                    min: 0.1; max: 3.0; step: 0.1
                    onLive:   function(v) { const g = root._gradient(); g.speed = v; root._writeGradient(g, false) }
                    onCommit: function(v) { workspace.saveToHistory() }
                }
            }
        }
    }

    // ── Card / Group ───────────────────────────────────────────────────
    // Makes this container a card: it stacks its member nodes, hugs the total,
    // and bottom-anchors to its box bottom (the recommended lower-third
    // mechanic). Members keep auto-fit; the card owns their position. Applies
    // on the projection output; the editor canvas shows the configured box.
    AccordionSection {
        id: cardSection
        anchors.left: parent.left
        anchors.right: parent.right
        title: qsTr("Card / Group")
        z: addMemberCombo._open ? 100 : 0
        Column {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: Theme.space.md
            anchors.topMargin: Theme.space.sm
            spacing: 6

            // Toggle — make this container a card.
            Item {
                id: cardRow
                anchors.left: parent.left
                width: 200
                height: 32
                Row {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 8
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 18; height: 18; radius: 0
                        color: root._isCard ? Theme.color.brand : Theme.color.canvas
                        border.color: root._isCard ? Theme.color.brand : Theme.color.borderStrong
                        border.width: 1
                        AppIcon {
                            anchors.centerIn: parent
                            visible: root._isCard
                            name: "check"; size: Theme.icon.sm
                            color: Theme.color.brandInk
                        }
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Card (stack & hug members)")
                        color: Theme.color.textSecondary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.bodySize
                        font.weight: Theme.font.weightMedium
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root._setCard(!root._isCard)
                }
            }

            // Card configuration.
            Column {
                visible: root._isCard
                anchors.left: parent.left
                anchors.right: parent.right
                spacing: 6

                Text {
                    text: qsTr("Members (top → bottom)")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                }

                // Ordered member list: each row reorders / removes itself.
                Repeater {
                    model: root._members
                    delegate: Row {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        spacing: 4
                        Rectangle {
                            width: parent.width - 84
                            height: 28
                            radius: 0
                            color: Theme.color.canvas
                            border.color: Theme.color.borderStrong
                            border.width: 1
                            Text {
                                anchors.fill: parent
                                anchors.leftMargin: 8
                                verticalAlignment: Text.AlignVCenter
                                text: modelData
                                color: Theme.color.textPrimary
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.bodySize
                                elide: Text.ElideRight
                            }
                        }
                        IconButton {
                            anchors.verticalCenter: parent.verticalCenter
                            iconName: "chevron-up"; iconSize: Theme.icon.sm
                            enabled: index > 0
                            opacity: enabled ? 1 : 0.35
                            onClicked: root._moveMember(index, -1)
                        }
                        IconButton {
                            anchors.verticalCenter: parent.verticalCenter
                            iconName: "chevron-down"; iconSize: Theme.icon.sm
                            enabled: index < root._members.length - 1
                            opacity: enabled ? 1 : 0.35
                            onClicked: root._moveMember(index, 1)
                        }
                        IconButton {
                            anchors.verticalCenter: parent.verticalCenter
                            iconName: "trash"; iconSize: Theme.icon.sm
                            onClicked: root._removeMember(index)
                        }
                    }
                }

                // Add member — a pure action picker (always shows placeholder).
                Combobox {
                    id: addMemberCombo
                    anchors.left: parent.left
                    anchors.right: parent.right
                    visible: root._nonMemberOptions.length > 0
                    searchable: false
                    placeholder: qsTr("Add member…")
                    value: ""
                    options: root._nonMemberOptions
                    onValueSelected: function(v) { root._addMember(v) }
                }

                // Gap + side padding.
                Row {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    spacing: 6
                    NumericInput {
                        width: (parent.width - 6) / 2
                        workspace: root.workspace
                        label: qsTr("Gap"); suffix: "%"
                        min: 0; max: 30; step: 0.5
                        value: root._group().gap
                        onLive:   function(v) { const g = root._group(); g.gap = Math.round(v * 10) / 10; root._writeGroup(g, false) }
                        onCommit: function(v) { workspace.saveToHistory() }
                    }
                    NumericInput {
                        width: (parent.width - 6) / 2
                        workspace: root.workspace
                        label: qsTr("Pad X"); suffix: "%"
                        min: 0; max: 40; step: 0.5
                        value: root._group().padX
                        onLive:   function(v) { const g = root._group(); g.padX = Math.round(v * 10) / 10; root._writeGroup(g, false) }
                        onCommit: function(v) { workspace.saveToHistory() }
                    }
                }
                // Top + bottom padding.
                Row {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    spacing: 6
                    NumericInput {
                        width: (parent.width - 6) / 2
                        workspace: root.workspace
                        label: qsTr("Pad top"); suffix: "%"
                        min: 0; max: 40; step: 0.5
                        value: root._group().padTop
                        onLive:   function(v) { const g = root._group(); g.padTop = Math.round(v * 10) / 10; root._writeGroup(g, false) }
                        onCommit: function(v) { workspace.saveToHistory() }
                    }
                    NumericInput {
                        width: (parent.width - 6) / 2
                        workspace: root.workspace
                        label: qsTr("Pad bot"); suffix: "%"
                        min: 0; max: 40; step: 0.5
                        value: root._group().padBottom
                        onLive:   function(v) { const g = root._group(); g.padBottom = Math.round(v * 10) / 10; root._writeGroup(g, false) }
                        onCommit: function(v) { workspace.saveToHistory() }
                    }
                }
            }
        }
    }

    // ── Media ─────────────────────────────────────────────────────────
    AccordionSection {
        id: mediaSection
        anchors.left: parent.left
        anchors.right: parent.right
        title: qsTr("Media")
        // Lift this section above subsequent siblings while the picker is
        // open — same trick the Typography accordion uses around its font
        // combobox so the popover's chrome paints above sections declared
        // after it. The popover already reparents to the window root for
        // truly-out-of-bounds clipping, but z lift keeps the picker's anchor
        // rectangle's hover/click handling on top of any overlap.
        z: mediaPicker.visible ? 100 : 0
        Column {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: Theme.space.md
            anchors.topMargin: Theme.space.sm
            spacing: 6

            Rectangle {
                id: mediaSlot
                anchors.left: parent.left
                anchors.right: parent.right
                height: 48
                radius: 0
                color: Theme.color.canvas
                border.color: slotMa.containsMouse ? Theme.color.brand : Theme.color.borderStrong
                border.width: 1

                Row {
                    anchors.fill: parent
                    anchors.margins: 6
                    spacing: 8

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 36; height: 36; radius: 0
                        color: Theme.color.elevated
                        Image {
                            visible: root._media && root._media.type === "image"
                            anchors.fill: parent
                            anchors.margins: 1
                            asynchronous: true
                            cache: true
                            source: root._media ? "file:///" + root._media.path : ""
                            fillMode: Image.PreserveAspectCrop
                        }
                        AppIcon {
                            visible: !root._media || root._media.type !== "image"
                            anchors.centerIn: parent
                            name: root._media ? "film" : "image"
                            color: Theme.color.textTertiary
                            size: Theme.icon.md
                        }
                    }

                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2
                        Text {
                            text: root._media ? root._media.title : qsTr("No media")
                            color: root._media ? Theme.color.textPrimary : Theme.color.textTertiary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.smallSize
                            font.italic: !root._media
                            elide: Text.ElideRight
                            width: mediaSlot.width - 64
                        }
                        Text {
                            visible: !!root._media
                            text: root._media && root._media.type === "video" ? qsTr("Video") : qsTr("Image")
                            color: Theme.color.textTertiary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.microSize
                        }
                    }
                }

                AppIcon {
                    anchors.right: parent.right
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    name: "chevron-down"
                    size: Theme.icon.sm
                    color: Theme.color.textTertiary
                }

                MouseArea {
                    id: slotMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: mediaPicker.openAt(mediaSlot)
                }
            }

            // Per-media opacity. Only meaningful when there's media to fade;
            // hidden otherwise so the panel doesn't suggest a slider that
            // visibly does nothing.
            SimpleSlider {
                anchors.left: parent.left
                anchors.right: parent.right
                visible: !!root._media
                label: qsTr("Opacity")
                value: (node && node.data && node.data.bgOpacity !== undefined)
                    ? node.data.bgOpacity : 1.0
                min: 0; max: 1; step: 0.05
                onLive:   function(v) { root._liveData("bgOpacity", v) }
                onCommit: function(v) { root._commitData("bgOpacity", v) }
            }
        }
    }

    // ── Corner radius ─────────────────────────────────────────────────
    // Single uniform value — sets all four corner fields to the same number.
    // Read value = average of the four fields (handles legacy asymmetric
    // tokens by surfacing what NodeRenderer would actually paint).
    AccordionSection {
        anchors.left: parent.left
        anchors.right: parent.right
        title: qsTr("Corner Radius")
        Column {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: Theme.space.md
            anchors.topMargin: Theme.space.sm
            spacing: 6

            NumericInput {
                anchors.left: parent.left
                anchors.right: parent.right
                workspace: root.workspace
                label: qsTr("Radius"); suffix: "px"; min: 0; max: 200; step: 1
                // Average of the four corner fields — handles legacy themes
                // that stored asymmetric corners by surfacing what
                // NodeRenderer would actually paint (Qt 6 Rectangle has a
                // uniform radius).
                value: {
                    if (!node || !node.style) return 0
                    const s = node.style
                    return ((s.borderTopLeftRadius     || 0)
                          + (s.borderTopRightRadius    || 0)
                          + (s.borderBottomLeftRadius  || 0)
                          + (s.borderBottomRightRadius || 0)) / 4
                }
                // Live writes all four corner fields per keystroke — no
                // history snapshots; the canvas re-renders via the same
                // nodeStyleChanged signal every other edit uses. Commit
                // takes one snapshot at the end of the editing session,
                // so an undo step rolls back the whole radius change as
                // a single unit instead of per-corner per-keystroke.
                onLive: function(v) {
                    const r = Math.round(v)
                    const wt = workspace.workingTheme
                    wt.setNodeStyle(node.id, "borderTopLeftRadius",     r)
                    wt.setNodeStyle(node.id, "borderTopRightRadius",    r)
                    wt.setNodeStyle(node.id, "borderBottomLeftRadius",  r)
                    wt.setNodeStyle(node.id, "borderBottomRightRadius", r)
                }
                onCommit: function(v) {
                    workspace.saveToHistory()
                }
            }
        }
    }

    // Floating picker — reparents to the window root on openAt() so the
    // list isn't clipped by the properties panel's Flickable or by the
    // section's bounds.
    MediaPickerPopover {
        id: mediaPicker
        targetId: (node && node.data && node.data.mediaId) || 0
        onMediaChosen: function(id) {
            // Store null (not 0) for "no media" so the saved token reads
            // cleanly; NodeRenderer reads mediaId || 0 either way.
            root._setData("mediaId", id === 0 ? null : id)
        }
    }
}
