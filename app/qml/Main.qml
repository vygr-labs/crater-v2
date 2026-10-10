import QtQml
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
    // Open maximized on first show. On Windows, main.cpp then hands the
    // window its real restore size and reopens it the way it was left
    // (WindowChrome.h, restoreWindowPlacement). `width`/`height` above are
    // only the restore size on the other platforms.
    visibility: Window.Maximized
    title: qsTr("Crater")
    color: Theme.color.canvas

    // ── Frameless chrome ────────────────────────────────────────────────
    // Drop the native title bar; we draw our own via panels/TitleBar.qml.
    // Window dragging / Aero Snap / edge resize are handled with Qt 6.5+
    // primitives (Window.startSystemMove / Window.startSystemResize) that
    // delegate to the OS — no manual WM behavior reimplementation needed.
    flags: Qt.Window | Qt.FramelessWindowHint

    // Maximized on Windows, the console hangs past every screen edge by the
    // resize border Windows expects to draw (WindowChrome.cpp keeps the
    // caption style so maximize and restore animate). Inset the content by
    // exactly that much so nothing runs off screen. It depends on the
    // screen's scaling, hence `screen` in the binding. 0 elsewhere.
    readonly property real _maxFix:
        (visibility === Window.Maximized && screen) ? WindowControls.maximizedInset(root) : 0

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

        // Passages in the schedule and on screen take the new layout at once
        // (one page per verse, or one page). See AppState.relayoutScripture.
        function onHighlightCurrentVerseChanged() {
            AppState.relayoutScripture()
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

    // ── Live display settings → projector ──────────────────────────────
    // ProjectionService holds a go-live snapshot, so a theme set on the live
    // schedule row, or a change to how passages are laid out, would wait for
    // the next Go Live. This hands the theme case to AppState, which
    // re-sends the live item with just that change (the layout case rides
    // the SettingsService block above).
    Connections {
        target: ScheduleService
        function onCurrentItemsChanged() {
            AppState.syncLiveTheme()
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

        // Ask-at-startup profile picker (ARCHITECTURE.md §12). The console
        // has already opened the last-used profile; the picker either keeps
        // it or restarts into another. Never shown on a launch that came
        // from a switch, which already says which profile it wants.
        if (ProfileService.shouldPromptAtStartup)
            Qt.callLater(function() { AppState.openModal("profilePicker", {}) })
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

        // Holds keyboard focus whenever nothing below has claimed it, so
        // there is always a focused item for key events to propagate up
        // from. Load-bearing for Keys.onReleased below: a click on a Live
        // card sets AppState.activeFocusPanel but claims no OS focus, so
        // without this the Ctrl release after a scrub could land on the
        // window's contentItem and never reach us. Panels that do want real
        // focus (search inputs, editors) still take it on click as before —
        // their releases then propagate back up through here.
        focus: true

        // Commits a live scrub (see AppState.liveScrubIndex). Ctrl+Arrow
        // moves the highlight; letting go of Ctrl is the "send it" gesture.
        // This has to be a key handler rather than a Shortcut because
        // Shortcut only fires on press — there is no release side to bind.
        // Sitting on mainArea rather than on the Live pane is deliberate:
        // key releases travel up the focus chain, so the ancestor of every
        // panel sees the release no matter which one holds focus.
        Keys.onReleased: function(event) {
            if (event.key === Qt.Key_Control)
                AppState.liveScrubCommit()
        }

        visible: root._consoleVisible
        anchors.top: topBar.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin:   root._maxFix
        anchors.rightMargin:  root._maxFix
        anchors.bottomMargin: root._maxFix

        // ── Panel layout ─────────────────────────────────────────────────
        // Operators can drag the lines between panels, hide the schedule,
        // the preview or the library sidebar, put Live to the left of
        // Preview and move the schedule to the right edge. What they changed
        // lives in SettingsService.consoleLayout. A key that is absent there
        // takes the stock value below, so an empty map is the stock layout
        // and Settings > Appearance > Reset layout just clears it.
        //
        // While a line is being dragged its value sits in _drag and only
        // goes to SettingsService on release, so a drag writes once.
        property var _drag: ({})
        function _val(key, fallback) {
            if (_drag[key] !== undefined) return _drag[key]
            const v = SettingsService.consoleLayout[key]
            return v === undefined ? fallback : v
        }
        function _setDrag(values) {
            _drag = Object.assign({}, _drag, values)
        }
        // A key set to undefined drops the dragged value and keeps what was
        // stored, which is how collapsing a panel leaves its width alone.
        function _commitDrag() {
            for (const k in _drag) {
                const v = _drag[k]
                if (v === undefined) continue
                // Hidden flags are stored only when set, sizes rounded.
                SettingsService.setConsoleLayoutValue(k,
                    v === false ? null : (typeof v === "number" ? Math.round(v * 1000) / 1000 : v))
            }
            _drag = ({})
        }
        function _clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

        // Smallest useful size of each panel. Together they still fit the
        // window's 1080 x 680 minimum with every panel shown.
        readonly property int _rail:       16
        readonly property int _minSchedule: 220
        readonly property int _minPreview:  240
        readonly property int _minLive:     280
        readonly property int _minSidebar:  160
        readonly property int _minContent:  420
        readonly property int _minTop:      220
        readonly property int _minBottom:   200

        readonly property bool scheduleShown: !_val("scheduleHidden", false)
        readonly property bool previewShown:  !_val("previewHidden", false)
        readonly property bool sidebarShown:  !_val("sidebarHidden", false)
        readonly property bool scheduleRight: _val("scheduleRight", false)
        readonly property bool liveFirst:     _val("liveFirst", false)

        // The two LIST panels have a real useful maximum by default: past
        // ~420px a schedule row is mostly empty space to the right of its
        // title, and past ~320px the sidebar is a column of short labels in
        // a wide gutter. Those pixels are worth more to Preview and Live.
        // A width the operator dragged to is kept as is.
        readonly property real scheduleWidth: scheduleShown
            ? _clamp(_val("scheduleWidth", Math.min(width * 0.30, 420)), _minSchedule,
                     width - _minLive - (previewShown ? _minPreview : _rail))
            : _rail
        readonly property real sidebarWidth: sidebarShown
            ? _clamp(_val("sidebarWidth", Math.min(width * 0.24, 320)), _minSidebar, width - _minContent)
            : _rail

        // Live's share of what the schedule leaves. The stock 0.36 / 0.70
        // keeps the two monitors in their original proportion.
        readonly property real monitorsWidth: width - scheduleWidth
        readonly property real liveWidth: previewShown
            ? _clamp(monitorsWidth * _val("liveShare", 0.36 / 0.70), _minLive, monitorsWidth - _minPreview)
            : monitorsWidth - _rail
        readonly property real previewWidth: monitorsWidth - liveWidth

        readonly property real scheduleX: scheduleRight ? width - scheduleWidth : 0
        readonly property real monitorsX: scheduleRight ? 0 : scheduleWidth
        readonly property real previewX:  liveFirst ? monitorsX + liveWidth : monitorsX
        readonly property real liveX:     liveFirst ? monitorsX : monitorsX + previewWidth

        readonly property real topRowHeight:
            _clamp(height * _val("topRowRatio", 0.58), _minTop, height - _minBottom)

        // Size of the panel being dragged, taken when the drag began.
        property real _dragStart: 0

        // ── Top row: Schedule | Preview | Live ───────────────────────────
        Item {
            id: topRow

            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: mainArea.topRowHeight

            SchedulePanel {
                id: schedulePane
                visible: mainArea.scheduleShown
                x: mainArea.scheduleX
                width: mainArea.scheduleWidth
                height: parent.height
            }

            PreviewPanel {
                id: previewPane
                visible: mainArea.previewShown
                x: mainArea.previewX
                width: mainArea.previewWidth
                height: parent.height
            }

            LivePanel {
                id: livePane
                x: mainArea.liveX
                width: mainArea.liveWidth
                height: parent.height
            }

            CollapsedRail {
                visible: !mainArea.scheduleShown
                x: mainArea.scheduleX
                width: mainArea._rail
                height: parent.height
                label: qsTr("Show schedule")
                chevron: mainArea.scheduleRight ? "chevron-left" : "chevron-right"
                onClicked: SettingsService.setConsoleLayoutValue("scheduleHidden", null)
            }

            CollapsedRail {
                visible: !mainArea.previewShown
                x: mainArea.previewX
                width: mainArea._rail
                height: parent.height
                label: qsTr("Show preview")
                chevron: mainArea.liveFirst ? "chevron-left" : "chevron-right"
                onClicked: SettingsService.setConsoleLayoutValue("previewHidden", null)
            }

            // Hairlines where two panels meet. Each panel draws its own
            // right edge, which is enough in the stock order but not once
            // the panels are rearranged.
            Repeater {
                model: [mainArea.scheduleRight ? mainArea.scheduleX : mainArea.scheduleWidth,
                        mainArea.monitorsX + (mainArea.liveFirst ? mainArea.liveWidth : mainArea.previewWidth)]
                delegate: Rectangle {
                    required property real modelData
                    x: modelData - 1
                    width: 1
                    height: topRow.height
                    z: 40
                    color: Theme.color.borderSubtle
                }
            }

            // Schedule edge. Dragging it under half the schedule's minimum
            // hides the schedule. The rail brings it back.
            PanelSplitter {
                visible: mainArea.scheduleShown || dragging
                frame: mainArea
                x: (mainArea.scheduleRight ? mainArea.scheduleX : mainArea.scheduleWidth) - leftOverlap
                height: parent.height
                onPressed: mainArea._dragStart = mainArea.scheduleWidth
                onMoved: function(delta) {
                    const w = mainArea._dragStart + (mainArea.scheduleRight ? -delta : delta)
                    if (w < mainArea._minSchedule / 2) mainArea._setDrag({ scheduleHidden: true, scheduleWidth: undefined })
                    else mainArea._setDrag({ scheduleHidden: false, scheduleWidth: w })
                }
                onReleased: mainArea._commitDrag()
                onReset: SettingsService.setConsoleLayoutValue("scheduleWidth", null)
            }

            // Edge between Preview and Live. Dragging Preview under half its
            // minimum hides it.
            PanelSplitter {
                visible: mainArea.previewShown || dragging
                frame: mainArea
                x: mainArea.monitorsX
                   + (mainArea.liveFirst ? mainArea.liveWidth : mainArea.previewWidth) - leftOverlap
                height: parent.height
                onPressed: mainArea._dragStart = mainArea.liveWidth
                onMoved: function(delta) {
                    const live = mainArea._dragStart + (mainArea.liveFirst ? delta : -delta)
                    if (mainArea.monitorsWidth - live < mainArea._minPreview / 2)
                        mainArea._setDrag({ previewHidden: true, liveShare: undefined })
                    else
                        mainArea._setDrag({ previewHidden: false, liveShare: live / mainArea.monitorsWidth })
                }
                onReleased: mainArea._commitDrag()
                onReset: SettingsService.setConsoleLayoutValue("liveShare", null)
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

        // Edge between the top row and the library.
        PanelSplitter {
            vertical: false
            frame: mainArea
            anchors.left: parent.left
            anchors.right: parent.right
            y: topRow.height - leftOverlap
            onPressed: mainArea._dragStart = topRow.height
            onMoved: function(delta) {
                mainArea._setDrag({ topRowRatio: (mainArea._dragStart + delta) / mainArea.height })
            }
            onReleased: mainArea._commitDrag()
            onReset: SettingsService.setConsoleLayoutValue("topRowRatio", null)
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
                visible: mainArea.sidebarShown
                anchors.top: tabBar.bottom
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                width: mainArea.sidebarWidth
            }

            CollapsedRail {
                visible: !mainArea.sidebarShown
                anchors.top: tabBar.bottom
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                width: mainArea._rail
                label: qsTr("Show library sidebar")
                onClicked: SettingsService.setConsoleLayoutValue("sidebarHidden", null)
            }

            LibraryContent {
                id: libraryContent
                anchors.top: tabBar.bottom
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.leftMargin: mainArea.sidebarWidth
                anchors.right: parent.right
            }

            PanelSplitter {
                visible: mainArea.sidebarShown || dragging
                frame: mainArea
                anchors.top: tabBar.bottom
                anchors.bottom: parent.bottom
                x: mainArea.sidebarWidth - leftOverlap
                onPressed: mainArea._dragStart = mainArea.sidebarWidth
                onMoved: function(delta) {
                    const w = mainArea._dragStart + delta
                    if (w < mainArea._minSidebar / 2) mainArea._setDrag({ sidebarHidden: true, sidebarWidth: undefined })
                    else mainArea._setDrag({ sidebarHidden: false, sidebarWidth: w })
                }
                onReleased: mainArea._commitDrag()
                onReset: SettingsService.setConsoleLayoutValue("sidebarWidth", null)
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
        // Lets the projection tell when it is aimed at the console's own
        // display, and stack itself under this window in behind mode.
        consoleWindow: root
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

    // ── Extra output windows (multi-display) ─────────────────────────────
    // One window per registered output that is not the audience projector
    // and not NDI. "primary" is the ProjectionWindow above; NDI renders to a
    // network stream through NdiCanvas and has no display of its own. Every
    // other entry — the built-in Stage Monitor, plus anything the operator
    // adds in Settings > Projection — gets an OutputWindow that decides for
    // itself whether it is currently showable.
    //
    // Instantiator, not Repeater: Repeater reparents its delegates and so
    // requires them to be Items, and a Window is not an Item. Instantiator
    // creates plain QObjects, which is exactly what a top-level Window is.
    //
    // The model is a list of ID STRINGS held in a property that is only
    // reassigned when the set of ids genuinely changes — deliberately not a
    // binding on OutputService.outputs. outputsChanged() is a coarse signal
    // that also fires for a theme pin, a transition tweak, or an enable
    // toggle; binding straight to it would hand Instantiator a new array
    // every time and tear down and rebuild every output window, so flipping
    // a stage monitor off and on would destroy a live fullscreen window
    // mid-service. Enable / screen / mode changes instead flow through
    // OutputWindow's own bindings, which re-evaluate without recreating it.
    property var _outputWindowIds: []

    function _refreshOutputWindowIds() {
        const list = OutputService.outputs
        const ids = []
        for (let i = 0; i < list.length; i++) {
            const b = list[i]
            if (b.id === "primary" || b.role === "ndi") continue
            ids.push(b.id)
        }
        if (ids.join("|") === root._outputWindowIds.join("|")) return
        root._outputWindowIds = ids
    }

    Connections {
        target: OutputService
        function onOutputsChanged() { root._refreshOutputWindowIds() }
    }

    Instantiator {
        model: root._outputWindowIds
        delegate: OutputWindow { outputId: modelData }
        // Seed the list once at startup. Scoped here rather than added to
        // the window's own Component.onCompleted so this whole feature is
        // one contiguous block that can be read (or removed) on its own.
        Component.onCompleted: root._refreshOutputWindowIds()
    }

    // Shared-screen go-live: keep the console in front. ProjectionWindow drops
    // its always-on-top hint when it shares the console's display (see
    // sharesConsoleScreen there), and in behind mode ProjectionLayering shows
    // it without activating and stacks it under this console. This is the
    // fallback in case the OS foregrounds the freshly shown window anyway: it
    // shoves the console back on top one event-loop tick later — same
    // Qt.callLater(raise + requestActivate) pattern the launch code uses, and
    // for the same reason (Windows suppresses focus-stealing). The operator
    // then surfaces the projection deliberately by clicking it or via its
    // taskbar / Alt-Tab entry. No-op when the output has a display of its own
    // (nothing to bury) and in windowed mode (the small preview never covers
    // the console).
    Connections {
        target: projectionWindow
        function onVisibleToOperatorChanged() {
            if (!projectionWindow.visibleToOperator) return
            if (!projectionWindow.sharesConsoleScreen) return
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
    Shortcut { sequence: "Ctrl+1"; enabled: AppState.consoleShortcutsActive; onActivated: AppState.setActiveTab(0) }
    Shortcut { sequence: "Ctrl+2"; enabled: AppState.consoleShortcutsActive; onActivated: AppState.setActiveTab(1) }
    Shortcut { sequence: "Ctrl+3"; enabled: AppState.consoleShortcutsActive; onActivated: AppState.setActiveTab(2) }
    Shortcut { sequence: "Ctrl+4"; enabled: AppState.consoleShortcutsActive; onActivated: AppState.setActiveTab(3) }
    Shortcut { sequence: "Ctrl+5"; enabled: AppState.consoleShortcutsActive; onActivated: AppState.setActiveTab(4) }
    // Disabled while a modal is open so dialogs (e.g. SongEditor) can
    // claim Ctrl+Tab for their own view-mode toggles without two
    // handlers fighting over the same sequence.
    Shortcut { sequence: "Ctrl+Tab";       enabled: AppState.consoleShortcutsActive; onActivated: AppState.cycleTab( 1) }
    Shortcut { sequence: "Ctrl+Shift+Tab"; enabled: AppState.consoleShortcutsActive; onActivated: AppState.cycleTab(-1) }

    // Production actions
    Shortcut { sequence: "Ctrl+,"; enabled: AppState.consoleShortcutsActive; onActivated: AppState.openModal("settings", {}) }
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
    Shortcut { sequence: "Ctrl+L"; enabled: AppState.consoleShortcutsActive; onActivated: AppState.toggleLogo() }
    // Ctrl+C = clear the projection (hide text, keep theme background +
    // logo). Same simple one-liner form as Ctrl+L — earlier attempts with
    // a text-input guard and Qt.ApplicationShortcut context appeared to
    // suppress the shortcut entirely. Tradeoff: Ctrl+C fires Clear even
    // when a text input is focused with selected text, so in-dialog copy
    // is shadowed by Clear. Ctrl+. remains as the redundant clear
    // binding; right-click → copy still works in text fields.
    Shortcut { sequence: "Ctrl+C"; enabled: AppState.consoleShortcutsActive; onActivated: AppState.clearLive() }
    // Ctrl+. is the legacy "clear" shortcut from the Electron version —
    // kept as a backup binding that always fires (no text-input guard) so
    // operators inside a text field can still clear via this combo.
    Shortcut { sequence: "Ctrl+."; enabled: AppState.consoleShortcutsActive; onActivated: AppState.clearLive() }
    // Ctrl+T = stage the currently focused library item. The active tab
    // (ScriptureTab / SongsTab / MediaTab) handles via its
    // onLibraryAddToSchedule listener; tabs without schedule items do nothing.
    Shortcut { sequence: "Ctrl+T"; enabled: AppState.consoleShortcutsActive; onActivated: AppState.libraryAddToSchedule() }

    // Save the working schedule. Updates the currently loaded saved row if
    // there is one; otherwise prompts the operator for a name (Save As).
    Shortcut {
        sequence: "Ctrl+S"
        // Off while a dialog or the theme editor is up — both bind
        // Ctrl+S to their own save, and an ungated one here made all
        // three ambiguous, so none of them fired.
        enabled: AppState.consoleShortcutsActive
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
        enabled: AppState.consoleShortcutsActive
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
    //
    // Deliberately NOT gated on consoleShortcutsActive. This is the ONE
    // Escape binding for every modal: ModalShell has no Escape handling of
    // its own, and dialogs must not add one (two enabled Escape Shortcuts
    // are ambiguous and neither fires). AppState.modalEscape routes a
    // single press through requestCloseModal, so an editor holding unsaved
    // edits still asks first, and turns a fast second press into the
    // double-tap discard.
    //
    // The theme editor workspace binds its own Escape, so it owns the key
    // while no modal is up and this one owns it while a modal is open
    // over the workspace. autoRepeat off: a held Escape is one press, never
    // a double tap that discards.
    Shortcut {
        sequence: "Escape"
        autoRepeat: false
        enabled: (AppState.activeModal !== "" || AppState.workspaceMode === "")
                 && !AppState.colorPopoverOpen
        onActivated: {
            if (AppState.activeModal !== "") {
                AppState.modalEscape()
            } else if (AppState.isTrailingEscape()) {
                // Second half of a double tap that already closed a
                // dialog. Leave the schedule selection alone.
            } else if (AppState.clearActiveLibrarySelection()) {
                // First Escape with library focus drops the checked rows
                // of the active tab. The schedule row stays selected until
                // the next Escape.
            } else if (AppState.activeFocusPanel === "schedule"
                       && AppState.selectedScheduleIndices.length > 1) {
                // Same staging for the schedule: drop the multi-selection
                // back to the anchor row first.
                AppState.collapseScheduleSelection()
            } else if (AppState.activeFocusPanel === "schedule"
                       && AppState.scheduleSelectMode) {
                // Then leave select mode, as a library tab does.
                AppState.setScheduleSelectMode(false)
            } else if (AppState.selectedScheduleIndex >= 0) {
                AppState.selectScheduleItem(-1)
            }
        }
    }

    // Ctrl+Enter twice = save the open dialog and close it, through the
    // dialog's own save path (AppState.saveAndCloseModal). Gated on
    // dialogOpen so the command palette keeps Ctrl+Enter as "go live".
    // autoRepeat off for the same reason as Escape above.
    Shortcut {
        sequences: ["Ctrl+Return", "Ctrl+Enter"]
        autoRepeat: false
        enabled: AppState.dialogOpen
        onActivated: AppState.modalSaveTap()
    }

    // F1 = the keyboard shortcut reference (ShortcutsDialog). Toggles, and
    // only opens over nothing: there is one modal slot, so opening it over
    // an editor would throw the editor's unsaved edits away.
    Shortcut {
        sequence: "F1"
        enabled: AppState.activeModal === "" || AppState.activeModal === "shortcuts"
        onActivated: AppState.toggleShortcutHelp()
    }

    // Ctrl+A: select every row of whichever list owns the keyboard (the
    // active library tab or the schedule). Only reaches here when no text
    // field has focus: a focused TextInput claims Ctrl+A for its own
    // select-all through ShortcutOverride, so typing never loses it. The
    // library search box forwards Ctrl+A only to the schedule, when that
    // was the last panel worked in (see TabSearchBar).
    Shortcut {
        sequence: "Ctrl+A"
        enabled: AppState.consoleShortcutsActive
        onActivated: AppState.requestSelectAll()
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
        // activeFocusPanel only reaches "schedule" through a deliberate
        // schedule gesture (right-click, or a Ctrl / Shift multi-select
        // click) — see SchedulePanel. A plain row click still leaves
        // focus in the library, which is what keeps Delete from eating
        // keystrokes in the sidebar search input.
        enabled: AppState.selectedScheduleIndices.length > 0
              && AppState.consoleShortcutsActive
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
                    // One batch call: one schedule change, and the live
                    // pointer is carried past the removed rows.
                    onConfirm:   function() { AppState.removeScheduleIndices(indices) }
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
        enabled: AppState.consoleShortcutsActive
        onActivated: {
            switch (AppState.activeFocusPanel) {
                case "preview": AppState.previewNavigateUp(); break
                case "live":    AppState.liveNavigateUp();    break
                default:        AppState.libraryNavigateUp(false)
            }
        }
    }
    Shortcut {
        sequence: "Shift+Up"
        enabled: AppState.consoleShortcutsActive
        onActivated: {
            switch (AppState.activeFocusPanel) {
                case "preview": AppState.previewNavigateUp(); break
                case "live":    AppState.liveNavigateUp();    break
                default:        AppState.libraryNavigateUp(true)
            }
        }
    }
    Shortcut {
        sequence: "Down"
        enabled: AppState.consoleShortcutsActive
        onActivated: {
            switch (AppState.activeFocusPanel) {
                case "preview": AppState.previewNavigateDown(); break
                case "live":    AppState.liveNavigateDown();    break
                default:        AppState.libraryNavigateDown(false)
            }
        }
    }
    // Home / End jump to the first / last page of the Preview or Live item,
    // Page Up / Page Down to the previous / next chorus or tag. Bound only
    // while one of those two panes holds focus, so the keys keep their
    // usual meaning everywhere else.
    readonly property bool _pageJumpKeys:
        AppState.consoleShortcutsActive
        && (AppState.activeFocusPanel === "preview" || AppState.activeFocusPanel === "live")
    // A focused library search box claims Home / End for its own caret
    // before any Shortcut sees them, so TabSearchBar routes those two
    // itself (AppState.routePageJump) when Preview or Live has focus.
    Shortcut { sequence: "Home";   enabled: root._pageJumpKeys; onActivated: AppState.routePageJump("first") }
    Shortcut { sequence: "End";    enabled: root._pageJumpKeys; onActivated: AppState.routePageJump("last") }
    Shortcut { sequence: "PgUp";   enabled: root._pageJumpKeys; onActivated: AppState.routePageJump("prevChorus") }
    Shortcut { sequence: "PgDown"; enabled: root._pageJumpKeys; onActivated: AppState.routePageJump("nextChorus") }

    // Ctrl+Arrow — walk the Live pane's page list without projecting; the
    // Ctrl release commits (mainArea's Keys.onReleased). Bound only while
    // the Live pane holds focus, so Ctrl+Arrow keeps its word-wise meaning
    // in every text field in the console — an unconditional binding here
    // would break editing in the search box and the song editor.
    Shortcut {
        sequence: "Ctrl+Up"
        enabled: AppState.consoleShortcutsActive
              && AppState.activeFocusPanel === "live"
        onActivated: AppState.liveScrubUp()
    }
    Shortcut {
        sequence: "Ctrl+Down"
        enabled: AppState.consoleShortcutsActive
              && AppState.activeFocusPanel === "live"
        onActivated: AppState.liveScrubDown()
    }

    // ── Live video transport ────────────────────────────────────────────
    // Bound only while the committed live item is a video, so none of these
    // exist the rest of the time. All of them drive the LIVE clip (the one
    // the audience output plays), never the Preview clip. Keys are picked to
    // stay clear of everything else the console binds: Space and plain or
    // Ctrl+arrows already mean typing / page navigation, so seeking rides
    // Alt+arrows, which no text field uses. Ctrl+M is the editors' view
    // toggle, but those are modals and consoleShortcutsActive is false while
    // one is open, so the two bindings are never enabled together.
    //   Ctrl+P          play / pause
    //   Ctrl+Shift+P    stop (rewind to the first frame, paused)
    //   Alt+Left/Right  back / forward 10 s
    //   Alt+Home        restart from the top
    //   Alt+Up/Down     output volume up / down 10 %
    //   Ctrl+M          mute / unmute
    readonly property bool _liveVideoKeys:
        AppState.consoleShortcutsActive && AppState.liveVideoUrl.length > 0
    Shortcut {
        sequence: "Ctrl+P"
        enabled: root._liveVideoKeys
        onActivated: MediaPlaybackService.togglePlay(AppState.liveVideoUrl)
    }
    Shortcut {
        sequence: "Ctrl+Shift+P"
        enabled: root._liveVideoKeys
        onActivated: MediaPlaybackService.stop(AppState.liveVideoUrl)
    }
    Shortcut {
        sequence: "Alt+Left"
        enabled: root._liveVideoKeys
        onActivated: MediaPlaybackService.skip(AppState.liveVideoUrl, -10000)
    }
    Shortcut {
        sequence: "Alt+Right"
        enabled: root._liveVideoKeys
        onActivated: MediaPlaybackService.skip(AppState.liveVideoUrl, 10000)
    }
    Shortcut {
        sequence: "Alt+Home"
        enabled: root._liveVideoKeys
        onActivated: MediaPlaybackService.restart(AppState.liveVideoUrl)
    }
    Shortcut {
        sequence: "Alt+Up"
        enabled: root._liveVideoKeys
        onActivated: SettingsService.mediaVolume =
                         Math.min(1, Math.round((SettingsService.mediaVolume + 0.1) * 100) / 100)
    }
    Shortcut {
        sequence: "Alt+Down"
        enabled: root._liveVideoKeys
        onActivated: SettingsService.mediaVolume =
                         Math.max(0, Math.round((SettingsService.mediaVolume - 0.1) * 100) / 100)
    }
    Shortcut {
        sequence: "Ctrl+M"
        enabled: root._liveVideoKeys
        onActivated: MediaPlaybackService.muted = !MediaPlaybackService.muted
    }

    // Shift+Arrow is the same dispatch with the extend flag set. It needs its
    // own Shortcut because a sequence of "Up" does not match a Shift+Up press
    // — Qt treats the modified chord as a different sequence entirely. Preview
    // and Live have no selection to extend, so there Shift behaves as a plain
    // arrow rather than swallowing the key.
    Shortcut {
        sequence: "Shift+Down"
        enabled: AppState.consoleShortcutsActive
        onActivated: {
            switch (AppState.activeFocusPanel) {
                case "preview": AppState.previewNavigateDown(); break
                case "live":    AppState.liveNavigateDown();    break
                default:        AppState.libraryNavigateDown(true)
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
        enabled: AppState.consoleShortcutsActive
        onActivated: {
            switch (AppState.activeFocusPanel) {
                case "preview": AppState.previewActivate(); break
                case "library": AppState.libraryActivate(); break
            }
        }
    }
}
