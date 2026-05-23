import QtQuick
import Crater

// Reusable projection scene — the canvas-native render surface shared by
// ProjectionWindow (audience display) and NdiCanvas (NDI broadcast in dual
// output mode). Drives a two-layer transition between the previous and
// current live content, with the style (cut / crossfade / fade-through-
// black) and duration resolved per output via SettingsService.
//
// outputKind selects which per-output settings the scene honors:
//   "primary" → transitionStyleForPrimary + transitionDurationMsForPrimary
//   "ndi"     → transitionStyleForNdi     + transitionDurationMsForNdi
//                (when outputMode==="dual"; in single mode NDI inherits
//                primary's scene wholesale, so these prefs aren't reached)
//   "stage"   → reserved for v1.1 multi-output stage monitor
//
// The same component instantiates in both consumer windows; only the
// outputKind property differs. That keeps the rendering source-of-truth
// singular even as the two outputs can independently set their own theme
// pin AND their own transition feel — e.g. operator can have Primary
// crossfade slowly for the audience and NDI cut instantly for stream
// production.
//
// Why two layers (current + previous) rather than snapshot-and-fade: a
// snapshot of the outgoing video freezes mid-fade, which looks worse than
// a hard cut for any item where motion matters. Keeping the outgoing
// content live (just fading its opacity) lets video → image / image →
// video / video → video crossfades stay in motion through the transition.
//
// SettingsService.reduceMotion is an accessibility override: when true,
// every output collapses to "cut" with 0 ms regardless of the per-output
// pins. Mirrors the standard prefers-reduced-motion semantic.
Item {
    id: scene

    property string outputKind: "primary"

    // Exposes the canvas-native render Item — NDI's grabber and any future
    // capture consumer points at this so they get full-resolution frames
    // regardless of how the scene is letterboxed into its host window.
    property alias renderItem: stage

    // ── Per-output transition resolution ────────────────────────────────
    // Reads style + duration from SettingsService based on this scene's
    // outputKind. reduceMotion overrides both to "cut" / 0 ms.
    readonly property string _outStyle: {
        switch (outputKind) {
            case "ndi":   return SettingsService.transitionStyleForNdi
            case "stage": return SettingsService.transitionStyleForStage
            default:      return SettingsService.transitionStyleForPrimary
        }
    }
    readonly property int _outMs: {
        switch (outputKind) {
            case "ndi":   return SettingsService.transitionDurationMsForNdi
            case "stage": return SettingsService.transitionDurationMsForStage
            default:      return SettingsService.transitionDurationMsForPrimary
        }
    }
    readonly property string _style: SettingsService.reduceMotion ? "cut" : _outStyle
    readonly property int    _ms:    SettingsService.reduceMotion ? 0     : _outMs

    // Duration used by passive (non-transition) fades inside the scene —
    // logo show/hide AND the per-text-node clear fade. "cut" coerces to 0
    // so picking that style genuinely makes the whole projection feel
    // instant; any fade style inherits the per-output content duration so
    // the scene feels coherent end to end.
    readonly property int _passiveMs: _style === "cut" ? 0 : _ms

    // ── Live state mirrors ──────────────────────────────────────────────
    // Bound to ProjectionService Q_PROPERTYs; the transition controller
    // reads these when promoting layers but the layers themselves do NOT
    // bind to them directly (the scene is the single mediator that copies
    // values into the current layer with each animation kickoff).
    readonly property var    _liveItem: ProjectionService.currentItem
    readonly property string _liveKind: ProjectionService.contentKind
    readonly property int    _livePage: ProjectionService.pageIndex
    readonly property rect   _liveCrop: ProjectionService.cropRect
    readonly property bool   _showLogo: ProjectionService.showLogo
    readonly property bool   _isClear:  ProjectionService.isClear

    // ── Theme-revision dependency forwarded to the layers ──────────────
    // Each layer's `theme` is reactive on this counter; we bump it for any
    // external signal that could change resolved themes (defaults, theme
    // edits, per-output pins). Forwarded to both layers in lock-step so a
    // theme edit during a transition takes effect on the new content as
    // soon as the bump propagates — no stale theme on the incoming layer.
    property int _themeRevision: 0
    Connections {
        target: ThemeService
        function onDefaultsChanged()  { scene._themeRevision++ }
        function onAllThemesChanged() { scene._themeRevision++ }
    }
    Connections {
        target: SettingsService
        function onOutputModeChanged()         { scene._themeRevision++ }
        function onThemeIdForPrimaryChanged()  { scene._themeRevision++ }
        function onThemeIdForNdiChanged()      { scene._themeRevision++ }
        function onThemeIdForStageChanged()    { scene._themeRevision++ }
    }

    // ── Canvas size ─────────────────────────────────────────────────────
    // Tracks the CURRENT layer's theme canvas — never the previous one.
    // If the new item has a different canvas size, the letterbox snaps to
    // the new size and the outgoing layer renders into it (it'll be
    // squished/stretched during the brief fade, but it's at opacity → 0
    // either way so the visual impact is negligible). Tracking the
    // current layer matches "transitions describe the destination" UX.
    readonly property var _canvas: {
        if (currentLayer && currentLayer.theme && currentLayer.theme.tokens
            && currentLayer.theme.tokens.canvas) {
            return currentLayer.theme.tokens.canvas
        }
        return { width: 1920, height: 1080 }
    }

    // ── Transition controller ──────────────────────────────────────────
    // ProjectionService.stateChanged() fires for many reasons (goLive,
    // clear, page change, logo toggle, …). Only item/kind/page/crop
    // changes should kick a transition — logo / clear toggles have their
    // own fades. We build a compound tag and skip when only the
    // non-trigger axes moved.
    //
    // Using item.id as the identity key means re-Go-Live of the same
    // schedule item won't reanimate even if the operator clicked it twice;
    // that matches operator intent ("nothing changed; don't flicker").
    // Pages and crop and kind move the tag too so verse advances and
    // crop commits both transition.
    property string _lastTag: ""

    function _buildTag(item, kind, page, crop) {
        const id = (item && item.id !== undefined) ? item.id : 0
        return [id, kind, page, crop.x, crop.y, crop.width, crop.height].join("|")
    }

    function _promoteLayers() {
        const newTag = scene._buildTag(scene._liveItem, scene._liveKind,
                                       scene._livePage, scene._liveCrop)
        if (newTag === scene._lastTag) return
        scene._lastTag = newTag

        // Stop any in-flight animations so opacities aren't being driven
        // by a stale animation while a new one starts. If the operator
        // hits PageDown three times in 200 ms each press cleanly takes
        // over from the previous fade rather than queueing.
        transitionParallel.stop()
        transitionSequence.stop()

        // Snapshot the old "current" content into "previous". This is the
        // moment that breaks the layer's bindings from the live state —
        // both layers now hold imperative snapshots; only the scene mutates
        // them on the next transition.
        previousLayer.layerItem    = currentLayer.layerItem
        previousLayer.layerKind    = currentLayer.layerKind
        previousLayer.layerPage    = currentLayer.layerPage
        previousLayer.layerCrop    = currentLayer.layerCrop
        previousLayer.audioEnabled = false

        // Promote new live state into the current layer.
        currentLayer.layerItem    = scene._liveItem
        currentLayer.layerKind    = scene._liveKind
        currentLayer.layerPage    = scene._livePage
        currentLayer.layerCrop    = scene._liveCrop
        currentLayer.audioEnabled = true

        // Pick the animation. With cut OR 0 ms duration, hard-set opacities
        // and skip the animation entirely — that avoids a 1-frame mid-value
        // flicker that a 0-duration NumberAnimation can produce on some
        // QRhi backends.
        if (scene._style === "cut" || scene._ms <= 0) {
            previousLayer.opacity = 0
            currentLayer.opacity  = 1
        } else {
            // Reset opacities to their start values BEFORE restart() so the
            // animation interpolates from a known state regardless of where
            // the previous (interrupted) animation left them.
            previousLayer.opacity = 1
            currentLayer.opacity  = 0
            if (scene._style === "fadeBlack") {
                transitionSequence.restart()
            } else {
                transitionParallel.restart()
            }
        }
    }

    Connections {
        target: ProjectionService
        function onStateChanged() { scene._promoteLayers() }
    }

    Component.onCompleted: {
        // Establish baseline tag without animating. If projection already
        // has live content at scene-construction time (e.g. scene re-opens
        // mid-service), the existing item shows immediately — no spurious
        // fade-in from nothing.
        scene._lastTag = scene._buildTag(scene._liveItem, scene._liveKind,
                                         scene._livePage, scene._liveCrop)
        currentLayer.layerItem    = scene._liveItem
        currentLayer.layerKind    = scene._liveKind
        currentLayer.layerPage    = scene._livePage
        currentLayer.layerCrop    = scene._liveCrop
        currentLayer.audioEnabled = true
        currentLayer.opacity      = 1
        previousLayer.opacity     = 0
    }

    // ── Animations ──────────────────────────────────────────────────────
    // Targeted by name (target/property) rather than `on opacity` Behaviors
    // because the controller needs explicit start/stop control and a single
    // animation that can be reused across many transitions.
    ParallelAnimation {
        id: transitionParallel
        NumberAnimation {
            target: previousLayer; property: "opacity"; to: 0
            duration: scene._ms; easing.type: Easing.InOutCubic
        }
        NumberAnimation {
            target: currentLayer; property: "opacity"; to: 1
            duration: scene._ms; easing.type: Easing.InOutCubic
        }
    }
    // Fade-through-black: outgoing finishes its fade BEFORE incoming
    // starts. Each phase gets half the total duration so the overall
    // transition still matches _ms (so the operator's mental model —
    // "duration is how long the whole thing takes" — holds across styles).
    // Math.max(1, …) avoids a 0-duration phase when _ms is very small.
    SequentialAnimation {
        id: transitionSequence
        NumberAnimation {
            target: previousLayer; property: "opacity"; to: 0
            duration: Math.max(1, scene._ms / 2); easing.type: Easing.InOutCubic
        }
        NumberAnimation {
            target: currentLayer; property: "opacity"; to: 1
            duration: Math.max(1, scene._ms / 2); easing.type: Easing.InOutCubic
        }
    }

    // ── Letterbox: the visible canvas container ─────────────────────────
    // Scales to fit the host while preserving the canvas aspect ratio.
    // For NdiCanvas (host sized 1920×1080) this collapses to a 1:1 scale;
    // for ProjectionWindow it shrinks the canvas into whatever windowed
    // thumbnail / fullscreen geometry is in play.
    Item {
        id: letterbox
        anchors.centerIn: parent
        readonly property real _scale: Math.min(parent.width  / scene._canvas.width,
                                                parent.height / scene._canvas.height)
        width:  scene._canvas.width  * _scale
        height: scene._canvas.height * _scale
        clip: true

        // ── Stage: the canvas-native render surface ─────────────────────
        // Always sized to theme canvas dimensions (typically 1920×1080).
        // scale: letterbox._scale shrinks/grows the visual rendering to
        // fit the letterbox without changing the logical size — children
        // continue to position themselves at canvas-native pixel
        // coordinates via percent-of-stage.{width,height}. grabToImage on
        // this Item returns canvas-native pixels regardless of how large
        // the actual display window is.
        Item {
            id: stage
            width:  scene._canvas.width
            height: scene._canvas.height
            transformOrigin: Item.TopLeft
            scale: letterbox._scale

            // ── Content layers ───────────────────────────────────────────
            // Wrapped in contentLayer so the logo toggle fades the entire
            // content stack as a single unit — preserving the pre-extraction
            // behavior where toggling the logo dimmed everything beneath it,
            // not just the active node graph.
            Item {
                id: contentLayer
                anchors.fill: parent
                opacity: scene._showLogo ? 0 : 1
                Behavior on opacity {
                    NumberAnimation {
                        duration: scene._passiveMs
                        easing.type: Easing.InOutCubic
                    }
                }

                // Both layers are full-stage; opacity is driven imperatively
                // by the transition controller. previousLayer renders below
                // currentLayer in QML z-order (declaration order); for
                // crossfade that's irrelevant, but for fadeBlack the
                // order means the previous layer is on top as it fades to
                // 0 (so the brief black moment is naturally produced by
                // both being at 0).
                ProjectionContentLayer {
                    id: previousLayer
                    anchors.fill: parent
                    outputKind:    scene.outputKind
                    themeRevision: scene._themeRevision
                    passiveFadeMs: scene._passiveMs
                    opacity:       0
                }
                ProjectionContentLayer {
                    id: currentLayer
                    anchors.fill: parent
                    outputKind:    scene.outputKind
                    themeRevision: scene._themeRevision
                    passiveFadeMs: scene._passiveMs
                    opacity:       1
                }
            }

            // ── No-theme fallback ───────────────────────────────────────
            // Reads from the CURRENT layer's resolved theme — during a
            // transition the message describes the destination, not the
            // outgoing one. Without this, the projection would be silently
            // black when an operator goes live on a song/scripture before
            // setting a default theme for that kind. Mirrors Electron's
            // NoThemeError.
            Text {
                id: noThemeText
                anchors.centerIn: parent
                anchors.margins: 40
                width: parent.width - 80
                visible: !scene._isClear
                      && !scene._showLogo
                      && (currentLayer.layerKind === "song" || currentLayer.layerKind === "scripture")
                      && (!currentLayer.theme || (currentLayer.theme.id || 0) === 0)
                text: qsTr("Default %1 theme has not been set").arg(currentLayer.layerKind)
                           .toUpperCase()
                color: "#ffffff"
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                font.family: Theme.font.family
                font.pixelSize: 72
                font.weight: Theme.font.weightBold
            }

            // ── Logo overlay ────────────────────────────────────────────
            // Sits above the content stack. Its own opacity fade uses the
            // scene's passive duration so a cut style makes the logo toggle
            // instant too. active gates the video decoder; opacity drives
            // the fade so the decoder doesn't bounce on every fade tick.
            //
            // Logo visibility is independent of isClear — clearing only
            // hides text, so a logo toggled on stays visible through a
            // clear.
            LogoView {
                id: logoView
                anchors.fill: parent
                active: scene._showLogo
                opacity: scene._showLogo ? 1.0 : 0.0
                Behavior on opacity {
                    NumberAnimation {
                        duration: scene._passiveMs
                        easing.type: Easing.InOutCubic
                    }
                }
            }
        }
    }
}
