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
    // Open maximized on first show. `width`/`height` above become the
    // restore-down size when the user un-maximizes, so the 1440x900
    // design target is preserved as the windowed fallback.
    visibility: Window.Maximized
    title: qsTr("Crater")
    color: Theme.color.canvas

    // The operator console (top bar / main area / footer) is hidden when a
    // full-screen workspace is open. The workspace Loader below this region
    // takes over the window — closing it (AppState.closeThemeEditor()) sets
    // workspaceMode back to "" and the console becomes visible again.
    readonly property bool _consoleVisible: AppState.workspaceMode === ""

    // ── SettingsService → AppState glue ─────────────────────────────────
    // These handlers live here (rather than on AppState directly) because
    // AppState is a QtObject-rooted QML singleton and QtObject refuses
    // child objects like Connections / Component.onCompleted blocks.
    // ApplicationWindow is the closest ancestor that accepts them.
    Connections {
        target: SettingsService
        function onShowStrongsTabChanged() {
            AppState._onStrongsTabVisibilityChanged()
        }
    }

    // One-shot init of showLogo from the operator's persisted default.
    // After this fires, manual Logo button / Ctrl+L toggles take over —
    // the dialog setting governs the next launch, not live override.
    Component.onCompleted: {
        AppState.showLogo = SettingsService.showLogoByDefault
        ProjectionService.setLogoVisible(AppState.showLogo)
    }

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
        anchors.bottom: parent.bottom
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
        // the mouse-driven goLive(true) calls (TopBar "Go Live" button,
        // schedule double-click, schedule context-menu), and false only by
        // AppState.endLive() (the windowed projector's close button).
        // clearLive() blanks content but does not lower the projector.
        // Ctrl+L calls goLive(false) so the shortcut transitions content to
        // live for rehearsal without exposing the audience screen. Item
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
    // Disabled while a modal is open so dialogs (e.g. SongEditor) can
    // claim Ctrl+Tab for their own view-mode toggles without two
    // handlers fighting over the same sequence.
    Shortcut { sequence: "Ctrl+Tab";       enabled: AppState.activeModal === ""; onActivated: AppState.cycleTab( 1) }
    Shortcut { sequence: "Ctrl+Shift+Tab"; enabled: AppState.activeModal === ""; onActivated: AppState.cycleTab(-1) }

    // Production actions
    Shortcut { sequence: "Ctrl+,"; onActivated: AppState.openModal("settings", {}) }
    // Ctrl+L = toggle the logo overlay. "L for Logo." Both the projection
    // window and the live mini-monitor read AppState.showLogo (via their
    // respective LogoView components), so a single toggleLogo() flip
    // updates both surfaces in lockstep. Going-live remains the TopBar
    // "Go Live" button + schedule double-click; the keyboard shortcut
    // is reserved for the lighter operator action of showing/hiding
    // the splash/wallpaper.
    Shortcut { sequence: "Ctrl+L"; onActivated: AppState.toggleLogo() }
    // Ctrl+C = clear the projection (hide text, keep theme background +
    // logo). Same simple one-liner form as Ctrl+L — earlier attempts with
    // a text-input guard and Qt.ApplicationShortcut context appeared to
    // suppress the shortcut entirely. Tradeoff: Ctrl+C fires Clear even
    // when a text input is focused with selected text, so in-dialog copy
    // is shadowed by Clear. Ctrl+. remains as the redundant clear
    // binding; right-click → copy still works in text fields.
    Shortcut { sequence: "Ctrl+C"; onActivated: AppState.clearLive() }
    // Ctrl+. is the legacy "clear" shortcut from the Electron version —
    // kept as a backup binding that always fires (no text-input guard) so
    // operators inside a text field can still clear via this combo.
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

    // Up / Down always navigate the active library tab — selecting a
    // schedule item no longer captures the arrow keys. The TabSearchBar's
    // own Keys.onUpPressed handles the same call path when the search
    // input has focus (and blocks this Shortcut via Keys.onShortcutOverride
    // to avoid double-fire). This window-level Shortcut covers the case
    // where focus is outside the search field (e.g. operator clicked a
    // schedule row or a verse row).
    Shortcut {
        sequence: "Up"
        enabled: AppState.activeModal === ""
        onActivated: AppState.libraryNavigateUp()
    }
    Shortcut {
        sequence: "Down"
        enabled: AppState.activeModal === ""
        onActivated: AppState.libraryNavigateDown()
    }
}
