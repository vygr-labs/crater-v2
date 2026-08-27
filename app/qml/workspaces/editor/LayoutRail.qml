import QtQuick
import QtQuick.Controls.Basic
import Crater

// The theme editor's design rail — every layout in the theme being edited,
// as a live thumbnail, with the one on the canvas highlighted.
//
// This is the authoring half of what LayoutStrip does in the slide editor:
// there an operator PICKS a design for a slide, here an author BUILDS the
// set a deck can pick from. Same visual language on purpose — a thumbnail
// row — so "the one with the big centred heading" means the same thing in
// both places.
//
//   LayoutRail { workspace: workspace }
//
// Only mounted for presentation themes. A song or scripture theme has one
// design by definition (a lyric slide is a lyric slide), and nothing in
// those render paths ever names a layout, so extra designs there would be
// unreachable by construction — see ThemeEditorWorkspace.
Rectangle {
    id: root

    property var workspace

    color: Theme.color.bgContent
    implicitHeight: 112

    readonly property var    _wt:      workspace ? workspace.workingTheme : null
    readonly property var    _layouts: _wt ? _wt.layouts : []
    readonly property string _curId:   _wt ? _wt.currentLayoutId : ""

    // ── Thumbnail source ───────────────────────────────────────────────
    // The thumbnails render the WORKING tokens, not the saved theme, so an
    // unsaved edit shows up in the rail. Snapshotting on every signal would
    // rebuild seven node graphs per drag tick, so node edits are debounced
    // and only structural layout changes refresh immediately — those are the
    // ones that add or remove a cell, where a stale rail would be visibly
    // wrong rather than merely a few hundred milliseconds behind.
    property var _previewTheme: ({ tokens: ({}) })

    function _refreshPreview() {
        if (!_wt) return
        previewDebounce.stop()
        _previewTheme = ({ tokens: _wt.toTokens() })
    }

    Timer {
        id: previewDebounce
        interval: 350
        onTriggered: root._refreshPreview()
    }

    Connections {
        target: root._wt
        function onLayoutsChanged()       { root._refreshPreview() }
        function onCurrentLayoutChanged() { root._refreshPreview() }
        function onNodesChanged()         { previewDebounce.restart() }
        function onCanvasChanged()        { previewDebounce.restart() }
        function onNodeStyleChanged(id, field) { previewDebounce.restart() }
        function onNodeDataChanged (id, field) { previewDebounce.restart() }
    }

    Component.onCompleted: _refreshPreview()

    // ── Mutations ──────────────────────────────────────────────────────
    // Every structural change snapshots history, so Ctrl+Z undoes adding a
    // design exactly as it undoes moving a node. Switching designs does NOT
    // — that is a selection, like which node is selected, and burning an
    // undo step on it would make Ctrl+Z stop doing what the author expects.
    function _add(layoutId, name) {
        const id = _wt.addLayout(layoutId || "", name || "")
        if (!id) return
        _wt.setCurrentLayout(id)
        workspace.saveToHistory()
    }

    function _promptCustom() {
        const wt = _wt
        const ws = workspace
        AppState.openModal("naming", {
            title:        qsTr("New design"),
            placeholder:  qsTr("Design name"),
            confirmText:  qsTr("Create"),
            initialValue: qsTr("Custom design"),
            onConfirm:    function(name) {
                if (!name || name.length === 0) return
                const id = wt.addLayout("", name)
                if (!id) return
                wt.setCurrentLayout(id)
                ws.saveToHistory()
            }
        })
    }

    function _promptRename(layoutId, current) {
        const wt = _wt
        const ws = workspace
        AppState.openModal("naming", {
            title:        qsTr("Rename design"),
            placeholder:  qsTr("Design name"),
            confirmText:  qsTr("Save"),
            initialValue: current,
            onConfirm:    function(name) {
                if (!name || name.length === 0) return
                wt.renameLayout(layoutId, name)
                ws.saveToHistory()
            }
        })
    }

    function _openMenu(originItem, mouseX, mouseY, layoutId) {
        const wt   = _wt
        const ws   = workspace
        const l    = wt.layout(layoutId)
        const idx  = wt.indexOfLayout(layoutId)
        const last = wt.layouts.length <= 1
        const name = l.name || layoutId

        AppState.openContextMenuAt(originItem, mouseX, mouseY, [
            { label: qsTr("Rename…"), iconName: "edit",
              action: function() { root._promptRename(layoutId, name) } },
            { label: qsTr("Duplicate"), iconName: "copy",
              action: function() {
                  const id = wt.duplicateLayout(layoutId)
                  if (id) { wt.setCurrentLayout(id); ws.saveToHistory() }
              } },
            { separator: true },
            // Dimmed rather than hidden on the design that already IS the
            // default, so the entry keeps a stable position and the check
            // mark reads as state instead of the item vanishing.
            { label: qsTr("Set as default"), iconName: "star",
              enabled: !l["default"],
              action: function() { wt.setDefaultLayout(layoutId); ws.saveToHistory() } },
            { label: qsTr("Move left"), iconName: "arrow-left",
              enabled: idx > 0,
              action: function() { wt.moveLayout(layoutId, -1); ws.saveToHistory() } },
            { label: qsTr("Move right"), iconName: "arrow-right",
              enabled: idx >= 0 && idx < wt.layouts.length - 1,
              action: function() { wt.moveLayout(layoutId, 1); ws.saveToHistory() } },
            { separator: true },
            // A theme with no design renders nothing at all, so the last one
            // cannot go. WorkingTheme refuses it too; this is the visible
            // half of the same rule.
            { label: qsTr("Delete design"), iconName: "trash", destructive: true,
              enabled: !last,
              action: function() { wt.removeLayout(layoutId); ws.saveToHistory() } }
        ], { menuWidth: 200 })
    }

    function _openAddMenu(originItem) {
        const wt    = _wt
        const items = []
        const unused = wt.unusedStandardLayoutIds()
        for (let i = 0; i < unused.length; i++) {
            const id = unused[i]
            items.push({
                label: ThemeService.defaultLayoutName(id),
                iconName: "plus",
                action: function() { root._add(id, "") }
            })
        }
        // The standard ids come first and the custom option last, because a
        // standard id is the one that survives a theme swap: a deck built on
        // "section" still reads as a section divider under someone else's
        // theme, while a custom id falls back to the default design. Nudging
        // toward the shared vocabulary costs the author nothing.
        if (items.length > 0) items.push({ separator: true })
        items.push({
            label: qsTr("Custom design…"), iconName: "edit",
            action: function() { root._promptCustom() }
        })
        AppState.openContextMenuAt(originItem, 0, originItem.height + 4, items,
                                   { menuWidth: 200, dx: -160 })
    }

    // ── Layout ─────────────────────────────────────────────────────────
    Item {
        id: railHeader
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Theme.space.md
        anchors.rightMargin: Theme.space.md
        height: 30

        Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: qsTr("Designs")
            color: Theme.color.textTertiary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.smallSize
            font.weight: Theme.font.weightMedium
        }

        GhostButton {
            id: addBtn
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            height: 26
            iconName: "plus"
            text: qsTr("Add design")
            onClicked: root._openAddMenu(addBtn)
        }
    }

    ListView {
        id: rail
        anchors.top: railHeader.bottom
        anchors.topMargin: 2
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: Theme.space.md
        anchors.rightMargin: Theme.space.md
        anchors.bottomMargin: Theme.space.sm
        orientation: ListView.Horizontal
        // Bind to the COUNT, not the array: reassigning the model rebuilds
        // every delegate, and each delegate here owns a live node graph.
        model: root._layouts.length
        spacing: Theme.space.sm
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.horizontal: AppScrollBar { }

        delegate: Item {
            id: cell
            width: 116
            height: rail.height

            readonly property var    _layout: root._layouts[index] || ({})
            readonly property string _id:     cell._layout.id || ""
            readonly property bool   _isSel:  cell._id === root._curId
            readonly property bool   _isDef:  !!cell._layout["default"]

            Rectangle {
                id: thumb
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottomMargin: 18
                height: parent.height - 18
                color: Theme.color.canvas
                border.width: cell._isSel ? 2 : 1
                border.color: cell._isSel        ? Theme.color.brand
                            : cellHover.hovered  ? Theme.color.borderStrong
                                                 : Theme.color.borderSubtle
                clip: true

                ThemePreview {
                    anchors.fill: parent
                    anchors.margins: 2
                    theme: root._previewTheme
                    layoutId: cell._id
                    // A rail of live mesh gradients is real frame budget
                    // spent on a picker sitting next to the canvas that is
                    // already animating the same theme.
                    autoPlayVideos: false
                }

                // The default design is the one every non-presentation kind
                // renders and the one a missing slide layout falls back to,
                // so it earns a persistent mark rather than a menu the
                // author has to open to find out.
                Rectangle {
                    visible: cell._isDef
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.margins: 3
                    width: 16; height: 16
                    color: Theme.color.overlay
                    AppIcon {
                        anchors.centerIn: parent
                        name: "star"
                        size: 10
                        color: Theme.color.brand
                    }
                }

                Rectangle {
                    id: kebab
                    anchors.top: parent.top
                    anchors.right: parent.right
                    anchors.margins: 3
                    width: 20; height: 20
                    visible: cellHover.hovered
                    color: kebabMa.containsMouse ? Theme.color.brandSubtle
                                                 : Theme.color.overlay
                    AppIcon {
                        anchors.centerIn: parent
                        name: "more-vertical"
                        size: Theme.icon.sm
                        color: Theme.color.textPrimary
                    }
                    MouseArea {
                        id: kebabMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root._openMenu(kebab, 0, kebab.height, cell._id)
                    }
                }
            }

            Text {
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                maximumLineCount: 1
                text: cell._layout.name || cell._id
                color: cell._isSel ? Theme.color.textPrimary : Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                font.weight: cell._isSel ? Theme.font.weightSemiBold
                                         : Theme.font.weightRegular
            }

            // HoverHandler rather than the MouseArea's containsMouse: the
            // kebab button stacked on top steals the pointer, and a plain
            // MouseArea would hide the very button the author is reaching
            // for the moment the cursor touched it.
            HoverHandler { id: cellHover }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: Qt.PointingHandCursor
                onClicked: function(mouse) {
                    if (mouse.button === Qt.RightButton)
                        root._openMenu(cell, mouse.x, mouse.y, cell._id)
                    else
                        root._wt.setCurrentLayout(cell._id)
                }
            }
        }
    }

    // Separator against the canvas below.
    Rectangle {
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 1
        color: Theme.color.borderSubtle
    }
}
