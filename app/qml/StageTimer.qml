pragma Singleton
import QtQuick

// The stage display's timer: a service timer that counts up, or a countdown
// for a sermon or a slot. The operator starts it from the top bar's Stage
// timer menu and the stage display shows it beside the clock.
//
// Session state, like AppState, so it is not saved: a timer left running
// last Sunday means nothing this Sunday.
//
// Time is measured against the wall clock rather than by counting ticks.
// The tick only refreshes `now`, so a stalled frame or a busy render thread
// can make the display late, never wrong.
QtObject {
    id: root

    // "off", "elapsed" (counts up from zero) or "countdown".
    property string mode: "off"
    property bool running: false
    // Length of the countdown in ms. Unused while counting up.
    property real durationMs: 0

    // Time banked by earlier runs, and when the current run started.
    property real _bankedMs: 0
    property real _startedAt: 0
    property real now: Date.now()

    readonly property bool active: mode !== "off"
    readonly property real elapsedMs: _bankedMs + (running ? Math.max(0, now - _startedAt) : 0)
    // Negative once a countdown has run past zero.
    readonly property real remainingMs: durationMs - elapsedMs
    readonly property bool overtime: mode === "countdown" && remainingMs < 0
    // The last two minutes of a countdown, so the stage can warn.
    readonly property bool nearEnd: mode === "countdown" && remainingMs >= 0 && remainingMs <= 120000

    // What the stage display and the top bar show: "1:04:09", "12:30",
    // or "+0:45" once a countdown is over.
    readonly property string text: {
        if (!active) return ""
        if (mode === "countdown") {
            // Rounded up, so a countdown shows 0:00 only at zero, and the
            // first second over reads +0:01.
            return remainingMs >= 0 ? _format(Math.ceil(remainingMs / 1000))
                                    : "+" + _format(Math.floor(-remainingMs / 1000) + 1)
        }
        return _format(Math.floor(elapsedMs / 1000))
    }

    function _format(totalSeconds) {
        const s = totalSeconds % 60
        const m = Math.floor(totalSeconds / 60) % 60
        const h = Math.floor(totalSeconds / 3600)
        const ss = (s < 10 ? "0" : "") + s
        if (h > 0) return h + ":" + (m < 10 ? "0" : "") + m + ":" + ss
        return m + ":" + ss
    }

    function startElapsed() {
        _begin("elapsed", 0)
    }

    function startCountdown(minutes) {
        _begin("countdown", Math.max(1, minutes) * 60000)
    }

    function _begin(m, ms) {
        mode = m
        durationMs = ms
        _bankedMs = 0
        now = Date.now()
        _startedAt = now
        running = true
    }

    function pause() {
        if (!running) return
        now = Date.now()
        _bankedMs = elapsedMs
        running = false
    }

    function resume() {
        if (running || !active) return
        now = Date.now()
        _startedAt = now
        running = true
    }

    function stop() {
        running = false
        mode = "off"
        durationMs = 0
        _bankedMs = 0
    }

    // A quarter second, not a second: a one second tick that lands just
    // either side of the second boundary would make the display skip a
    // second or show one twice. The text only changes once a second, so
    // the extra ticks redraw nothing.
    property Timer _tick: Timer {
        interval: 250
        repeat: true
        running: root.running
        onTriggered: root.now = Date.now()
    }
}
