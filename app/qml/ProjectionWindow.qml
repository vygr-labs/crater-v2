import QtQuick
import QtQuick.Window

// Second-monitor output window. A separate QQuickWindow (NOT inside an
// ApplicationWindow), bound directly to ProjectionService Q_PROPERTYs — when
// projection state changes, Qt's binding engine re-evaluates and this window
// re-renders, no IPC, no Redux, no event bus. See plan's "Deviations from
// Electron" table for the rationale.
Window {
    id: projectionWindow

    // The screen index to target. Main.qml binds this to OutputService.
    property int screenIndex: 0

    // Hot-bind to the selected QScreen so dragging settings across monitors
    // moves the window to the new display.
    screen: Qt.application.screens[screenIndex] || Qt.application.screens[0]

    flags: Qt.Window | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
    // NOTE: `visibility` is set from Main.qml so the parent can switch between
    // Window.FullScreen (live) and Window.Hidden (idle). Don't also bind
    // `visible` — they conflict.
    title: qsTr("Crater Projection")

    // Background color from theme tokens, with a sensible fallback while the
    // theme is still resolving on first render.
    color: {
        const t = ProjectionService.currentTheme
        if (t && t.tokens && t.tokens.background && t.tokens.background.color)
            return t.tokens.background.color
        return "#000000"
    }

    onVisibleChanged: {
        if (visible) OutputService.notifyProjectionOpened()
        else         OutputService.notifyProjectionClosed()
    }

    // Convenience handles. Bound — re-evaluate on every stateChanged signal.
    readonly property var  _item    : ProjectionService.currentItem
    readonly property int  _page    : ProjectionService.pageIndex
    readonly property var  _theme   : ProjectionService.currentTheme
    readonly property bool _isClear : ProjectionService.isClear
    readonly property bool _showLogo: ProjectionService.showLogo

    // Token accessors. The `??` and `?.` operators are supported in QML's JS
    // engine (Qt 6.4+); we use them to gracefully handle missing tokens.
    readonly property color _bg: {
        const c = _theme && _theme.tokens && _theme.tokens.background
                ? _theme.tokens.background.color
                : "#000000"
        return c
    }
    readonly property color _fg: {
        return _theme && _theme.tokens && _theme.tokens.text
            ? _theme.tokens.text.color
            : "#ffffff"
    }
    readonly property string _fontFamily: {
        return _theme && _theme.tokens && _theme.tokens.text && _theme.tokens.text.fontFamily
            ? _theme.tokens.text.fontFamily
            : "Segoe UI Variable Display"
    }
    readonly property int _fontPixelSize: {
        return _theme && _theme.tokens && _theme.tokens.text && _theme.tokens.text.fontPixelSize
            ? _theme.tokens.text.fontPixelSize
            : 64
    }
    readonly property int _fontWeight: {
        return _theme && _theme.tokens && _theme.tokens.text && _theme.tokens.text.fontWeight
            ? _theme.tokens.text.fontWeight
            : 500
    }
    readonly property int _padding: {
        return _theme && _theme.tokens && _theme.tokens.layout && _theme.tokens.layout.padding
            ? _theme.tokens.layout.padding
            : 80
    }
    readonly property int _transitionMs: {
        return _theme && _theme.tokens && _theme.tokens.transition && _theme.tokens.transition.durationMs
            ? _theme.tokens.transition.durationMs
            : 320
    }

    // Content text — current page of the live item.
    readonly property string _pageText: {
        if (!_item) return ""
        const pages = _item.pages
        if (!pages || pages.length === 0) return ""
        const idx = Math.min(_page, pages.length - 1)
        const p = pages[idx]
        return (p && p.content) || ""
    }

    Item {
        anchors.fill: parent
        anchors.margins: projectionWindow._padding

        // Content text — the main projection body.
        Text {
            id: bodyText
            anchors.fill: parent
            visible: !projectionWindow._isClear && !projectionWindow._showLogo
            opacity: visible ? 1.0 : 0.0
            text: projectionWindow._pageText
            color: projectionWindow._fg
            font.family: projectionWindow._fontFamily
            font.pixelSize: projectionWindow._fontPixelSize
            font.weight: projectionWindow._fontWeight
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            wrapMode: Text.WordWrap

            Behavior on opacity {
                NumberAnimation {
                    duration: projectionWindow._transitionMs
                    easing.type: Easing.InOutCubic
                }
            }
        }

        // Logo placeholder. Real logo asset comes later when MediaService lands.
        Text {
            id: logoText
            anchors.centerIn: parent
            visible: projectionWindow._showLogo && !projectionWindow._isClear
            opacity: visible ? 1.0 : 0.0
            text: "CRATER"
            color: projectionWindow._fg
            font.family: projectionWindow._fontFamily
            font.pixelSize: 128
            font.weight: 900
            font.letterSpacing: 8

            Behavior on opacity {
                NumberAnimation {
                    duration: projectionWindow._transitionMs
                    easing.type: Easing.InOutCubic
                }
            }
        }
    }
}
