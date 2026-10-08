import QtQuick
import QtQuick.Window
import Crater

// Full-screen theme editor — mounted by Main.qml when AppState.workspaceMode
// is "themeEditor". Owns the WorkingTheme instance, the undo/redo stack, the
// canvas selection state, and the property-panel inputs. On Save, ships the
// working tokens back to ThemeService.create/update. On Cancel/Close, just
// drops the working copy — the database is untouched until Save.
//
// Layout:
//   ┌─ Header (56px) ─────────────────────────────────────────────────┐
//   ├─ Toolbar (44px) ────────────────────────────────────────────────┤
//   │ Layers │  Canvas (16:9 letterbox, checkerboard, handles)  │ Props│
//   │ 240px  │                                                   │ 320px│
//   ├─ Footer (56px) ─────────────────────────────────────────────────┤
//   └──────────────────────────────────────────────────────────────────┘
Rectangle {
    id: workspace
    color: Theme.color.canvas

    // ── Props from AppState ───────────────────────────────────────────
    property int    themeId: -1          // -1 = new theme
    property string themeKind: "song"

    // ── Working state ─────────────────────────────────────────────────
    // Expose the WorkingTheme instance as a property on the workspace so
    // child components in other .qml files (LayersPanel, EditorCanvas,
    // PropertiesPanel, etc.) can reach it via `workspace.workingTheme`.
    // Without this alias, those external files would only see undeclared
    // properties — ids defined inside this file are not visible across
    // file boundaries.
    property alias workingTheme: _workingThemeInst

    WorkingTheme {
        id: _workingThemeInst
    }
    property string themeName: ""
    property string selectedNodeId: ""
    // Hover + Alt state for the Figma-style measurement overlay. Transient
    // UI state (like selectedNodeId) — never persisted, never in history.
    // hoveredNodeId: node currently under the cursor. measureAlt: Alt held,
    // sampled from hover-move events. The overlay shows only when a node
    // is selected AND a *different* node is hovered AND Alt is down.
    property string hoveredNodeId: ""
    property bool   measureAlt:    false
    property real   zoom: 1.0
    // Gates keyboard shortcuts (Ctrl+Z/Y, Delete, arrow-nudge, …): when a
    // text-editing widget has focus the user is typing, so those keys must
    // go to the field, not the editor.
    //
    // DERIVED, not mirrored. The previous version was a hand-set
    // `property bool` flipped by every input's onActiveFocusChanged — but
    // when a focused input is destroyed (switching nodes swaps the
    // PropertiesPanel Loader content; deselecting unloads it) Qt doesn't
    // fire the focus-lost signal, so the flag stuck `true` and every
    // shortcut went permanently dead. Reading Window.activeFocusItem is
    // reactive and self-correcting: destroy the focused input and this
    // re-evaluates to false on the next tick. Catches every text widget
    // transitively — NumericInput's TextInput, the name field, the
    // custom-text TextEdit, the font combobox's search field.
    readonly property bool inputFocused: {
        const fi = Window.activeFocusItem
        return !!fi && (fi instanceof TextInput || fi instanceof TextEdit)
    }

    // History stack — snapshots produced by WorkingTheme.toTokens(). Capped
    // at 50; we drop the oldest entry when overflowing. saveTimestamp
    // tracks which history index matches the on-disk theme so the
    // "Unsaved" indicator can fire only when we've actually diverged.
    property var historyStack: []
    property int historyIndex: -1
    property int savedIndex: -1
    readonly property bool hasUnsavedChanges: historyIndex !== savedIndex

    readonly property bool _isNew:     themeId <= 0
    readonly property bool _isBuiltin: {
        if (_isNew) return false
        const t = ThemeService.theme(themeId)
        return !!(t && t.isBuiltin)
    }
    readonly property var selectedNode: selectedNodeId
        ? workingTheme.node(selectedNodeId)
        : null

    // ── Initial load ──────────────────────────────────────────────────
    Component.onCompleted: {
        if (_isNew) {
            // Start with a sensible default for a new theme: a full-canvas
            // dark container + a centered text node tied to the kind's
            // typical content. Same shape buildV2FromV1 produces.
            const defaults = _newThemeTokens(themeKind)
            workingTheme.loadFrom(defaults)
            themeName = qsTr("Untitled")
        } else {
            const t = ThemeService.theme(themeId)
            if (t && t.id) {
                workingTheme.loadFrom(t.tokens)
                themeName = t.name
            }
        }
        // Initial snapshot — index 0 is the as-loaded state.
        saveToHistory()
        savedIndex = historyIndex
    }

    // A new theme starts with ONE design. The rail's Add builds the rest,
    // and each one inherits this design's background and text styling, so
    // seeding all seven standard layouts up front would only hand the author
    // six more designs to curate before they have decided what the first one
    // looks like.
    function _newThemeTokens(kind) {
        const linkage = kind === "song"         ? "lyric"
                      : kind === "scripture"    ? "scriptureText"
                      : kind === "presentation" ? "presentationBody"
                                                : "custom"
        return {
            version: 3,
            canvas: { width: 1920, height: 1080 },
            layouts: [{
              id: "content",
              name: qsTr("Title + content"),
              "default": true,
              nodes: [
                { id: "bg",  kind: "container",
                  style: { x: 0, y: 0, width: 100, height: 100, z: 0, opacity: 1,
                           backgroundColor: "#0a0a0d" },
                  data:  { layerName: "Background",
                           mediaId: null, bgOpacity: 1, overlayColor: null } },
                { id: "txt", kind: "text",
                  style: { x: 5, y: 35, width: 90, height: 30, z: 10, opacity: 1,
                           color: "#f5f5f0", fontFamily: "Segoe UI Variable Display",
                           fontPixelSize: 64, fontWeight: 500,
                           lineHeightMultiplier: 1.25, letterSpacing: 0,
                           textAlign: "center", verticalAlign: "center" },
                  data:  { layerName: "Text", linkage: linkage,
                           text: linkage === "custom" ? qsTr("New text") : "",
                           autoResize: true, maxFontSize: 220 } }
              ]
            }]
        }
    }

    // ── History ───────────────────────────────────────────────────────
    function saveToHistory() {
        const snapshot = JSON.parse(JSON.stringify(workingTheme.toTokens()))
        historyStack = historyStack.slice(0, historyIndex + 1).concat([snapshot])
        if (historyStack.length > 50) {
            historyStack.shift()
            savedIndex = Math.max(-1, savedIndex - 1)
        } else {
            historyIndex = historyStack.length - 1
        }
    }
    function undo() {
        if (historyIndex <= 0) return
        historyIndex--
        _restoreSnapshot(historyStack[historyIndex])
    }
    function redo() {
        if (historyIndex >= historyStack.length - 1) return
        historyIndex++
        _restoreSnapshot(historyStack[historyIndex])
    }
    // loadFrom re-emits currentLayoutChanged even when the design stays the
    // same, and that clears the selection (see the Connections below). An
    // undo or redo keeps the layer selected when it is still in the same
    // design, so the operator can keep stepping through its edits.
    function _restoreSnapshot(snapshot) {
        const keepId     = selectedNodeId
        const keepLayout = workingTheme.currentLayoutId
        workingTheme.loadFrom(JSON.parse(JSON.stringify(snapshot)))
        if (keepId !== "" && workingTheme.currentLayoutId === keepLayout
                && workingTheme.indexOf(keepId) >= 0)
            selectedNodeId = keepId
    }

    // ── Mock content (preview / editor canvas) ────────────────────────
    readonly property string mockScriptureRef:  "John 3:16"
    readonly property string mockScriptureText: "For God so loved the world, that he gave his only begotten Son, that whosoever believeth in him should not perish, but have everlasting life."
    readonly property string mockLyric:         "Amazing grace, how sweet the sound\nThat saved a wretch like me"
    readonly property string mockSlideTitle:    "The God Who Pursues"
    readonly property string mockSlideBody:     "He does not wait at the edge of the far country.\nHe runs."
    // Distinct strings per slot, matching ThemePreview's, so a two-column
    // design reads as two columns on the canvas instead of the same sentence
    // twice and the author can judge the balance between them.
    readonly property string mockSlideSubtitle:  "Luke 15"
    readonly property string mockSlideBodyRight: "The elder son stayed home and was just as lost."
    // Shown whatever the Show author / Show CCLI toggles say, so the author
    // can always see and style the node they placed.
    readonly property string mockSongCredits:    "John Newton · CCLI 22025"

    function resolveText(node) {
        if (!node || node.kind !== "text") return ""
        const data = node.data || {}
        switch (data.linkage) {
            case "scriptureRef":      return mockScriptureRef
            case "scriptureText":     return mockScriptureText
            case "lyric":             return mockLyric
            case "presentationTitle": return mockSlideTitle
            case "presentationBody":  return mockSlideBody
            case "presentationSubtitle":  return mockSlideSubtitle
            case "presentationBodyRight": return mockSlideBodyRight
            case "songCredits":       return mockSongCredits
            case "custom":            return data.text || qsTr("(empty)")
        }
        return ""
    }

    // A node id only means anything within the design it belongs to, so a
    // selection cannot survive a switch: keeping it would leave the
    // properties panel bound to a node the canvas is no longer drawing.
    Connections {
        target: workspace.workingTheme
        function onCurrentLayoutChanged() { workspace.selectedNodeId = "" }
        function onNodeDataChanged(id, field) {
            if (field === "group" || field === "autoHeight" || field === "autoPosition")
                workspace.layoutRev++
        }
    }

    // ── Moving a laid-out layer ─────────────────────────────────────────
    // Some geometry is decided by the auto-layout, not by style (see
    // ThemedNodeGraph). Every tool that moves or sizes a layer asks here
    // (canvas drag, arrow keys, the align buttons, the X/Y/W/H fields), so
    // they all agree on what an edit to a laid-out layer does:
    //   card member     : the card moves instead. Its own box isn't editable.
    //   autoPosition    : its top follows another layer. No y.
    //   hug of another  : top and height follow the layer it wraps.
    // A card or a self-hug keeps its height: that box is what the card
    // anchors inside, and the inspector is the only way to set it.
    //
    // layoutRev bumps on the data edits that rewire a card, hug or stack.
    // setNodeData doesn't emit nodesChanged, so readers of the node list
    // depend on this as well. Structural edits already emit nodesChanged.
    property int layoutRev: 0
    function layoutRuleOf(id) {
        layoutRev   // dependency
        const ns = workingTheme.nodes || []
        let self = null, card = null
        for (let i = 0; i < ns.length; i++) {
            const n = ns[i]
            if (n.id === id) self = n
            const g = n.data && n.data.group
            if (!card && g && g.members && g.members.indexOf(id) >= 0) card = n
        }
        if (!self) return null
        const selfLocked = !!(self.data && self.data.locked)
        if (card) {
            const cd = card.data || {}
            return { target: card.id, member: true, locked: selfLocked || !!cd.locked,
                     y: !cd.autoPosition, size: false, height: false }
        }
        const d  = self.data || {}
        const ah = d.autoHeight
        const wraps = !!ah && (!!(ah.from && ah.to)
                               || !(ah.source === "self" || ah.source === id))
        return { target: id, member: false, locked: selfLocked,
                 y: !d.autoPosition && !wraps, size: true, height: !wraps }
    }

    // Where a layer shows on the canvas, in percent of the canvas: the box
    // the layout put it in, which for a card, hug or stack isn't its style.
    function shownBoxOf(id) {
        const g = editorCanvas.paintGraph
        const r = g ? g.layoutRectOf(id) : null
        if (r && g.width > 0 && g.height > 0)
            return { x: r.x / g.width * 100,     y: r.y / g.height * 100,
                     width: r.width / g.width * 100, height: r.height / g.height * 100 }
        const n = workingTheme.node(id)
        const s = (n && n.style) || {}
        return { x: s.x || 0, y: s.y || 0, width: s.width || 0, height: s.height || 0 }
    }

    // ── Design with AI ──────────────────────────────────
    // Opens the copy-a-prompt / paste-the-reply dialog. What comes back
    // lands in the WORKING copy as a single undo step, so a design that
    // misses is one Ctrl+Z away and never reaches the themes list. The
    // dialog validates the paste with ThemeService before calling this, so
    // anything arriving here is already known to survive Save.
    function openAiDesign() {
        AppState.openModal("aiDesign", {
            kind:          workspace.themeKind,
            currentTokens: workspace.workingTheme.toTokens(),
            onApply: function(tokens, name, kind) {
                workspace.workingTheme.loadFrom(tokens)
                workspace.selectedNodeId = ""
                // The AI names what it designs. On a theme still sitting at
                // its placeholder name that beats "Untitled", but on one the
                // user has already named it is not ours to overwrite.
                if (name && workspace._isNew
                    && (workspace.themeName === ""
                        || workspace.themeName === qsTr("Untitled"))) {
                    workspace.themeName = name
                }
                workspace.saveToHistory()
            }
        })
    }

    // ── Save / cancel ─────────────────────────────────────────────────
    // Surfaced when ThemeService refuses the tokens (validation) or the
    // write itself fails. The C++ side logs to qWarning and returns a
    // sentinel; without echoing it back to the UI the button looks dead.
    property string saveError: ""

    function saveTheme() {
        if (!themeName || themeName.length === 0) return
        const tokens = workingTheme.toTokens()

        // Pre-validate via the same checker create()/update() use, so the
        // user sees the specific reason in-place instead of an inert button.
        const errs = ThemeService.validateTokens(tokens)
        if (errs.length > 0) {
            saveError = errs.join(" · ")
            saveErrorClearTimer.restart()
            return
        }

        if (workspace._isNew) {
            const newId = ThemeService.create(themeKind, themeName, tokens)
            if (newId > 0) {
                workspace.themeId = newId
                workspace.savedIndex = workspace.historyIndex
                AppState.closeThemeEditor()
            } else {
                saveError = qsTr("Could not save theme. Check the log for details.")
                saveErrorClearTimer.restart()
            }
        } else {
            ThemeService.update(themeId, themeName, tokens)
            workspace.savedIndex = workspace.historyIndex
            AppState.closeThemeEditor()
        }
    }

    Timer {
        id: saveErrorClearTimer
        interval: 8000
        onTriggered: workspace.saveError = ""
    }

    function requestClose() {
        if (hasUnsavedChanges) confirmOverlay.openConfirm()
        else AppState.closeThemeEditor()
    }

    // ── Layout ────────────────────────────────────────────────────────
    EditorHeader {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 56
        workspace: workspace
    }

    EditorToolbar {
        id: toolbar
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 44
        workspace: workspace
    }

    EditorFooter {
        id: footer
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        // Grows to accommodate the inline error bar when saveError is set;
        // the canvas region shrinks instead of the Save button shifting.
        height: workspace.saveError.length > 0 ? 88 : 56
        Behavior on height {
            NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
        }
        workspace: workspace
    }

    Rectangle {
        anchors.top: toolbar.bottom
        anchors.bottom: footer.top
        anchors.left: parent.left
        anchors.right: parent.right
        color: "transparent"

        LayersPanel {
            id: layersPanel
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            width: 240
            workspace: workspace
        }

        Rectangle {
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.left: layersPanel.right
            anchors.right: propsPanel.left
            color: Theme.color.bgContent

            // Presentation themes only. Every other kind renders one design
            // and has no way to name a second — a lyric slide is a lyric
            // slide — so a rail there would let an author build layouts
            // nothing could ever select, which is worse than not offering it.
            LayoutRail {
                id: layoutRail
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                visible: workspace.themeKind === "presentation"
                height: visible ? implicitHeight : 0
                workspace: workspace
            }

            EditorCanvas {
                id: editorCanvas
                anchors.top: layoutRail.bottom
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                workspace: workspace
            }
        }

        PropertiesPanel {
            id: propsPanel
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.right: parent.right
            width: 320
            workspace: workspace
        }
    }

    // ── Confirmation overlay (above panels, below modal layer) ────────
    ConfirmationOverlay {
        id: confirmOverlay
        anchors.fill: parent
        title: qsTr("Discard changes?")
        body: qsTr("Your unsaved edits will be lost.")
        confirmLabel: qsTr("Discard")
        onConfirmed: AppState.closeThemeEditor()
    }

    // ── Keyboard shortcuts ────────────────────────────────────────────
    Shortcut { sequence: "Ctrl+Z";          enabled: !workspace.inputFocused; onActivated: workspace.undo() }
    Shortcut { sequence: "Ctrl+Y";          enabled: !workspace.inputFocused; onActivated: workspace.redo() }
    Shortcut { sequence: "Ctrl+Shift+Z";    enabled: !workspace.inputFocused; onActivated: workspace.redo() }
    Shortcut { sequence: "Ctrl+S";          onActivated: workspace.saveTheme() }
    Shortcut { sequence: "Ctrl+D"
        enabled: !workspace.inputFocused && workspace.selectedNodeId !== ""
        onActivated: {
            const id = workingTheme.duplicateNode(workspace.selectedNodeId)
            if (id) { workspace.selectedNodeId = id; workspace.saveToHistory() }
        } }
    Shortcut { sequence: "Delete"
        enabled: !workspace.inputFocused && workspace.selectedNodeId !== ""
        onActivated: {
            workingTheme.removeNode(workspace.selectedNodeId)
            workspace.selectedNodeId = ""
            workspace.saveToHistory()
        } }
    // Off while a modal is open over the workspace: Main.qml's Escape closes
    // that modal then. Off while a colour picker is open too, whose own
    // Escape closes just the picker and leaves the layer selected. The
    // trailing-Escape check stops the second press of a double tap that
    // closed a dialog from also deselecting or closing.
    Shortcut { sequence: "Escape"
        enabled: AppState.activeModal === "" && !AppState.colorPopoverOpen
        onActivated: {
            if (AppState.isTrailingEscape()) return
            if (workspace.selectedNodeId !== "") workspace.selectedNodeId = ""
            else workspace.requestClose()
        } }
    Shortcut { sequence: "Ctrl+0";          onActivated: workspace.zoom = 1.0 }
    // Same 10% steps and 10-400% range as the toolbar and canvas menu.
    // Ctrl+= is the unshifted key Ctrl++ lives on.
    Shortcut { sequences: ["Ctrl++", "Ctrl+="]
        onActivated: workspace.zoom = Math.min(4.0, Math.round((workspace.zoom + 0.1) * 10) / 10) }
    Shortcut { sequence: "Ctrl+-"
        onActivated: workspace.zoom = Math.max(0.1, Math.round((workspace.zoom - 0.1) * 10) / 10) }

    // Arrow nudge — 1% normally, 5% with Shift. Range matches the drag
    // and direct-input clamps (-200..200) so all three movement paths
    // agree on what's reachable.
    // Same rule as a canvas drag (layoutRuleOf): a card member nudges its
    // card, and up / down do nothing where the layout decides the top.
    function _nudge(dx, dy) {
        const id = workspace.selectedNodeId
        if (!id) return
        const rule = layoutRuleOf(id)
        if (!rule || rule.locked) return
        const n = workingTheme.node(rule.target)
        if (!n || !n.style) return
        workingTheme.setNodeStyle(rule.target, "x", Math.max(-200, Math.min(200,
            Math.round(((n.style.x || 0) + dx) * 10) / 10)))
        if (rule.y)
            workingTheme.setNodeStyle(rule.target, "y", Math.max(-200, Math.min(200,
                Math.round(((n.style.y || 0) + dy) * 10) / 10)))
    }
    Shortcut { sequence: "Left";        enabled: !workspace.inputFocused; onActivated: workspace._nudge(-1, 0) }
    Shortcut { sequence: "Right";       enabled: !workspace.inputFocused; onActivated: workspace._nudge( 1, 0) }
    Shortcut { sequence: "Up";          enabled: !workspace.inputFocused; onActivated: workspace._nudge( 0, -1) }
    Shortcut { sequence: "Down";        enabled: !workspace.inputFocused; onActivated: workspace._nudge( 0,  1) }
    Shortcut { sequence: "Shift+Left";  enabled: !workspace.inputFocused; onActivated: workspace._nudge(-5, 0) }
    Shortcut { sequence: "Shift+Right"; enabled: !workspace.inputFocused; onActivated: workspace._nudge( 5, 0) }
    Shortcut { sequence: "Shift+Up";    enabled: !workspace.inputFocused; onActivated: workspace._nudge( 0, -5) }
    Shortcut { sequence: "Shift+Down";  enabled: !workspace.inputFocused; onActivated: workspace._nudge( 0,  5) }
}
