import QtQuick
import Crater

import "../workspaces/editor" as Editor
import "../components" as Components

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
    WorkingTheme {
        id: workingTheme
    }
    property string themeName: ""
    property string selectedNodeId: ""
    property real   zoom: 1.0
    property bool   inputFocused: false  // gates keyboard shortcuts

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

    function _newThemeTokens(kind) {
        const linkage = kind === "song"      ? "lyric"
                      : kind === "scripture" ? "scriptureText"
                                             : "custom"
        return {
            version: 2,
            canvas: { width: 1920, height: 1080 },
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
                           autoResize: false, maxFontSize: 220 } }
            ]
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
        workingTheme.loadFrom(JSON.parse(JSON.stringify(historyStack[historyIndex])))
    }
    function redo() {
        if (historyIndex >= historyStack.length - 1) return
        historyIndex++
        workingTheme.loadFrom(JSON.parse(JSON.stringify(historyStack[historyIndex])))
    }

    // ── Mock content (preview / editor canvas) ────────────────────────
    readonly property string mockScriptureRef:  "John 3:16"
    readonly property string mockScriptureText: "For God so loved the world, that he gave his only begotten Son, that whosoever believeth in him should not perish, but have everlasting life."
    readonly property string mockLyric:         "Amazing grace, how sweet the sound\nThat saved a wretch like me"

    function resolveText(node) {
        if (!node || node.kind !== "text") return ""
        const data = node.data || {}
        switch (data.linkage) {
            case "scriptureRef":  return mockScriptureRef
            case "scriptureText": return mockScriptureText
            case "lyric":         return mockLyric
            case "custom":        return data.text || qsTr("(empty)")
        }
        return ""
    }

    // ── Save / cancel ─────────────────────────────────────────────────
    function saveTheme() {
        if (!themeName || themeName.length === 0) return
        const tokens = workingTheme.toTokens()
        if (workspace._isNew) {
            const newId = ThemeService.create(themeKind, themeName, tokens)
            if (newId > 0) {
                workspace.themeId = newId
                workspace.savedIndex = workspace.historyIndex
                AppState.closeThemeEditor()
            }
        } else {
            ThemeService.update(themeId, themeName, tokens)
            workspace.savedIndex = workspace.historyIndex
            AppState.closeThemeEditor()
        }
    }
    function requestClose() {
        if (hasUnsavedChanges) confirmOverlay.openConfirm()
        else AppState.closeThemeEditor()
    }

    // ── Layout ────────────────────────────────────────────────────────
    Editor.EditorHeader {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 56
        workspace: workspace
    }

    Editor.EditorToolbar {
        id: toolbar
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 44
        workspace: workspace
    }

    Editor.EditorFooter {
        id: footer
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 56
        workspace: workspace
    }

    Rectangle {
        anchors.top: toolbar.bottom
        anchors.bottom: footer.top
        anchors.left: parent.left
        anchors.right: parent.right
        color: "transparent"

        Editor.LayersPanel {
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

            Editor.EditorCanvas {
                anchors.fill: parent
                workspace: workspace
            }
        }

        Editor.PropertiesPanel {
            id: propsPanel
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.right: parent.right
            width: 320
            workspace: workspace
        }
    }

    // ── Confirmation overlay (above panels, below modal layer) ────────
    Components.ConfirmationOverlay {
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
    Shortcut { sequence: "Escape"
        onActivated: {
            if (workspace.selectedNodeId !== "") workspace.selectedNodeId = ""
            else workspace.requestClose()
        } }
    Shortcut { sequence: "Ctrl+0";          onActivated: workspace.zoom = 1.0 }

    // Arrow nudge — 1% normally, 5% with Shift.
    function _nudge(dx, dy) {
        const id = workspace.selectedNodeId
        if (!id) return
        const n = workingTheme.node(id)
        if (!n || !n.style) return
        workingTheme.setNodeStyle(id, "x", Math.max(0, Math.min(100,
            Math.round(((n.style.x || 0) + dx) * 10) / 10)))
        workingTheme.setNodeStyle(id, "y", Math.max(0, Math.min(100,
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
