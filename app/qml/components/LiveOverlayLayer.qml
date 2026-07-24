import QtQuick
import QtQuick.Effects
import Crater

// LiveOverlayLayer — renders the live timer / clock / message overlay from
// LiveMessages, styled by the per-type theme in LiveOverlayStyles. Mounted
// inside ProjectionScene's canvas `stage` (paints audience + NDI); the style
// editor and the Timers dialog mount preview instances at small sizes.
//
// Resolution-independent: every size is a fraction of this item's own height,
// so the SAME component looks right at 1080p and in a small preview box. Inputs
// default to the live singletons but are overridable — the editors rebind them
// to pending content / a pending style so a preview matches "Show" exactly.
//
// Content (mode/message/timers) comes from LiveMessages; placement (position)
// too; the LOOK (text fill incl. gradient, effect, background) comes from the
// resolved `style`. The per-tick clock lives here (a QtObject singleton can't
// own a Timer); both projection copies tick independently off Date.now().
Item {
    id: layer

    // ── Content inputs ──────────────────────────────────────────────────
    property string mode:                LiveMessages.mode
    property string message:             LiveMessages.message
    property double countdownTargetMs:   LiveMessages.countdownTargetMs
    property string caption:             LiveMessages.caption
    property string countdownEndMode:    LiveMessages.countdownEndMode
    property string countdownEndMessage: LiveMessages.countdownEndMessage
    property double countupStartMs:      LiveMessages.countupStartMs
    property double countupAccumMs:      LiveMessages.countupAccumMs
    property bool   countupRunning:      LiveMessages.countupRunning
    property bool   clock24h:            LiveMessages.clock24h
    property bool   clockShowSeconds:    LiveMessages.clockShowSeconds
    property string position:            LiveMessages.position

    // ── Look ────────────────────────────────────────────────────────────
    // Resolved per-type style; re-resolves when the mode changes or the
    // operator edits that type's theme (styleFor reads LiveOverlayStyles state).
    property var  style: LiveOverlayStyles.styleFor(mode)
    property bool animate: !SettingsService.reduceMotion

    readonly property bool _active: mode !== ""
    readonly property real _h: height

    // ── Clock tick ──────────────────────────────────────────────────────
    property double nowMs: 0
    Component.onCompleted: layer.nowMs = Date.now()
    Timer {
        interval: 200
        repeat: true
        running: layer._active && layer.mode !== "message"
        triggeredOnStart: true
        onTriggered: layer.nowMs = Date.now()
    }

    // ── Derived values ──────────────────────────────────────────────────
    readonly property int _countdownSec: Math.ceil((countdownTargetMs - nowMs) / 1000)
    readonly property double _countupMs:
        countupAccumMs + (countupRunning ? Math.max(0, nowMs - countupStartMs) : 0)
    readonly property bool _showingMessage:
        mode === "message"
        || (mode === "countdown" && _countdownSec <= 0 && countdownEndMode === "message")

    function _clockText() {
        var d = new Date(nowMs)
        var h = d.getHours(), m = d.getMinutes(), s = d.getSeconds(), suffix = ""
        if (!clock24h) {
            suffix = h >= 12 ? " PM" : " AM"
            h = h % 12
            if (h === 0) h = 12
        }
        var t = (clock24h ? LiveMessages.pad2(h) : String(h)) + ":" + LiveMessages.pad2(m)
        if (clockShowSeconds) t += ":" + LiveMessages.pad2(s)
        return t + suffix
    }
    function _primaryText() {
        switch (mode) {
        case "message": return message
        case "clock":   return _clockText()
        case "countup": return LiveMessages.fmtDuration(_countupMs / 1000)
        case "countdown":
            if (_countdownSec <= 0 && countdownEndMode === "message") return countdownEndMessage
            return LiveMessages.fmtDuration(Math.max(0, _countdownSec))
        }
        return ""
    }
    function _captionText() {
        if (mode === "countdown") {
            if (_countdownSec <= 0 && countdownEndMode === "message") return ""
            return caption
        }
        return ""
    }
    function _cased(t) { return (style && style.uppercase) ? String(t).toUpperCase() : t }

    // ── Sizing ──────────────────────────────────────────────────────────
    readonly property real _primarySize: {
        var frac = _showingMessage ? (position === "center" ? 0.11 : 0.085)
                                    : (position === "center" ? 0.24 : 0.13)
        return Math.max(11, _h * frac)
    }
    readonly property real _captionSize: Math.max(9, _h * 0.05)
    readonly property int  _fontWeight: (style && style.fontWeight) || Theme.font.weightBold
    readonly property real _letterSpacing: (style && style.letterSpacing)
        ? style.letterSpacing * _primarySize / 40 : 0
    readonly property bool _fillGradient: style && style.textFillType === "gradient"

    // ── Effect (shadow / glow) ──────────────────────────────────────────
    readonly property string _effect: (style && style.effect) || "none"
    readonly property color  _effectColor: (style && style.effectColor) || "#000000"
    readonly property bool   _effectOn: _effect === "shadow" || _effect === "glow"
    readonly property real   _effBlur: _effect === "glow" ? 0.6 : 0.28
    readonly property real   _effOffY: _effect === "glow" ? 0 : Math.max(1, _primarySize * 0.03)

    // ── Show / hide fade ────────────────────────────────────────────────
    opacity: _active ? 1.0 : 0.0
    visible: opacity > 0.001
    Behavior on opacity {
        NumberAnimation { duration: Theme.motion.normal; easing.type: Easing.InOutCubic }
    }

    // ── Backdrop ────────────────────────────────────────────────────────
    readonly property string _bg: (style && style.background) || "dim"
    Rectangle {
        anchors.fill: parent
        color: layer._bg === "solid" ? (layer.style.backgroundColor || "#0a0a0c") : "#000000"
        opacity: layer._bg === "solid" ? 1.0 : layer._bg === "dim" ? 0.5 : 0.0
    }
    Loader {
        anchors.fill: parent
        active: layer._bg === "gradient"
        sourceComponent: GradientFill {
            spec: layer.style ? layer.style.backgroundGradient : ({})
            animate: layer.animate
        }
    }

    // ── Text block ──────────────────────────────────────────────────────
    Column {
        id: block
        width: layer.width * 0.86
        spacing: layer._h * 0.02
        anchors.horizontalCenter: parent.horizontalCenter
        y: layer.position === "top"    ? layer._h * 0.10
         : layer.position === "bottom" ? layer._h * 0.90 - height
                                       : (layer._h - height) / 2

        // Primary line. A hidden reference Text always measures the layout so
        // the gradient variant (which fills its box) gets the exact glyph
        // height; the solid variant IS that same reference Text made visible.
        Item {
            id: primaryHost
            width: block.width
            height: refText.contentHeight
            visible: refText.text.length > 0

            Text {
                id: refText
                width: parent.width
                text: layer._cased(layer._primaryText())
                visible: !layer._fillGradient
                color: (layer.style && layer.style.textColor) || "#ffffff"
                horizontalAlignment: Text.AlignHCenter
                font.family: Theme.font.family
                font.pixelSize: layer._primarySize
                font.weight: layer._fontWeight
                font.letterSpacing: layer._letterSpacing
                wrapMode: Text.Wrap
                maximumLineCount: 4
                elide: Text.ElideRight
                layer.enabled: !layer._fillGradient && layer._effectOn
                layer.effect: MultiEffect {
                    shadowEnabled: true
                    shadowColor: layer._effectColor
                    shadowBlur: layer._effBlur
                    shadowVerticalOffset: layer._effOffY
                    shadowHorizontalOffset: 0
                    autoPaddingEnabled: true
                }
            }

            GradientText {
                anchors.fill: parent
                visible: layer._fillGradient
                text: layer._cased(layer._primaryText())
                spec: layer.style ? layer.style.textGradient : ({})
                animate: layer.animate
                fontFamily: Theme.font.family
                fontPixelSize: layer._primarySize
                fontWeight: layer._fontWeight
                letterSpacing: layer._letterSpacing
                wrapMode: Text.Wrap
                maximumLineCount: 4
                layer.enabled: layer._fillGradient && layer._effectOn
                layer.effect: MultiEffect {
                    shadowEnabled: true
                    shadowColor: layer._effectColor
                    shadowBlur: layer._effBlur
                    shadowVerticalOffset: layer._effOffY
                    shadowHorizontalOffset: 0
                    autoPaddingEnabled: true
                }
            }
        }

        // Caption (solid, always — a small supporting line under a countdown).
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: layer._cased(layer._captionText())
            visible: text.length > 0
            color: (layer.style && layer.style.textColor) || "#ffffff"
            opacity: 0.85
            font.family: Theme.font.family
            font.pixelSize: layer._captionSize
            font.weight: Theme.font.weightMedium
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            layer.enabled: layer._effectOn
            layer.effect: MultiEffect {
                shadowEnabled: true
                shadowColor: layer._effectColor
                shadowBlur: 0.25
                shadowVerticalOffset: Math.max(1, layer._captionSize * 0.06)
                autoPaddingEnabled: true
            }
        }
    }
}
