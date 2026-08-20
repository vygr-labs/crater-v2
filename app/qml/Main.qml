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

    // ── Frameless chrome ────────────────────────────────────────────────
    // Drop the native title bar; we draw our own via panels/TitleBar.qml.
    // Window dragging / Aero Snap / edge resize are handled with Qt 6.5+
    // primitives (Window.startSystemMove / Window.startSystemResize) that
    // delegate to the OS — no manual WM behavior reimplementation needed.
    flags: Qt.Window | Qt.FramelessWindowHint

    // Frameless maximized windows on Windows extend ~8 px past the screen
    // bounds (Win expects an invisible resize border the WM normally
    // draws). Apply an equal margin to the content wrapper when maximized
    // so the operator sees crisp pixels at the screen edges instead of
    // chrome that runs off-screen. macOS / Linux don't exhibit the
    // overshoot, so the margin collapses to 0 elsewhere.
    readonly property int _maxFix:
        (Qt.platform.os === "windows" && visibility === Window.Maximized) ? 8 : 0

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
        // Live re-pointing of the NDI grabber when the operator flips
        // dual-output mode while broadcasting. No NDI restart required —
        // the next capture tick (~33 ms) picks up the new source.
        function onOutputModeChanged() {
            root._updateNdiSource()
        }
    }

    // ── SongService → AppState glue ─────────────────────────────────────
    // Same reason as the block above: AppState can't host its own
    // Connections. SongService invalidates its cache and emits this after
    // every create / update / destroy / favorite / import, so the staged
    // preview item re-reads the song it points at and stops serving
    // pre-edit lyrics to the next Go Live. No-op unless a song is staged.
    Connections {
        target: SongService
        function onAllSongsChanged() {
            AppState.refreshStagedSong()
        }
    }

    // One-shot init of showLogo from the operator's persisted default.
    // After this fires, manual Logo button / Ctrl+L toggles take over —
    // the dialog setting governs the next launch, not live override.
    //
    // NDI source registration also happens here — NdiService needs the
    // QQuickWindow + QQuickItem pointers but can't reach them from C++
    // at static-construction time (the QML objects are created later).
    // Re-points to the right pair based on output mode; subsequent
    // mode flips ride the onOutputModeChanged handler above.
    Component.onCompleted: {
        AppState.showLogo = SettingsService.showLogoByDefault
        ProjectionService.setLogoVisible(AppState.showLogo)
        root._updateNdiSource()
        // BrowserCast (removable feature) — capture the same canvas-native
        // projection Item the NDI sender uses, so the TV browser mirrors the
        // primary audience output.
        BrowserCastService.setSourceItem(projectionWindow.renderItem)

        // Bring the operator console to the foreground on launch. Windows
        // suppresses focus-stealing for processes that didn't start with
        // foreground rights, so `visible: true` alone can leave us painted
        // but parked behind the user's current app. Defer one event-loop
        // tick so the WM has finished realizing the surface — raising
        // before the window is mapped is a no-op on some compositors.
        Qt.callLater(function() {
            root.raise()
            root.requestActivate()
        })
    }

    // ── Shutdown ────────────────────────────────────────────────────────
    // Closing the operator console quits Crater — there is no headless
    // mode, the console IS the app. But the projection window is a second
    // OS-level QQuickWindow, and Qt's quitOnLastWindowClosed only fires
    // when the last *visible* window closes. If projection is live on the
    // audience screen (or parked offscreen for an NDI broadcast — see
    // ProjectionWindow.qml's keepRendering state) when the console closes,
    // that window stays visible, the process keeps running, and the
    // operator is left with a projection no console can drive.
    //
    // endLive() lowers the projector the clean way — it flips
    // AppState.projectorVisible, which drives ProjectionWindow to
    // Window.Hidden and fires OutputService.notifyProjectionClosed().
    // Qt.quit() then tears down every remaining window unconditionally;
    // this is what covers the keepRendering case, where endLive() alone
    // would leave the projection window alive offscreen (visibility
    // Window.Windowed) and still blocking the quit. Qt.quit() bypasses
    // ProjectionWindow's own onClosing close-rejection because it destroys
    // windows directly rather than routing an OS close event through them.
    onClosing: function() {
        AppState.endLive()
        Qt.quit()
    }

    // ── NDI source plumbing ────────────────────────────────────────────
    // Selects which window+item pair NDI grabs frames from based on the
    // current output mode:
    //
    //   single mode → projectionWindow + its renderItem. NDI mirrors
    //     whatever the audience is seeing; the projection window has to
    //     stay alive offscreen during solo broadcast so the scene graph
    //     keeps producing frames (see ProjectionWindow.qml's keepRendering
    //     binding, wired to NdiService.sending below).
    //
    //   dual mode → operator-console window + ndiCanvas's renderItem.
    //     ndiCanvas is a hidden Item inside this ApplicationWindow rather
    //     than a separate Window — see NdiCanvas.qml for *why*. The
    //     window-level pointer is `root` itself (always exposed, scene
    //     graph always live); the item pointer is the offscreen NDI
    //     scene's stage.
    //
    // captureFrame in NdiService.cpp grabs from sourceItem when set,
    // falling back to sourceWindow->contentItem(). We always set both
    // so the fallback never matters.
    function _updateNdiSource() {
        if (SettingsService.outputMode === "dual") {
            NdiService.setSourceWindow(root)
            // ndiCanvasLoader.item is null until outputMode flips to dual and the
            // Loader builds the canvas; guard so a stray call in that window sets
            // a null source rather than dereferencing null. onLoaded re-runs this.
            NdiService.setSourceItem(ndiCanvasLoader.item ? ndiCanvasLoader.item.renderItem : null)
        } else {
            NdiService.setSourceWindow(projectionWindow)
            NdiService.setSourceItem(projectionWindow.renderItem)
        }
    }

    // ── Custom title bar ────────────────────────────────────────────────
    // Replaces the OS-drawn title bar that Qt.FramelessWindowHint removed.
    // Always visible — even during workspace mode (theme editor) the
    // operator still needs window controls. The maxFix margins on the
    // top/left/right keep it inside the visible screen pixels when
    // maximized on Windows. z: 9999 keeps it above the workspaces Loader;
    // ModalLayer below uses an even higher z so modals dim the titlebar
    // when active and the operator dismisses modals via Esc / modal close.
    TitleBar {
        id: titleBar
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin:   root._maxFix
        anchors.leftMargin:  root._maxFix
        anchors.rightMargin: root._maxFix
        z: 9999
    }

    // ── Top bar ─────────────────────────────────────────────────────────
    TopBar {
        id: topBar
        anchors.top: titleBar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin:  root._maxFix
        anchors.rightMargin: root._maxFix
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
        anchors.leftMargin:   root._maxFix
        anchors.rightMargin:  root._maxFix
        anchors.bottomMargin: root._maxFix

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
        // Workspaces start below the title bar so the operator never loses
        // window controls while the theme editor is open. Margins on the
        // remaining sides absorb the Windows max-overshoot fix.
        anchors.top: titleBar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin:   root._maxFix
        anchors.rightMargin:  root._maxFix
        anchors.bottomMargin: root._maxFix
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

    // ── Modal overlay (renders above the entire frame including the
    //    custom TitleBar once a modal is active — operator dismisses
    //    via Esc / the modal's own close button) ──────────────────────
    ModalLayer {
        anchors.fill: parent
        anchors.margins: root._maxFix
        z: 10000
    }

    // ── Edge resize zones ───────────────────────────────────────────────
    // 6 px-wide strips at each edge plus 8 px-square corner zones, hung
    // directly off the ApplicationWindow root so they ride the actual
    // visible window edges (not the inner content-margin edges). Each
    // calls Window.startSystemResize() with the appropriate edge set —
    // the OS then runs its native resize loop, so Aero Snap / dock-to-
    // edge / cursor-warp on multi-monitor all work without extra QML
    // state machines. Disabled when maximized; resizing a maximized
    // window via startSystemResize kicks it into a half-restored
    // intermediate state on Windows that's visually jarring.
    Item {
        id: resizeZones
        anchors.fill: parent
        z: 10001
        enabled: !titleBar._isMaximized

        readonly property int edge:   6
        readonly property int corner: 10

        // Left edge
        MouseArea {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.topMargin:    resizeZones.corner
            anchors.bottomMargin: resizeZones.corner
            width: resizeZones.edge
            cursorShape: Qt.SizeHorCursor
            onPressed: function (m) {
                if (m.button === Qt.LeftButton) root.startSystemResize(Qt.LeftEdge)
            }
        }
        // Right edge
        MouseArea {
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.topMargin:    resizeZones.corner
            anchors.bottomMargin: resizeZones.corner
            width: resizeZones.edge
            cursorShape: Qt.SizeHorCursor
            onPressed: function (m) {
                if (m.button === Qt.LeftButton) root.startSystemResize(Qt.RightEdge)
            }
        }
        // Top edge (overlays the top of the TitleBar drag region — this
        // matches OS-native behavior where the very top edge is a resize
        // zone, not a drag zone, and only kicks in for the 6 px strip).
        MouseArea {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin:  resizeZones.corner
            anchors.rightMargin: resizeZones.corner
            height: resizeZones.edge
            cursorShape: Qt.SizeVerCursor
            onPressed: function (m) {
                if (m.button === Qt.LeftButton) root.startSystemResize(Qt.TopEdge)
            }
        }
        // Bottom edge
        MouseArea {
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin:  resizeZones.corner
            anchors.rightMargin: resizeZones.corner
            height: resizeZones.edge
            cursorShape: Qt.SizeVerCursor
            onPressed: function (m) {
                if (m.button === Qt.LeftButton) root.startSystemResize(Qt.BottomEdge)
            }
        }
        // Top-left corner (↖↘ diagonal)
        MouseArea {
            anchors.top: parent.top
            anchors.left: parent.left
            width: resizeZones.corner
            height: resizeZones.corner
            cursorShape: Qt.SizeFDiagCursor
            onPressed: function (m) {
                if (m.button === Qt.LeftButton) root.startSystemResize(Qt.TopEdge | Qt.LeftEdge)
            }
        }
        // Top-right corner (↗↙ diagonal)
        MouseArea {
            anchors.top: parent.top
            anchors.right: parent.right
            width: resizeZones.corner
            height: resizeZones.corner
            cursorShape: Qt.SizeBDiagCursor
            onPressed: function (m) {
                if (m.button === Qt.LeftButton) root.startSystemResize(Qt.TopEdge | Qt.RightEdge)
            }
        }
        // Bottom-left corner (↗↙ diagonal)
        MouseArea {
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            width: resizeZones.corner
            height: resizeZones.corner
            cursorShape: Qt.SizeBDiagCursor
            onPressed: function (m) {
                if (m.button === Qt.LeftButton) root.startSystemResize(Qt.BottomEdge | Qt.LeftEdge)
            }
        }
        // Bottom-right corner (↖↘ diagonal)
        MouseArea {
            anchors.bottom: parent.bottom
            anchors.right: parent.right
            width: resizeZones.corner
            height: resizeZones.corner
            cursorShape: Qt.SizeFDiagCursor
            onPressed: function (m) {
                if (m.button === Qt.LeftButton) root.startSystemResize(Qt.BottomEdge | Qt.RightEdge)
            }
        }
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
        // Two orthogonal flags drive the projection window's state:
        //
        //   visibleToOperator — "is the audience seeing this right now?"
        //     Set true by AppState.openProjector() (the TopBar Go Live button,
        //     which only opens the window) and by the schedule context-menu's
        //     "Send to Live" (goLive(true) — commit that row AND raise); set
        //     false by AppState.endLive() (the windowed projector's close
        //     button or Esc shortcut). clearLive() blanks content but doesn't
        //     lower the projector. Content-commit gestures (Enter, preview /
        //     schedule double-click, library push) use goLive(false) /
        //     pushLibraryLive and do NOT raise the window.
        //
        //   keepRendering — "does anything need frames in the background?"
        //     In single output mode this is `NdiService.sending` — NDI
        //     pulls from this window's scene graph, so it has to stay
        //     alive offscreen for broadcast to continue after the
        //     operator closes the audience view. In dual output mode
        //     this collapses to false: NdiCanvas owns the always-alive
        //     role and the projection window can fully Window.Hidden
        //     whenever the operator wants. Future hooks (recording,
        //     stage monitor) would OR-in here the same way.
        visibleToOperator: AppState.projectorVisible
        // BrowserCast (removable feature) adds the `|| BrowserCastService.active`
        // term: while a TV browser is pulling the MJPEG stream the scene graph
        // must keep rendering offscreen so grabToImage() has fresh frames —
        // the same reason NDI keeps it alive.
        keepRendering:     (NdiService.sending
                         && SettingsService.outputMode === "single")
                        || BrowserCastService.active
    }

    // Single-screen go-live: keep the console in front. ProjectionWindow drops
    // its always-on-top hint when there's only one display (see _singleScreen
    // there), so the fullscreen audience output renders BEHIND this console
    // instead of burying it. But the OS still briefly foregrounds a freshly-
    // shown window, so we shove the console back on top one event-loop tick
    // later — same Qt.callLater(raise + requestActivate) pattern the launch
    // code uses, and for the same reason (Windows suppresses focus-stealing).
    // The operator then surfaces the projection deliberately via its taskbar /
    // Alt-Tab entry. No-op on multi-monitor (nothing to bury) and in windowed
    // mode (the small preview never covers the console).
    Connections {
        target: projectionWindow
        function onVisibleToOperatorChanged() {
            if (!projectionWindow.visibleToOperator) return
            if (OutputService.screens.length > 1) return
            if (OutputService.projectionMode !== OutputService.Fullscreen) return
            Qt.callLater(function() {
                root.raise()
                root.requestActivate()
            })
        }
    }

    // The same guard for the cable coming OUT. onVisibleToOperatorChanged
    // only fires at go-live, so unplugging the audience display mid-service
    // never ran it: the fullscreen projector followed the operator onto the
    // remaining panel and sat on top of the console with nothing to push it
    // back. ProjectionWindow now demotes itself to the corner preview when
    // the screen count collapses (see _windowedForced there); this puts the
    // console back in front so the operator keeps a surface they can drive.
    //
    // Fires on screenAdded / screenRemoved / primaryScreenChanged via
    // OutputService.rebuildScreens. Re-plugging is not a special case — the
    // count goes back above one, this returns early, and ProjectionWindow's
    // bindings restore fullscreen on their own.
    Connections {
        target: OutputService
        function onScreensChanged() {
            if (OutputService.screens.length > 1) return
            if (!projectionWindow.visibleToOperator) return
            Qt.callLater(function() {
                root.raise()
                root.requestActivate()
            })
        }
    }

    // ── Dedicated NDI render canvas (dual output mode only) ─────────────
    // Hidden Item parked far offscreen within this ApplicationWindow. It
    // hosts a ProjectionScene with outputKind="ndi" so dual mode can grab
    // an independently-themed frame. Lives inside the operator console
    // (not as a separate Window) so its scene graph is always backed by
    // this window's render context — see NdiCanvas.qml for *why* that
    // matters. `visible: _shouldRender` inside NdiCanvas suspends scene-
    // graph cost when not broadcasting.
    // Deferred behind a Loader keyed on output mode. NdiCanvas is used ONLY in
    // dual output mode: its renderItem is read by _updateNdiSource solely in the
    // dual branch, and its scene renders only when _shouldRender (which also
    // requires dual). In the common single-output launch it was a full
    // ProjectionScene instantiated at startup and never used — gating it here
    // skips that QML object creation entirely. outputMode is a persisted setting
    // that rarely flips, so there's no create/destroy churn in practice. When it
    // does flip to dual, onLoaded re-runs the NDI source wiring against the fresh
    // canvas — covering the race where onOutputModeChanged fires _updateNdiSource
    // before the Loader has built its item.
    Loader {
        id: ndiCanvasLoader
        active: SettingsService.outputMode === "dual"
        sourceComponent: ndiCanvasComponent
        onLoaded: root._updateNdiSource()

        // Explicit Component (matches the workspaceLoader pattern above) rather
        // than an inline NdiCanvas {} — sourceComponent wants a Component.
        Component {
            id: ndiCanvasComponent
            NdiCanvas { }
        }
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
    // Ctrl+K = the global search command palette (search across every library
    // at once). Toggles: closed → open, open → close. Gated so it never stacks
    // on another modal or the full-screen theme-editor workspace; the palette
    // itself lives in ModalLayer under activeModal === "globalSearch".
    Shortcut {
        sequence: "Ctrl+K"
        enabled: AppState.workspaceMode === ""
              && (AppState.activeModal === "" || AppState.activeModal === "globalSearch")
        onActivated: {
            if (AppState.activeModal === "globalSearch") AppState.closeGlobalSearch()
            else                                         AppState.openGlobalSearch()
        }
    }
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

    // Up / Down dispatch by AppState.activeFocusPanel so the same physical
    // key can mean "move within the staged page list", "move within the
    // live page list", or "move within the library list" depending on
    // which surface last received an interaction. Clicking a card in
    // PreviewPanel / LivePanel claims focus for that panel; typing in the
    // sidebar search input (TabSearchBar) claims it back for the library.
    // The TabSearchBar's own Keys.onUpPressed handles the same call path
    // when the search input has focus (and blocks this Shortcut via
    // Keys.onShortcutOverride to avoid double-fire).
    Shortcut {
        sequence: "Up"
        enabled: AppState.activeModal === ""
        onActivated: {
            switch (AppState.activeFocusPanel) {
                case "preview": AppState.previewNavigateUp(); break
                case "live":    AppState.liveNavigateUp();    break
                default:        AppState.libraryNavigateUp()
            }
        }
    }
    Shortcut {
        sequence: "Down"
        enabled: AppState.activeModal === ""
        onActivated: {
            switch (AppState.activeFocusPanel) {
                case "preview": AppState.previewNavigateDown(); break
                case "live":    AppState.liveNavigateDown();    break
                default:        AppState.libraryNavigateDown()
            }
        }
    }

    // Enter / Return — "activate the focused thing". TabSearchBar already
    // owns this when the search input has OS focus and we're routing to
    // the library: its Keys.onReturnPressed + onShortcutOverride pair
    // accept the key, suppressing this Shortcut on that path. For every
    // other case — preview-card focus, library focus without the search
    // input owning it — the window-level dispatch routes here. "live"
    // intentionally has no activate semantics (the page is already on
    // the projector, so there's nothing to "activate"); "schedule"
    // similarly has no defined Enter action yet, so Enter is a no-op
    // there.
    Shortcut {
        sequences: ["Return", "Enter"]
        enabled: AppState.activeModal === ""
        onActivated: {
            switch (AppState.activeFocusPanel) {
                case "preview": AppState.previewActivate(); break
                case "library": AppState.libraryActivate(); break
            }
        }
    }
}
