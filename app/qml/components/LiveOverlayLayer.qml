import QtQuick
import Crater

// LiveOverlayLayer — renders the live timer / clock / message overlay from
// LiveMessages onto whatever surface hosts it. Mounted inside ProjectionScene's
// canvas `stage`, so a single instance each paints the audience window and the
// NDI canvas; the in-dialog preview mounts a second instance at a small size.
//
// Resolution-independent: every size is a fraction of this item's own height,
// so the SAME component looks right at 1080p on the projector and at ~180px in
// the control dialog's preview box. That's also why the inputs below default to
// the LiveMessages singleton but can be overridden — the dialog rebinds them to
// its *pending* config so the preview shows exactly what "Show" will push,
// while the projection instances keep the live singleton bindings.
//
// The per-tick clock lives here (a QtObject singleton can't own a Timer). Both
// projection copies tick independently off Date.now(); a sub-second skew
// between them is invisible at seconds resolution.
Item {
    id: layer

    // ── Inputs (default: the live singleton; overridable for preview) ────
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
    property string background:          LiveMessages.background

    readonly property bool _active: mode !== ""
    readonly property real  _h: height

    // ── Clock ───────────────────────────────────────────────────────────
    // nowMs is bumped by the Timer; every displayed value binds through it so
    // the digits advance. Only runs for the ticking modes (a static message
    // needs no clock).
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
    // ceil for the countdown so it reads "05:00" on start (not "04:59") and
    // only hits 00:00 at true zero. Count-up floors — elapsed seconds.
    readonly property int _countdownSec: Math.ceil((countdownTargetMs - nowMs) / 1000)
    readonly property double _countupMs:
        countupAccumMs + (countupRunning ? Math.max(0, nowMs - countupStartMs) : 0)

    // Whether the primary line is currently rendering message text (message
    // mode, or a finished countdown configured to swap to its end message) —
    // drives font sizing/weight so wrapped prose isn't set at digit scale.
    readonly property bool _showingMessage:
        mode === "message"
        || (mode === "countdown" && _countdownSec <= 0 && countdownEndMode === "message")

    function _clockText() {
        var d = new Date(nowMs)
        var h = d.getHours()
        var m = d.getMinutes()
        var s = d.getSeconds()
        var suffix = ""
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
            if (_countdownSec <= 0 && countdownEndMode === "message")
                return countdownEndMessage
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

    // ── Sizing ──────────────────────────────────────────────────────────
    readonly property real _primarySize: {
        var frac = _showingMessage ? (position === "center" ? 0.11 : 0.085)
                                    : (position === "center" ? 0.24 : 0.13)
        return Math.max(11, _h * frac)
    }
    readonly property real _captionSize: Math.max(9, _h * 0.05)

    // ── Show / hide fade ────────────────────────────────────────────────
    opacity: _active ? 1.0 : 0.0
    visible: opacity > 0.001
    Behavior on opacity {
        NumberAnimation { duration: Theme.motion.normal; easing.type: Easing.InOutCubic }
    }

    // ── Backdrop ────────────────────────────────────────────────────────
    // none  → transparent (text floats; the outline keeps it legible)
    // dim   → half-black scrim (content stays faintly visible behind)
    // solid → opaque near-black (full takeover — the countdown-loop look)
    Rectangle {
        anchors.fill: parent
        color: layer.background === "solid" ? "#0a0a0c" : "#000000"
        opacity: layer.background === "solid" ? 1.0
               : layer.background === "dim"   ? 0.5
                                              : 0.0
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

        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: layer._primaryText()
            visible: text.length > 0
            color: "#ffffff"
            font.family: Theme.font.family
            font.pixelSize: layer._primarySize
            font.weight: layer._showingMessage ? Theme.font.weightSemiBold
                                               : Theme.font.weightBold
            wrapMode: Text.Wrap
            maximumLineCount: 4
            elide: Text.ElideRight
            // Outline so "none"-backdrop text stays readable over any live
            // content; harmless on dim/solid. Mirrors ProjectionScene's
            // scriptureFooter / noThemeText legibility treatment.
            style: Text.Outline
            styleColor: "#000000"
        }

        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: layer._captionText()
            visible: text.length > 0
            color: "#f0f0f0"
            font.family: Theme.font.family
            font.pixelSize: layer._captionSize
            font.weight: Theme.font.weightMedium
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            style: Text.Outline
            styleColor: "#000000"
        }
    }
}
