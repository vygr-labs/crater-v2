import QtQuick

// Window-level overlay for all modal UI: dialogs and popover menus.
//
// Each modal type gets its own Loader. The Loader's `active` is driven by
// AppState.activeModal, so when nothing's open all 8 Loaders are inactive
// and the layer holds only an invisible Item — zero overdraw, zero memory.
//
// When a Loader becomes active, it instantiates its component on demand.
// Closing the modal sets activeModal to "", which deactivates the Loader
// and frees the component. No leaks across open/close cycles.
Item {
    id: root

    // ── Settings ────────────────────────────────────────────────────────
    Loader {
        anchors.fill: parent
        active: AppState.activeModal === "settings"
        sourceComponent: SettingsDialog { }
    }

    // ── Song editor ─────────────────────────────────────────────────────
    Loader {
        anchors.fill: parent
        active: AppState.activeModal === "songEditor"
        sourceComponent: SongEditorDialog { }
    }

    // The theme editor is now a full-screen workspace, not a modal —
    // see ThemeEditorWorkspace.qml mounted in Main.qml under the
    // AppState.workspaceMode === "themeEditor" gate.

    // ── Naming (e.g., "name your new collection") ───────────────────────
    Loader {
        anchors.fill: parent
        active: AppState.activeModal === "naming"
        sourceComponent: NamingDialog { }
    }

    // ── Confirm (destructive actions) ───────────────────────────────────
    Loader {
        anchors.fill: parent
        active: AppState.activeModal === "confirm"
        sourceComponent: ConfirmDialog { }
    }

    // ── Import ──────────────────────────────────────────────────────────
    Loader {
        anchors.fill: parent
        active: AppState.activeModal === "import"
        sourceComponent: ImportDialog { }
    }

    // ── Schedule dropdown popover (anchored under TopBar) ───────────────
    Loader {
        anchors.fill: parent
        active: AppState.activeModal === "scheduleDropdown"
        sourceComponent: ScheduleDropdownPopover { }
    }

    // ── Context menu (right-click, gear menus, etc.) ────────────────────
    Loader {
        anchors.fill: parent
        active: AppState.activeModal === "contextMenu"
        sourceComponent: PopoverMenu {
            // Auto-open when instantiated. Properties read from modalProps
            // at load-time; the Loader is destroyed on close so no stale
            // bindings.
            active: true
            anchorX: AppState.modalProps.anchorX || 0
            anchorY: AppState.modalProps.anchorY || 0
            menuWidth: AppState.modalProps.menuWidth || 220
            model: AppState.modalProps.items || []
            // We deliberately do NOT close the modal on itemActivated — the
            // PopoverMenu's own onClicked still calls close() at the end of
            // its handler, which flips `active` and gets us here via
            // onActiveChanged. The guard below stops us clobbering some
            // other modal (e.g. "confirm") that the action handler opened
            // synchronously — previously every site that did that needed
            // a Qt.callLater workaround.
            onActiveChanged: {
                if (!active && AppState.activeModal === "contextMenu")
                    AppState.closeModal()
            }
        }
    }
}
