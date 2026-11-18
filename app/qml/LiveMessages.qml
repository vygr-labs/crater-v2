pragma Singleton
import QtQuick

// The live overlay: a countdown, a count-up, the time of day or a message,
// drawn over the audience output by LiveOverlayLayer. The operator drives it
// from the Messages dialog (LiveMessagesDialog).
//
// Session state, like AppState and StageTimer, so nothing is saved: a message
// left up last Sunday means nothing this Sunday.
//
// It is kept apart from ProjectionService on purpose. The overlay is not the
// live item, so going live, changing slide, clearing and the logo all leave
// it where it is, the same way the logo layer is independent of the content.
//
// Time is measured against the wall clock rather than by counting ticks. The
// tick only refreshes `now`, so a stalled frame can make the display late,
// never wrong. There is one tick for every surface (projector, extra outputs,
// NDI and the Live monitor), so they all show the same digits.
QtObject {
    id: root

    // What the overlay shows: "countdown", "countup", "clock" or "message".
    // It keeps its value after hide() so the overlay can fade out on the
    // text it was showing instead of blanking first.
    property string mode: "countdown"
    // True while the overlay is on screen.
    property bool active: false

    // ── Message ─────────────────────────────────────────────────────────
    property string message: ""

    readonly property var presets: [
        qsTr("Please silence your phones"),
        qsTr("The service will begin shortly"),
        qsTr("Please stand"),
        qsTr("Please be seated"),
        qsTr("Welcome"),
        qsTr("Parents, you're needed in the nursery")
    ]

    // ── Countdown ───────────────────────────────────────────────────────
    // An absolute wall-clock target in ms, so the remaining time is always
    // target minus now and never drifts.
    property real   countdownTargetMs: 0
    property string caption: ""
    // "hold" stays on 00:00 at the end, "message" swaps to countdownEndMessage.
    property string countdownEndMode: "hold"
    property string countdownEndMessage: ""

    // ── Count-up ────────────────────────────────────────────────────────
    // Time banked by earlier runs, and when the current run started.
    property bool countupRunning: false
    property real _countupBankedMs: 0
    property real _countupStartedAt: 0

    // ── Clock ───────────────────────────────────────────────────────────
    property bool clock24h: false
    property bool clockShowSeconds: false

    // ── Placement ───────────────────────────────────────────────────────
    // position: "top" | "center" | "bottom"
    // background: "none" floats the text over the live content, "dim"
    // darkens the whole screen behind it, "solid" covers it completely.
    property string position: "center"
    property string background: "solid"

    // ── Derived ─────────────────────────────────────────────────────────
    property real now: Date.now()

    readonly property bool countdownDone: mode === "countdown" && countdownTargetMs - now <= 0
    // Rounded up, so a five minute countdown opens on 05:00 and shows 00:00
    // only at zero.
    readonly property int countdownSeconds: Math.max(0, Math.ceil((countdownTargetMs - now) / 1000))
    readonly property real countupMs:
        _countupBankedMs + (countupRunning ? Math.max(0, now - _countupStartedAt) : 0)

    // True when the main line is prose rather than digits. The layer sets
    // prose smaller and lets it wrap.
    readonly property bool showingMessage:
        mode === "message" || (countdownDone && countdownEndMode === "message")

    // The main line and the small line under it, as the audience sees them.
    readonly property string text: {
        switch (mode) {
        case "message":   return message
        case "clock":     return clockText(now, clock24h, clockShowSeconds)
        case "countup":   return formatDuration(Math.floor(countupMs / 1000))
        case "countdown":
            return (countdownDone && countdownEndMode === "message")
                   ? countdownEndMessage : formatDuration(countdownSeconds)
        }
        return ""
    }
    readonly property string captionText:
        (mode === "countdown" && !showingMessage) ? caption : ""

    // ── Control ─────────────────────────────────────────────────────────
    function showMessage(msg) {
        message = String(msg || "")
        _show("message")
    }

    function showClock() {
        _show("clock")
    }

    // Count down a length of time from now.
    function startCountdown(totalSeconds, captionText, endMessage) {
        _startCountdownTo(Date.now() + Math.max(0, Math.floor(totalSeconds || 0)) * 1000,
                          captionText, endMessage)
    }

    // Count down to a time of day (24-hour), today or tomorrow if it has
    // already passed.
    function startCountdownUntil(hour, minute, captionText, endMessage) {
        _startCountdownTo(untilTarget(hour, minute, Date.now()), captionText, endMessage)
    }

    // An empty end message means hold at 00:00.
    function _startCountdownTo(targetMs, captionText, endMessage) {
        countdownTargetMs = targetMs
        caption = String(captionText || "")
        countdownEndMessage = String(endMessage || "").trim()
        countdownEndMode = countdownEndMessage.length > 0 ? "message" : "hold"
        _show("countdown")
    }

    function startCountup() {
        _countupBankedMs = 0
        _countupStartedAt = Date.now()
        countupRunning = true
        _show("countup")
    }

    function pauseCountup() {
        if (mode !== "countup" || !countupRunning) return
        now = Date.now()
        _countupBankedMs = countupMs
        countupRunning = false
    }

    function resumeCountup() {
        if (mode !== "countup" || countupRunning) return
        now = Date.now()
        _countupStartedAt = now
        countupRunning = true
    }

    // Back to 00:00. A running count-up carries on from zero, a paused one
    // stays paused there.
    function resetCountup() {
        if (mode !== "countup") return
        now = Date.now()
        _countupBankedMs = 0
        _countupStartedAt = now
    }

    function hide() {
        active = false
        countupRunning = false
    }

    // Refresh `now` before the mode flips, so the first frame is already
    // right rather than showing the time the overlay was last up.
    function _show(m) {
        now = Date.now()
        mode = m
        active = true
    }

    // ── Pure helpers, shared with the dialog's preview ──────────────────
    function pad2(n) {
        n = Math.floor(n)
        return (n < 10 ? "0" : "") + n
    }

    // Whole seconds to "05:00", or "1:05:00" once there is an hour in it.
    function formatDuration(totalSeconds) {
        const s = Math.max(0, Math.floor(totalSeconds || 0))
        const h = Math.floor(s / 3600)
        const m = Math.floor((s % 3600) / 60)
        if (h > 0) return h + ":" + pad2(m) + ":" + pad2(s % 60)
        return pad2(m) + ":" + pad2(s % 60)
    }

    function clockText(ms, h24, seconds) {
        const d = new Date(ms)
        let h = d.getHours()
        let suffix = ""
        if (!h24) {
            suffix = h >= 12 ? " PM" : " AM"
            h = h % 12
            if (h === 0) h = 12
        }
        let t = (h24 ? pad2(h) : String(h)) + ":" + pad2(d.getMinutes())
        if (seconds) t += ":" + pad2(d.getSeconds())
        return t + suffix
    }

    // The next time the clock reads hour:minute. Built from calendar fields
    // rather than by adding 24 hours, so the day a clock change happens still
    // lands on the right time.
    function untilTarget(hour, minute, fromMs) {
        const n = new Date(fromMs)
        const h = Math.max(0, Math.min(23, Math.floor(hour || 0)))
        const m = Math.max(0, Math.min(59, Math.floor(minute || 0)))
        let t = new Date(n.getFullYear(), n.getMonth(), n.getDate(), h, m, 0, 0)
        if (t.getTime() <= n.getTime())
            t = new Date(n.getFullYear(), n.getMonth(), n.getDate() + 1, h, m, 0, 0)
        return t.getTime()
    }

    // A quarter second, like StageTimer: a one second tick landing either
    // side of a second boundary would skip a second or show one twice. Runs
    // only while something on screen is changing, so a message, a paused
    // count-up or a countdown held at zero costs nothing.
    property Timer _tick: Timer {
        interval: 250
        repeat: true
        running: root.active
                 && (root.mode === "clock"
                     || (root.mode === "countup" && root.countupRunning)
                     || (root.mode === "countdown" && !root.countdownDone))
        onTriggered: root.now = Date.now()
    }
}
