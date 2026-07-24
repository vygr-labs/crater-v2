pragma Singleton

import QtQuick

// LiveMessages — single source of truth for the live on-screen overlay:
// countdown / count-up / wall-clock timers and free-text messages pushed to
// the projection (audience + NDI) on the fly.
//
// Like AppState this is transient, QML-only state (ARCHITECTURE.md §9): no
// persistence, no DB, no IPC. The overlay is ephemeral by nature — a message
// or a pre-service countdown belongs to the live moment, not to saved data.
// (A future SettingsService slot can persist message presets / the operator's
// preferred style, mirroring how scriptureInputMode et al. graduated from
// session-only to persisted — see AppState.qml.)
//
// The overlay is deliberately ORTHOGONAL to ProjectionService.currentItem:
// it survives page changes, go-live, clear and the logo toggle, exactly like
// the logo layer. So it lives here, not on ProjectionService (whose concern is
// the single live *item* snapshot). LiveOverlayLayer.qml — mounted inside
// ProjectionScene's canvas stage — binds to this singleton and renders on the
// audience window AND the NDI canvas from one instance each.
//
// This is a QtObject singleton, so (like AppState) it can hold no child
// objects — no Timer here. The per-second ticking that advances a countdown /
// clock lives in LiveOverlayLayer, which reads these config properties and
// recomputes the displayed value against its own clock. That keeps this file
// pure config + control functions.
QtObject {
    id: ctl

    // ── Mode ────────────────────────────────────────────────────────────
    // "" = nothing shown (overlay hidden). Otherwise one of the four kinds.
    // active is the single flag every consumer (the render layer, the TopBar
    // button highlight, the dialog status) reads to know the overlay is up.
    property string mode: ""   // "" | "countdown" | "countup" | "clock" | "message"
    readonly property bool active: mode !== ""

    // ── Message ─────────────────────────────────────────────────────────
    property string message: ""

    // A few built-in message suggestions. Static (no persistence needed) —
    // the operator can also type any custom text. Kept short so the dialog's
    // preset row stays tidy.
    readonly property var presets: [
        qsTr("Please silence your phones"),
        qsTr("The service will begin shortly"),
        qsTr("Please stand"),
        qsTr("Please be seated"),
        qsTr("Welcome"),
        qsTr("Parents, you're needed in the nursery")
    ]

    // ── Countdown ───────────────────────────────────────────────────────
    // Stored as an absolute wall-clock target (epoch ms). The render layer
    // computes remaining = targetMs − now each tick, so both output copies
    // agree without a shared ticker. `caption` is an optional line shown
    // under the digits (e.g. "Service begins"). countdownEndMode decides what
    // shows once it reaches zero.
    property double countdownTargetMs: 0
    property string caption: ""
    property string countdownEndMode: "hold"      // "hold" (stay at 00:00) | "message"
    property string countdownEndMessage: ""

    // ── Count-up (stopwatch) ────────────────────────────────────────────
    // startMs = epoch of the last resume; accumMs = elapsed frozen at the
    // last pause. elapsed = accumMs + (running ? now − startMs : 0). The
    // render layer computes it against its own clock (it can't call a
    // now()-reading helper reactively), so these three are the whole state.
    property double countupStartMs: 0
    property double countupAccumMs: 0
    property bool   countupRunning: false

    // ── Clock ───────────────────────────────────────────────────────────
    property bool clock24h: false
    property bool clockShowSeconds: false

    // ── Placement ───────────────────────────────────────────────────────
    // Where the text block sits on the canvas. The rest of the look (text
    // fill incl. gradient, effect, background) is the per-type theme resolved
    // by LiveOverlayStyles — see [[live-timers-worktree]] / OverlaySection.
    property string position: "center"     // "top" | "center" | "bottom"

    // ── Control functions ───────────────────────────────────────────────
    // Each sets the relevant config and flips `mode`, which the render layer
    // reacts to. Callers are operator gestures (dialog buttons), so reading
    // the wall clock here is safe (real runtime, unlike a workflow sandbox).

    function showMessage(text) {
        message = (text === undefined || text === null) ? "" : String(text)
        mode = "message"
    }

    function showClock() {
        mode = "clock"
    }

    // Count down a duration (in whole seconds) from now.
    function startCountdownDuration(totalSeconds, captionText) {
        var secs = Math.max(0, Math.floor(totalSeconds || 0))
        countdownTargetMs = Date.now() + secs * 1000
        caption = captionText || ""
        mode = "countdown"
    }

    // Count down to a wall-clock time today (hour 0-23, minute 0-59). If that
    // time has already passed today, target the same time tomorrow so a
    // "10:30" set at 10:45 counts ~23h50m rather than showing 00:00 forever.
    function startCountdownUntil(hour, minute, captionText) {
        var now = new Date()
        var target = new Date(now.getFullYear(), now.getMonth(), now.getDate(),
                              Math.max(0, Math.min(23, hour || 0)),
                              Math.max(0, Math.min(59, minute || 0)), 0, 0)
        if (target.getTime() <= now.getTime())
            target = new Date(target.getTime() + 24 * 3600 * 1000)
        countdownTargetMs = target.getTime()
        caption = captionText || ""
        mode = "countdown"
    }

    function startCountup() {
        countupStartMs = Date.now()
        countupAccumMs = 0
        countupRunning = true
        caption = ""
        mode = "countup"
    }

    function pauseCountup() {
        if (mode !== "countup" || !countupRunning) return
        countupAccumMs = countupAccumMs + (Date.now() - countupStartMs)
        countupRunning = false
    }

    function resumeCountup() {
        if (mode !== "countup" || countupRunning) return
        countupStartMs = Date.now()
        countupRunning = true
    }

    function resetCountup() {
        countupStartMs = Date.now()
        countupAccumMs = 0
        // Running state is left as-is: reset-while-running restarts from 0 and
        // keeps counting; reset-while-paused parks it at 0.
    }

    function hide() {
        mode = ""
    }

    // ── Pure format helpers ─────────────────────────────────────────────
    // Shared by LiveOverlayLayer (and any preview) so every surface formats
    // identically. Kept here (not in the layer) because they're pure — they
    // take a value, not the wall clock.
    function pad2(n) {
        n = Math.floor(n)
        return (n < 10 ? "0" : "") + n
    }

    // Whole seconds → "M:SS" / "MM:SS", or "H:MM:SS" once an hour is on the
    // clock. Negative clamps to 0 (a finished countdown reads 00:00).
    function fmtDuration(totalSeconds) {
        var s = Math.max(0, Math.floor(totalSeconds || 0))
        var h = Math.floor(s / 3600)
        var m = Math.floor((s % 3600) / 60)
        var sec = s % 60
        if (h > 0) return h + ":" + pad2(m) + ":" + pad2(sec)
        return pad2(m) + ":" + pad2(sec)
    }
}
