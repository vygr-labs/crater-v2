import QtQuick
import QtQuick.Window
import Crater

// Second-monitor output window. A separate QQuickWindow (NOT inside an
// ApplicationWindow), bound directly to ProjectionService Q_PROPERTYs — when
// projection state changes, Qt's binding engine re-evaluates and this window
// re-renders, no IPC, no Redux, no event bus. See plan's "Deviations from
// Electron" table for the rationale.
//
// As of tokens v2 the theme is a node graph (containers + texts positioned
// by percent on a canvas). This window letterboxes the canvas into the
// screen and Repeats node delegates inside that stage. Per-node fade is
// not animated — the entire content layer fades on go-live/page-change.
Window {
    id: projectionWindow

    // The screen index to target. Main.qml binds this to OutputService.
    property int screenIndex: 0

    // Whether the projection is "logically open" — i.e. shown to the operator
    // and the audience. When false, the window stays *alive* but is parked
    // offscreen with no taskbar / Alt+Tab presence, so the scene graph keeps
    // rendering and NDI (or any other capture consumer) always has fresh
    // frames. This is the cheap version of the render-pipeline-decouple
    // story — the real decouple (headless QQuickRenderControl + shared FBO)
    // lives in a future PR; this gets us 90% of the benefit today by simply
    // not letting visibility go Hidden.
    property bool logicallyVisible: true

    readonly property var _targetScreen:
        Qt.application.screens[screenIndex] || Qt.application.screens[0]

    readonly property bool _windowed:
        OutputService.projectionMode === OutputService.Windowed

    screen: _targetScreen

    // Detach from the operator console's window family. Without this, Qt
    // makes nested Windows transient children of their declaring ancestor —
    // they share a taskbar slot and inherit z-order quirks. Setting to null
    // gives this window its own taskbar entry on Windows, its own Alt+Tab
    // slot, and lets the operator click back to the console even when the
    // projection is fullscreen on a single-monitor laptop.
    transientParent: null

    // Visibility never reaches Window.Hidden — even when "logically closed"
    // we keep the window in Window.Windowed state at an off-screen position
    // so the Qt scene graph keeps rendering and grabWindow() returns valid
    // frames for NDI. When logically visible, we honour OutputService's
    // Fullscreen / Windowed preference.
    visibility: logicallyVisible
        ? (_windowed ? Window.Windowed : Window.FullScreen)
        : Window.Windowed

    // Flags: standard window in production; tool-flagged (no taskbar entry,
    // no Alt+Tab, doesn't accept focus) when parked offscreen so the
    // operator never sees the "hidden" projection window in their OS chrome.
    flags: !logicallyVisible
        ? (Qt.Tool | Qt.FramelessWindowHint | Qt.WindowDoesNotAcceptFocus)
        : _windowed
            ? Qt.Window
            : (Qt.Window | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint)
    title: qsTr("Crater Projection")

    // Windowed-mode geometry. When logically visible: 480x270 16:9 canvas-
    // aspect thumbnail anchored to the bottom-right of the target screen
    // with a 24 px inset. When offscreen: full 1920x1080 so the scene
    // renders at projection resolution (NDI receivers get proper-sized
    // frames) and positioned way off the virtual desktop so no display
    // ever shows it. Fullscreen visibility overrides width/height/x/y, so
    // setting these unconditionally is safe — they only take effect when
    // visibility is Window.Windowed.
    width:  logicallyVisible ?  480 : 1920
    height: logicallyVisible ?  270 : 1080
    x: !logicallyVisible
        ? -32000
        : (_targetScreen
            ? _targetScreen.virtualX + _targetScreen.width  - width  - 24
            : 100)
    y: !logicallyVisible
        ? -32000
        : (_targetScreen
            ? _targetScreen.virtualY + _targetScreen.height - height - 24
            : 100)

    // Background color = first container's color, falling back to black.
    // Painted BEFORE the canvas stage so anything outside the letterbox
    // looks intentional (matte black, not theme color stretched).
    color: "#000000"

    // OutputService.projectionOpen now tracks logical visibility, not OS
    // visibility. Since the window stays OS-visible even when "closed",
    // onVisibleChanged would fire exactly once at startup and never again;
    // onLogicallyVisibleChanged is the right hook for the open/close semantic.
    onLogicallyVisibleChanged: {
        if (logicallyVisible) OutputService.notifyProjectionOpened()
        else                  OutputService.notifyProjectionClosed()
    }

    // User clicked the close (X) button on the windowed projector. Reject
    // the OS-level close so the nested QQuickWindow object is reused on
    // the next goLive() — calling endLive() routes through projectorVisible,
    // which drives Main.qml's visibility binding to Window.Hidden cleanly.
    onClosing: function(closeEvent) {
        closeEvent.accepted = false
        AppState.endLive()
    }

    // Esc is the universal escape hatch — useful primarily in Fullscreen
    // mode on a single-monitor system, where there's no title bar to click
    // and the operator can otherwise get stuck behind the projection. The
    // Shortcut's default Qt.WindowShortcut context scopes it to this
    // window, so it doesn't fight Main.qml's Esc handler (modals / schedule
    // deselect), which runs in the operator console's scope.
    Shortcut {
        sequence: "Escape"
        onActivated: AppState.endLive()
    }

    // Reactive bindings to ProjectionService — stateChanged() fans into all
    // of these. Defensive `??` / `&&` chaining handles the moment before the
    // first theme is resolved (e.g. cold start, before any goLive call).
    readonly property var    _item      : ProjectionService.currentItem
    readonly property string _kind      : ProjectionService.contentKind
    readonly property int    _page      : ProjectionService.pageIndex
    readonly property bool   _isClear   : ProjectionService.isClear
    readonly property bool   _showLogo  : ProjectionService.showLogo

    // ── Theme resolution (reactive) ─────────────────────────────────────
    // Mirrors Electron's RenderProjection createMemo: prefer the per-item
    // override (item.themeId), else fall back to ThemeService.defaultFor(kind).
    // The `_themeRevision` int is bumped by Connections below so the binding
    // re-evaluates whenever the operator changes the default theme for a kind
    // OR a theme is added/deleted — without forcing the operator to re-Go-Live.
    property int _themeRevision: 0

    readonly property var _theme: {
        _themeRevision   // dependency: re-fires this binding on signal bumps
        return AppState.resolveItemTheme(_item)
    }

    Connections {
        target: ThemeService
        function onDefaultsChanged()  { projectionWindow._themeRevision++ }
        function onAllThemesChanged() { projectionWindow._themeRevision++ }
    }

    readonly property var    _tokens    : _theme && _theme.tokens ? _theme.tokens : ({})
    readonly property var    _canvas    : _tokens.canvas || ({ width: 1920, height: 1080 })
    readonly property var    _nodes     : _tokens.nodes  || []
    readonly property int    _transMs   : 280

    // ── Content resolution ──────────────────────────────────────────────
    // Live current page text — the actual lyric/verse content the
    // operator sent live. Text nodes with linkage=scriptureText or
    // linkage=lyric show this.
    readonly property string _pageText: {
        if (!_item) return ""
        const pages = _item.pages
        if (!pages || pages.length === 0) return ""
        const idx = Math.min(_page, pages.length - 1)
        const p = pages[idx]
        return (p && p.content) || ""
    }
    // Reference label (e.g. "John 3:16") for scripture items.
    readonly property string _refText: {
        if (!_item) return ""
        return _item.title || _item.reference || ""
    }

    function resolveText(node) {
        if (!node || node.kind !== "text") return ""
        const data = node.data || {}
        switch (data.linkage) {
            case "scriptureRef":  return _refText
            case "scriptureText": return _pageText
            case "lyric":         return _pageText
            case "custom":        return data.text || ""
        }
        return data.text || ""
    }

    // Pre-sort nodes by z so render order matches layer order. Recomputes
    // when _nodes changes — cheap for ≤50 nodes.
    readonly property var _sortedNodes: {
        const arr = _nodes.slice()
        arr.sort((a, b) => ((a.style && a.style.z) || 0) - ((b.style && b.style.z) || 0))
        return arr
    }

    // ── Stage: letterbox the canvas into the screen ─────────────────────
    Item {
        id: stage
        anchors.centerIn: parent
        readonly property real _scale: Math.min(parent.width  / projectionWindow._canvas.width,
                                                parent.height / projectionWindow._canvas.height)
        width:  projectionWindow._canvas.width  * _scale
        height: projectionWindow._canvas.height * _scale
        clip: true

        // Content layer — fades in/out on go-live, page-change, logo.
        // `isClear` no longer hides the whole stage; instead it hides only
        // *text* nodes (handled per-delegate below) so the theme background
        // and any non-text nodes remain visible. Logo overlay still drives
        // a full-stage fade because the logo is meant to replace the
        // entire scene visually.
        Item {
            id: contentLayer
            anchors.fill: parent
            opacity: projectionWindow._showLogo ? 0 : 1
            Behavior on opacity {
                NumberAnimation {
                    duration: projectionWindow._transMs
                    easing.type: Easing.InOutCubic
                }
            }

            Repeater {
                model: projectionWindow._sortedNodes
                delegate: Item {
                    readonly property var _style: modelData.style || ({})
                    x:        stage.width  * ((_style.x      || 0) / 100)
                    y:        stage.height * ((_style.y      || 0) / 100)
                    width:    stage.width  * ((_style.width  || 0) / 100)
                    height:   stage.height * ((_style.height || 0) / 100)
                    opacity:  _style.opacity !== undefined ? _style.opacity : 1
                    rotation: _style.rotation || 0

                    // Per-node "clear fader" — a nested Item whose opacity
                    // drops to 0 only when the node is a TEXT node AND the
                    // projection is cleared. Non-text nodes (image
                    // backgrounds, containers, decorative shapes) keep
                    // their parent opacity and remain visible. Separated
                    // from the outer Item's opacity so theme-editor edits
                    // to `style.opacity` continue to snap (no Behavior
                    // there), while the clear fade is animated here.
                    Item {
                        anchors.fill: parent
                        opacity: (projectionWindow._isClear && modelData.kind === "text") ? 0 : 1
                        Behavior on opacity {
                            NumberAnimation {
                                duration: projectionWindow._transMs
                                easing.type: Easing.InOutCubic
                            }
                        }

                        NodeRenderer {
                            anchors.fill: parent
                            node: modelData
                            resolvedText: projectionWindow.resolveText(modelData)
                        }
                    }
                }
            }
        }

        // ── No-theme fallback ────────────────────────────────────────────
        // Shown when a song/scripture goes live but the operator hasn't set a
        // default theme for that kind and no built-in matches. Without this,
        // the projection would be silently black — confusing during a service.
        // Mirrors Electron's NoThemeError in RenderProjection.tsx. Text-bearing
        // kinds only — image/video items don't render through the theme path.
        Text {
            id: noThemeText
            anchors.centerIn: parent
            anchors.margins: 40
            width: parent.width - 80
            visible: !projectionWindow._isClear
                  && !projectionWindow._showLogo
                  && (projectionWindow._kind === "song" || projectionWindow._kind === "scripture")
                  && (!projectionWindow._theme || (projectionWindow._theme.id || 0) === 0)
            text: qsTr("Default %1 theme has not been set").arg(projectionWindow._kind)
                       .toUpperCase()
            color: "#ffffff"
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            font.family: Theme.font.family
            font.pixelSize: 72
            font.weight: Theme.font.weightBold
        }

        // Logo overlay — sits above the content layer when toggled on.
        // LogoView renders the configured image OR video, or a "CRATER"
        // fallback when no logo path has been chosen. `active` gates the
        // video decoder; opacity drives the fade so the decoder doesn't
        // bounce on every fade tick.
        //
        // Logo visibility is now independent of `isClear` — clearing only
        // hides text, so a logo toggled on stays visible through a clear.
        LogoView {
            id: logoView
            anchors.fill: parent
            active: projectionWindow._showLogo
            opacity: projectionWindow._showLogo ? 1.0 : 0.0

            Behavior on opacity {
                NumberAnimation {
                    duration: projectionWindow._transMs
                    easing.type: Easing.InOutCubic
                }
            }
        }
    }
}
