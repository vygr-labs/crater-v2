import QtQuick
import Crater

// Reusable projection scene — the canvas-native render surface shared by
// ProjectionWindow (audience display), OutputWindow (extra outputs) and the
// headless NDI renderer. Drives a two-layer transition between the outgoing
// and incoming live content, with the style (cut / crossfade / fade-through-
// black) and duration resolved per output AND per content type (lyrics,
// scripture, media, logo, clear) via OutputService.
//
// outputKind here is an output id from the OutputService registry —
// "primary", "ndi", "stage", or any dynamically-registered output. Each
// registered output carries its own transition settings on its
// OutputBinding, so a fourth output costs zero changes here.
//
// Why two layers rather than snapshot-and-fade: a snapshot of the outgoing
// video freezes mid-fade, which looks worse than a hard cut for any item
// where motion matters. Keeping the outgoing content live (just fading its
// opacity) lets video → image / image → video / video → video crossfades
// stay in motion through the transition.
//
// SettingsService.reduceMotion is an accessibility override: when true,
// every output collapses to "cut" with 0 ms regardless of the per-output
// settings. Mirrors the standard prefers-reduced-motion semantic.
Item {
    id: scene

    property string outputKind: "primary"

    // Exposes the canvas-native render Item — NDI's grabber and any future
    // capture consumer points at this so they get full-resolution frames
    // regardless of how the scene is letterboxed into its host window.
    property alias renderItem: stage

    // ── Per-output, per-type transition resolution ──────────────────────
    // Each output keeps a style and duration for each content type:
    // lyrics, scripture, media, logo and clear (OutputService
    // transitionStyleFor / transitionDurationFor). Reading
    // OutputService.outputs makes these re-evaluate on outputsChanged, so a
    // change in Settings reaches the next transition. Reduce Motion turns
    // every one of them into a cut.
    function _styleFor(type) {
        OutputService.outputs  // dep
        if (SettingsService.reduceMotion) return "cut"
        return OutputService.transitionStyleFor(outputKind, type)
    }
    function _msFor(type) {
        OutputService.outputs  // dep
        if (SettingsService.reduceMotion) return 0
        return _styleFor(type) === "cut" ? 0 : OutputService.transitionDurationFor(outputKind, type)
    }

    // Which transition type a content kind uses.
    function _typeForKind(kind) {
        switch (kind) {
            case "song":         return "lyrics"
            case "scripture":
            case "strongs":      return "scripture"
            case "image":
            case "video":
            case "pdf":
            case "presentation": return "media"
        }
        return ""
    }

    // Logo and Clear aren't content swaps, they're fades on top of whatever
    // is live, so they read their own types straight off the output.
    readonly property string _logoStyle: _styleFor("logo")
    readonly property int    _logoMs:    _msFor("logo")
    readonly property int    _clearMs:   _msFor("clear")

    // ── Live state mirrors ──────────────────────────────────────────────
    // Only the logo and clear flags are mirrored. The transition controller
    // reads ProjectionService directly inside its handler instead of going
    // through mirrors, because mirrors bound to the same stateChanged signal
    // aren't guaranteed to have updated when the handler runs.
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
        function onOutputModeChanged() { scene._themeRevision++ }
    }
    Connections {
        // Per-output theme-pin changes arrive on the registry's coarse
        // signal — bump in lock-step so both layers re-resolve their
        // themes on the same revision tick.
        target: OutputService
        function onOutputsChanged() { scene._themeRevision++ }
    }

    // ── Canvas size ─────────────────────────────────────────────────────
    // Tracks the shown layer's theme canvas. When the new item has a
    // different canvas size, the letterbox snaps to it as the fade starts
    // and the outgoing layer renders into it (squished during the brief
    // fade, but it's fading out either way). Waiting for the fade, rather
    // than the commit, keeps the old content undistorted while the new one
    // loads.
    readonly property var _canvas: {
        if (shownLayer && shownLayer.theme && shownLayer.theme.tokens
            && shownLayer.theme.tokens.canvas) {
            return shownLayer.theme.tokens.canvas
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
    // Pages and crop and kind move the tag too so verse advances and
    // crop commits both transition.
    property string _lastTag: ""

    // Schedule items don't carry a uniform `id` field — they're keyed by
    // kind-specific natural identifiers (songId, scriptureRef object,
    // mediaPath, mediaId). Reading a hypothetical `item.id` always returns
    // undefined and collapses every item to the same identity, which would
    // debounce real item swaps as "nothing changed". This helper builds a
    // kind-aware identity that actually distinguishes items.
    //
    // Reference: AppState.qml documents the canonical item shape — kind +
    // title + subtitle + pages + (songId | scriptureRef | mediaPath |
    // mediaId) + themeId.
    function _itemIdentity(item, kind) {
        if (!item) return ""
        switch (kind) {
            case "song":
                return "song:" + (item.songId || 0)
            case "scripture": {
                const r = item.scriptureRef
                if (!r) return "scripture:" + (item.title || "")
                return "scripture:"
                     + (r.translationCode || "") + ":"
                     + (r.book || "")            + ":"
                     + (r.chapter || 0)          + ":"
                     + (r.verseStart || 0)       + "-"
                     + (r.verseEnd || 0)
            }
            case "presentation":
                // Without this the default branch below keys a deck by its
                // TITLE, so two decks named the same (a series where every
                // week is "Week 1") would read as one item and the
                // transition controller would debounce the swap between them.
                return "presentation:" + (item.presentationId || 0)
            case "image":
            case "video":
                return kind + ":" + (item.mediaPath || "")
            case "pdf":
                return "pdf:" + (item.mediaId || 0)
        }
        return kind + ":" + (item.title || "")
    }

    // Content fingerprint. Identity alone is not enough to decide "did the
    // live content change?" — two commits can share an identity and still
    // render differently:
    //   • the operator edits a song and re-commits the SAME verse. songId
    //     and page are unchanged; the lyrics are not.
    //   • the operator flips an image's fit mode in the preview fit bar and
    //     presses Enter. mediaPath and page are unchanged; fitMode is not.
    // Both used to be swallowed by the identity-only tag, so the audience
    // kept seeing the pre-edit render until the operator stepped off the
    // slide and back. Serializing the whole item map catches every such
    // field without enumerating them, and keeps a genuinely-redundant
    // re-commit (same item, same page, same everything) debounced — which
    // matters because a fadeBlack transition on a no-op commit would flash
    // the audience screen for no reason.
    function _contentFingerprint(item) {
        if (!item) return ""
        try {
            return JSON.stringify(item)
        } catch (e) {
            // Cyclic or non-serializable map — degrade to identity-only
            // debouncing rather than throwing out of the signal handler.
            return ""
        }
    }

    function _buildTag(item, kind, page, crop) {
        return _identityTag(item, kind, page, crop) + "|" + _contentFingerprint(item)
    }
    // "Which slide is this", ignoring how it's rendered. The title and the
    // page text are part of it because a verse picked in the library carries
    // no verse numbers in its scriptureRef, so _itemIdentity alone gives
    // every verse of a chapter the same identity.
    function _identityTag(item, kind, page, crop) {
        const pages = item && item.pages ? item.pages : []
        const p = pages.length > 0 ? pages[Math.min(page, pages.length - 1)] : null
        return _itemIdentity(item, kind)
             + "|" + kind
             + "|" + page
             + "|" + crop.x + "," + crop.y + "," + crop.width + "," + crop.height
             + "|" + (item ? (item.title || "") : "")
             + "|" + (p ? (p.content || "") : "")
    }

    // ── Layers ──────────────────────────────────────────────────────────
    // Two layers, layerA and layerB, that take turns. New content always
    // goes into the layer that isn't on air, which then fades in ON TOP of
    // the one that is. The outgoing layer is never rewritten, so it keeps
    // painting exactly what the audience was looking at until the fade
    // covers it. (The scene used to copy the outgoing content into a second
    // layer, which rebuilt it from scratch at full opacity and could blink
    // before the fade even started.)
    //
    // currentLayer is the layer holding the newest content. shownLayer
    // (below) is the one the audience is being shown.
    property bool _aIsCurrent: true
    readonly property var currentLayer:  _aIsCurrent ? layerA : layerB
    readonly property var previousLayer: _aIsCurrent ? layerB : layerA
    // The layer the audience is being shown, which only moves to the new
    // layer when its fade actually starts. The letterbox and the no-theme
    // message follow this, so they don't change under the old content
    // while the new one is still loading.
    property bool _aIsShown: true
    readonly property var shownLayer: _aIsShown ? layerA : layerB

    // True from the moment new content is committed until its fade ends,
    // including the wait for the new layer to load.
    property bool _transitioning: false
    // Fixed when a fade starts so a settings change mid-fade can't stretch
    // or cut short the one already running.
    property string _runStyle: "crossfade"
    property int    _runMs: 0
    property string _lastIdentity: ""
    property bool   _skipFadeOut: false

    // Audio is not touched here: it moves to the new layer only when the
    // picture does, in _runTransition, so a video doesn't go quiet while it
    // is still on screen and the next one isn't heard before it is seen.
    function _setContent(layer, item, kind, page, crop) {
        layer.layerItem = item
        layer.layerKind = kind
        layer.layerPage = page
        layer.layerCrop = crop
    }

    function _promoteLayers() {
        const item = ProjectionService.currentItem
        const kind = ProjectionService.contentKind
        const page = ProjectionService.pageIndex
        const crop = ProjectionService.cropRect
        const newTag = _buildTag(item, kind, page, crop)
        if (newTag === _lastTag) return
        const identity  = _identityTag(item, kind, page, crop)
        const sameSlide = identity === _lastIdentity
        _lastTag      = newTag
        _lastIdentity = identity

        // The app re-commits the slide that just went live (a theme sync, a
        // scripture relayout) moments after the go-live itself. Mid-fade
        // that is the same destination, so update what is fading in and let
        // the running fade finish, instead of restarting it as a new one.
        if (sameSlide && _transitioning) {
            _setContent(currentLayer, item, kind, page, crop)
            return
        }

        // The incoming kind picks the type. Going to nothing uses the type
        // of what is leaving.
        const type = _typeForKind(kind) || _typeForKind(currentLayer.layerKind) || "lyrics"
        let style = _styleFor(type)
        // The same slide re-rendered (a theme change, a relayout, an edit to
        // the live song) never fades through black, which would flash the
        // screen for what is a small change.
        if (sameSlide && style === "fadeBlack") style = "crossfade"
        _runStyle = style
        _runMs    = style === "cut" ? 0 : _msFor(type)

        transitionParallel.stop()
        transitionSequence.stop()

        // Mid-transition there are two layers on screen and only two layers,
        // so one of them has to take the new content. Replace whichever
        // shows less of the picture: the incoming layer on top contributes
        // its opacity, the outgoing one underneath what shows through it.
        // The visible jump is then never more than the smaller share.
        const inShare  = currentLayer.opacity
        const outShare = previousLayer.opacity * (1 - currentLayer.opacity)
        if (_transitioning && inShare < outShare) {
            // Still mostly the old content: keep it as the outgoing layer
            // and swap what is fading in. The fade carries on from where it
            // got to. The old content keeps the sound until then.
            _setContent(currentLayer, item, kind, page, crop)
            currentLayer.audioEnabled  = false
            previousLayer.audioEnabled = true
        } else {
            // Nothing in flight, or the incoming content is already most of
            // the picture: that becomes the outgoing layer at full opacity.
            const out = currentLayer
            const inc = previousLayer
            out.opacity = 1
            out.z = 0
            inc.opacity = 0
            inc.z = 1
            inc.audioEnabled = false
            _setContent(inc, item, kind, page, crop)
            _aIsCurrent = !_aIsCurrent
            _aIsShown   = !_aIsCurrent
        }
        _transitioning = true
        // One deadline per wait. A stream of re-commits while media loads
        // must not keep pushing it back and hold the old content up.
        if (!readyPoll.running) _readyDeadline = Date.now() + _readyTimeoutMs
        readyPoll.restart()
    }

    // ── Waiting for the new layer ───────────────────────────────────────
    // The fade starts once the incoming layer reports everything loaded, or
    // after _readyTimeoutMs so a broken file can't hold the screen. Polled
    // rather than signalled: readiness is spread over every picture and
    // video in the layer's tree, and a 16 ms poll for a few frames is
    // cheaper than wiring each one up. Always at least one tick, so text
    // fitting (done on completion) has settled first.
    readonly property int _readyTimeoutMs: 600
    property real _readyDeadline: 0
    // Videos that never produced a frame within the timeout (a missing file,
    // a codec the player can't open). Not waited for again this session.
    property var _stalledUrls: ({})
    Timer {
        id: readyPoll
        interval: 16
        repeat: true
        onTriggered: {
            if (!scene.currentLayer.isReady(scene._stalledUrls)) {
                if (Date.now() < scene._readyDeadline) return
                const stalled = scene.currentLayer.pendingUrls()
                for (let i = 0; i < stalled.length; ++i) scene._stalledUrls[stalled[i]] = true
            }
            stop()
            scene._runTransition()
        }
    }

    function _runTransition() {
        _aIsShown = _aIsCurrent
        previousLayer.audioEnabled = false
        currentLayer.audioEnabled  = true
        // Interrupted in the black half of a fade through black: the old
        // content is already gone, so skip straight to fading in.
        _skipFadeOut = previousLayer.opacity <= 0.001
        if (_runStyle === "cut" || _runMs <= 0) {
            currentLayer.opacity = 1
            _finishTransition()
            return
        }
        if (_runStyle === "fadeBlack") transitionSequence.restart()
        else                           transitionParallel.restart()
    }

    // Empty the outgoing layer once it is fully covered. Until this existed
    // the previous layer kept its content at opacity 0 until the NEXT
    // transition, so a video that went off air kept its MediaPlaybackService
    // subscription and carried on decoding invisibly (and a later go-live of
    // the same file joined a player that had kept running).
    function _finishTransition() {
        const out = previousLayer
        out.opacity = 0
        out.audioEnabled = false
        out.layerItem = ({})
        out.layerKind = ""
        out.layerPage = 0
        out.layerCrop = Qt.rect(0, 0, 1, 1)
        _transitioning = false
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
        const item = ProjectionService.currentItem
        const kind = ProjectionService.contentKind
        const page = ProjectionService.pageIndex
        const crop = ProjectionService.cropRect
        _lastTag      = _buildTag(item, kind, page, crop)
        _lastIdentity = _identityTag(item, kind, page, crop)
        _setContent(layerA, item, kind, page, crop)
        layerA.audioEnabled = true
        layerA.opacity = 1
        layerA.z = 1
        layerB.opacity = 0
        layerB.z = 0
        _aIsCurrent = true
        _aIsShown   = true
    }

    // ── Animations ──────────────────────────────────────────────────────
    // Crossfade: the incoming layer fades in on top while the outgoing one
    // fades out underneath, on mirrored curves. The incoming rises early
    // (OutQuad) and the outgoing holds late (InQuad), so halfway through
    // both are at 75% and the picture stays solid. Fading both on the same
    // curve, as before, let a quarter of the black window show through
    // mid-fade, so even two slides on the same background dipped. Fading
    // the outgoing at all (rather than leaving it at full under the
    // incoming) stops letterboxed media from popping off at the end.
    //
    // The targets are bound to currentLayer / previousLayer, which only
    // change in _promoteLayers after both animations are stopped.
    ParallelAnimation {
        id: transitionParallel
        onFinished: scene._finishTransition()
        NumberAnimation {
            target: scene.currentLayer; property: "opacity"; to: 1
            duration: scene._runMs; easing.type: Easing.OutQuad
        }
        NumberAnimation {
            target: scene.previousLayer; property: "opacity"; to: 0
            duration: scene._runMs; easing.type: Easing.InQuad
        }
    }
    // Fade through black: the outgoing finishes fading before the incoming
    // starts, half the duration each, so the whole thing still takes the
    // set duration.
    SequentialAnimation {
        id: transitionSequence
        onFinished: scene._finishTransition()
        NumberAnimation {
            target: scene.previousLayer; property: "opacity"; to: 0
            duration: scene._skipFadeOut ? 1 : Math.max(1, scene._runMs / 2)
            easing.type: Easing.InOutCubic
        }
        NumberAnimation {
            target: scene.currentLayer; property: "opacity"; to: 1
            duration: Math.max(1, scene._runMs / 2); easing.type: Easing.InOutCubic
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
            //
            // The logo's own type sets the fade. With fade through black the
            // content goes out first and the logo comes in after it (and the
            // other way round when the logo goes off), so whichever side is
            // fading IN waits out the first half.
            Item {
                id: contentLayer
                anchors.fill: parent
                opacity: scene._showLogo ? 0 : 1
                Behavior on opacity {
                    id: contentLogoFade
                    SequentialAnimation {
                        PauseAnimation {
                            duration: (scene._logoStyle === "fadeBlack" && contentLogoFade.targetValue > 0.5)
                                      ? scene._logoMs / 2 : 0
                        }
                        NumberAnimation {
                            duration: scene._logoStyle === "fadeBlack" ? scene._logoMs / 2 : scene._logoMs
                            easing.type: Easing.InOutCubic
                        }
                    }
                }

                // Both layers are full stage and swap roles each transition.
                // z and opacity are set by the transition controller.
                ProjectionContentLayer {
                    id: layerA
                    anchors.fill: parent
                    outputKind:    scene.outputKind
                    themeRevision: scene._themeRevision
                    passiveFadeMs: scene._clearMs
                    opacity:       1
                }
                ProjectionContentLayer {
                    id: layerB
                    anchors.fill: parent
                    outputKind:    scene.outputKind
                    themeRevision: scene._themeRevision
                    passiveFadeMs: scene._clearMs
                    opacity:       0
                }
            }

            // ── No-theme fallback ───────────────────────────────────────
            // Reads from the shown layer's resolved theme — once a fade
            // starts the message describes the destination, not the
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
                      && (shownLayer.layerKind === "song" || shownLayer.layerKind === "scripture"
                          || shownLayer.layerKind === "strongs")
                      && (!shownLayer.theme || (shownLayer.theme.id || 0) === 0)
                text: qsTr("Default %1 theme has not been set").arg(shownLayer.layerKind)
                           .toUpperCase()
                color: "#ffffff"
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                font.family: Theme.font.family
                font.pixelSize: 72
                font.weight: Theme.font.weightBold
            }

            // ── Logo overlay ────────────────────────────────────────────
            // Sits above the content stack. Its fade uses the output's Logo
            // transition (see contentLayer above for the fade through black
            // ordering). active gates the video decoder; opacity drives
            // the fade so the decoder doesn't bounce on every fade tick.
            //
            // Logo visibility is independent of isClear — clearing only
            // hides text, so a logo toggled on stays visible through a
            // clear.
            LogoView {
                id: logoView
                anchors.fill: parent
                active: scene._showLogo
                // Wait for a picture logo to finish decoding before fading
                // in, so the audience never sees the black matte first.
                opacity: (scene._showLogo && logoView.ready) ? 1.0 : 0.0
                Behavior on opacity {
                    id: logoFade
                    SequentialAnimation {
                        PauseAnimation {
                            duration: (scene._logoStyle === "fadeBlack" && logoFade.targetValue > 0.5)
                                      ? scene._logoMs / 2 : 0
                        }
                        NumberAnimation {
                            duration: scene._logoStyle === "fadeBlack" ? scene._logoMs / 2 : scene._logoMs
                            easing.type: Easing.InOutCubic
                        }
                    }
                }
            }
        }
    }
}
