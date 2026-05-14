import QtQuick
import QtQuick.Window
import QtQuick.Controls.Basic
import QtQuick.Layouts

// Operator console — the single window for the production team. Composes
// the panels defined in qml/panels/, listens to global keyboard shortcuts,
// and renders modals/popovers on top via ModalLayer.
//
// All UI state lives in AppState (a QML singleton). Each child component
// reads from and writes to AppState directly — no prop drilling.
ApplicationWindow {
    id: root

    width: 1440
    height: 900
    minimumWidth: 1080
    minimumHeight: 680
    visible: true
    title: qsTr("Crater")
    color: Theme.color.canvas

    // The operator console (top bar / main area / footer) is hidden when a
    // full-screen workspace is open. The workspace Loader below this region
    // takes over the window — closing it (AppState.closeThemeEditor()) sets
    // workspaceMode back to "" and the console becomes visible again.
    readonly property bool _consoleVisible: AppState.workspaceMode === ""

    // ── Top bar ─────────────────────────────────────────────────────────
    TopBar {
        id: topBar
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        visible: root._consoleVisible
    }

    // ── Main work surface ───────────────────────────────────────────────
    Item {
        id: mainArea

        visible: root._consoleVisible
        anchors.top: topBar.bottom
        anchors.bottom: footerBar.top
        anchors.left: parent.left
        anchors.right: parent.right

        // Top row split ratio. A future Workspace system will let users
        // drag a horizontal grip to adjust this; today it's a static
        // constant matching the existing visual design.
        readonly property real topRowRatio: 0.58

        // ── Top row: Schedule | Preview | Live ───────────────────────────
        Item {
            id: topRow

            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: parent.height * mainArea.topRowRatio

            SchedulePanel {
                id: schedulePane
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                width: parent.width * 0.30
            }

            PreviewPanel {
                id: previewPane
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.left: schedulePane.right
                anchors.right: livePane.left
            }

            LivePanel {
                id: livePane
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.right: parent.right
                width: parent.width * 0.36
            }
        }

        // ── Mid divider ──────────────────────────────────────────────────
        Rectangle {
            id: midDivider
            anchors.top: topRow.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: 1
            color: Theme.color.borderSubtle
        }

        // ── Bottom row: tab bar + (sidebar | content) ────────────────────
        Item {
            id: bottomRow
            anchors.top: midDivider.bottom
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right

            LibraryTabBar {
                id: tabBar
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
            }

            LibrarySidebar {
                id: librarySidebar
                anchors.top: tabBar.bottom
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                width: parent.width * 0.24
            }

            LibraryContent {
                id: libraryContent
                anchors.top: tabBar.bottom
                anchors.bottom: parent.bottom
                anchors.left: librarySidebar.right
                anchors.right: parent.right
            }
        }
    }

    // ── Footer ──────────────────────────────────────────────────────────
    FooterBar {
        id: footerBar
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        visible: root._consoleVisible
    }

    // ── Full-screen workspaces (theme editor, future composers) ─────────
    // Lives between the operator console and the modal layer so editor
    // popovers (color picker, confirm overlay) still render above it via
    // ModalLayer. Only mounted when AppState.workspaceMode is non-empty —
    // closing returns to the operator console with no rebuild cost.
    Loader {
        id: workspaceLoader
        anchors.fill: parent
        z: 100
        active: AppState.workspaceMode === "themeEditor"
        sourceComponent: active ? themeEditorWorkspaceComp : null

        Component {
            id: themeEditorWorkspaceComp
            ThemeEditorWorkspace {
                themeId:   AppState.editorThemeId
                themeKind: AppState.editorThemeKind
            }
        }
    }

    // ── Modal overlay (renders above everything, anchors.fill: parent) ──
    ModalLayer {
        anchors.fill: parent
    }

    // ── Projection output window ─────────────────────────────────────────
    // QML allows a Window to be nested inside another Window declaratively
    // — each becomes its own QQuickWindow on the OS side. We bind `visible`
    // to whether anything is live; opening/closing is implicit. See plan's
    // "Deviations from Electron" — no IPC, no Redux, the projection just
    // re-binds when ProjectionService Q_PROPERTYs change.
    ProjectionWindow {
        id: projectionWindow
        screenIndex: OutputService.selectedScreenIndex
        // Use `visibility` (not `visible`) so we can toggle FullScreen / Windowed
        // / Hidden without conflicting with ProjectionWindow.qml's own setup.
        //
        // Single source of truth: AppState.projectorVisible — set true only by
        // AppState.goLive() (the explicit "Go Live" button / Ctrl+L), and false
        // only by AppState.endLive() (the windowed projector's close button).
        // clearLive() blanks content but does not lower the projector. Item
        // clicks, library double-clicks, logo toggle, and schedule selection
        // do NOT raise or lower the projector.
        //
        // The OutputService.projectionMode arm distinguishes Fullscreen (the
        // production target — frameless, fills the selected screen) from
        // Windowed (an OS-framed preview window for single-monitor / dev).
        // Default mode is computed from available displays (see OutputService).
        visibility: !AppState.projectorVisible
                  ? Window.Hidden
                  : OutputService.projectionMode === OutputService.Windowed
                      ? Window.Windowed
                      : Window.FullScreen
    }

    // ── Keyboard shortcuts ──────────────────────────────────────────────
    // Numeric shortcuts switch tabs. Ctrl+Tab and Ctrl+Shift+Tab cycle.
    Shortcut { sequence: "Ctrl+1"; onActivated: AppState.setActiveTab(0) }
    Shortcut { sequence: "Ctrl+2"; onActivated: AppState.setActiveTab(1) }
    Shortcut { sequence: "Ctrl+3"; onActivated: AppState.setActiveTab(2) }
    Shortcut { sequence: "Ctrl+4"; onActivated: AppState.setActiveTab(3) }
    Shortcut { sequence: "Ctrl+5"; onActivated: AppState.setActiveTab(4) }
    Shortcut { sequence: "Ctrl+Tab";       onActivated: AppState.cycleTab( 1) }
    Shortcut { sequence: "Ctrl+Shift+Tab"; onActivated: AppState.cycleTab(-1) }

    // Production actions
    Shortcut { sequence: "Ctrl+,"; onActivated: AppState.openModal("settings", {}) }
    Shortcut { sequence: "Ctrl+L"; onActivated: AppState.goLive() }
    // Ctrl+. is the "clear" shortcut from the Electron version — avoids
    // colliding with system Ctrl+C (copy).
    Shortcut { sequence: "Ctrl+."; onActivated: AppState.clearLive() }
    // Ctrl+T = stage the currently focused library item. The active tab
    // (ScriptureTab / SongsTab / MediaTab) handles via its
    // onLibraryAddToSchedule listener; tabs without schedule items do nothing.
    Shortcut { sequence: "Ctrl+T"; onActivated: AppState.libraryAddToSchedule() }

    // Save the working schedule. Updates the currently loaded saved row if
    // there is one; otherwise prompts the operator for a name (Save As).
    Shortcut {
        sequence: "Ctrl+S"
        onActivated: {
            if (ScheduleService.loadedScheduleId > 0) {
                ScheduleService.saveCurrent()
            } else {
                AppState.openModal("naming", {
                    title:       qsTr("Save schedule as"),
                    placeholder: qsTr("e.g., Sunday AM - June 5"),
                    confirmText: qsTr("Save"),
                    onConfirm: function(name) {
                        if (name && name.length > 0) ScheduleService.saveAs(name)
                    }
                })
            }
        }
    }

    // Always prompt for a new name — equivalent to "Save a copy of this
    // schedule under a new name". Useful when forking a loaded schedule
    // into a variant without overwriting the original.
    Shortcut {
        sequence: "Ctrl+Shift+S"
        onActivated: AppState.openModal("naming", {
            title:       qsTr("Save schedule as"),
            placeholder: qsTr("e.g., Sunday AM - June 5"),
            confirmText: qsTr("Save"),
            onConfirm: function(name) {
                if (name && name.length > 0) ScheduleService.saveAs(name)
            }
        })
    }

    // Escape: close modal first; if no modal, deselect schedule item.
    Shortcut {
        sequence: "Escape"
        onActivated: {
            if (AppState.activeModal !== "") {
                AppState.closeModal()
            } else if (AppState.selectedScheduleIndex >= 0) {
                AppState.selectScheduleItem(-1)
            }
        }
    }

    // Delete: prompt to remove the selected schedule item(s) — only when the
    // schedule has keyboard focus. With library focus, Delete falls through
    // (a future "delete song" / "delete theme" path will own it then).
    //
    // Multi-select aware: removal is done in descending index order so each
    // removeAt() call doesn't shift the indices of items still pending
    // deletion.
    Shortcut {
        sequence: "Delete"
        enabled: AppState.selectedScheduleIndices.length > 0
              && AppState.activeModal === ""
              && AppState.activeFocusPanel === "schedule"
        onActivated: {
            const indices = AppState.selectedScheduleIndices.slice()
                .sort(function(a, b) { return b - a })
            if (indices.length === 1) {
                const i = indices[0]
                const item = ScheduleService.currentItems[i]
                AppState.openModal("confirm", {
                    title:       qsTr("Remove item?"),
                    body:        qsTr("Remove \"") + (item ? item.title : "") + qsTr("\" from the schedule?"),
                    confirmText: qsTr("Remove"),
                    onConfirm:   function() { ScheduleService.removeAt(i) }
                })
            } else {
                AppState.openModal("confirm", {
                    title:       qsTr("Remove %1 items?").arg(indices.length),
                    body:        qsTr("This will remove %1 selected items from the schedule.").arg(indices.length),
                    confirmText: qsTr("Remove"),
                    onConfirm:   function() {
                        for (let k = 0; k < indices.length; k++) {
                            ScheduleService.removeAt(indices[k])
                        }
                        AppState.clearScheduleSelection()
                    }
                })
            }
        }
    }

    // Up / Down: focus-aware navigation. Routed by AppState.activeFocusPanel
    // so an operator browsing the library list isn't moving the schedule
    // selection on every arrow press, and vice-versa.
    //
    // Note: when the TabSearchBar input has focus, its own Keys.onUpPressed
    // handles the key AND its Keys.onShortcutOverride blocks this Shortcut
    // from firing — see TabSearchBar.qml. This Shortcut only kicks in when
    // focus is OUTSIDE the input (e.g. operator clicked a verse row).
    Shortcut {
        sequence: "Up"
        enabled: AppState.activeModal === ""
        onActivated: {
            if (AppState.activeFocusPanel === "schedule") {
                if (ScheduleService.currentItems.length === 0) return
                const next = Math.max(0, AppState.selectedScheduleIndex - 1)
                AppState.selectScheduleItem(next)
            } else {
                AppState.libraryNavigateUp()
            }
        }
    }
    Shortcut {
        sequence: "Down"
        enabled: AppState.activeModal === ""
        onActivated: {
            if (AppState.activeFocusPanel === "schedule") {
                if (ScheduleService.currentItems.length === 0) return
                const max = ScheduleService.currentItems.length - 1
                const next = AppState.selectedScheduleIndex < 0
                           ? 0
                           : Math.min(max, AppState.selectedScheduleIndex + 1)
                AppState.selectScheduleItem(next)
            } else {
                AppState.libraryNavigateDown()
            }
        }
    }
}
