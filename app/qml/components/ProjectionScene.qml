import QtQuick
import Crater

// Reusable projection scene — the canvas-native render surface shared by
// ProjectionWindow (audience display) and NdiCanvas (NDI broadcast in dual
// output mode). Letterboxes a theme canvas into the parent, runs the
// A/B crossfade between successive ProjectionService snapshots, and
// exposes the inner `stage` Item via `renderItem` so external consumers
// (NDI grabber today; future recording / multi-output sinks) can pull
// canvas-resolution frames regardless of how the scene is letterboxed
// into its host window.
//
// outputKind selects which per-output overrides the scene honors:
//   "primary" → SettingsService.themeIdForPrimary / transitionFor[Ms]Primary
//   "ndi"     → themeIdForNdi / transitionFor[Ms]Ndi when outputMode==="dual",
//               otherwise falls back to the primary slots (so a single-mode
//               NDI scene matches what the projection window shows)
//   "stage"   → reserved for v1.1 multi-output stage monitor; same fallback
//
// The same component instantiates in both consumer windows; only the
// outputKind property differs. That keeps the rendering source-of-truth
// singular even as the two outputs can render different themes and crossfade
// at different speeds.
Item {
    id: scene

    property string outputKind: "primary"

    // Canvas-native render surface. NDI's grabber points at this so it
    // gets canvas-resolution pixels (1920×1080 by default) regardless of
    // how big the host window happens to be.
    property alias renderItem: stage

    // ── Reactive bindings to ProjectionService (the live state) ─────────
    // These drive change detection — when any of them updates,
    // Connections.onStateChanged fires below and the A/B swap kicks in.
    readonly property var    _item    : ProjectionService.currentItem
    readonly property string _kind    : ProjectionService.contentKind
    readonly property int    _page    : ProjectionService.pageIndex
    readonly property bool   _isClear : ProjectionService.isClear
    readonly property bool   _showLogo: ProjectionService.showLogo
    readonly property rect   _cropRect: ProjectionService.cropRect

    // ── Per-output transition resolution ────────────────────────────────
    // Maps outputKind (× outputMode) onto the SettingsService slot pair
    // that this scene's animations consult. Same dispatch shape as theme
    // resolution above — single mode collapses every output to Primary's
    // slot so NDI / Stage inherit the audience-facing pacing.
    //
    // reduceMotion is the global override: whenever the operator has
    // ticked it on, every output's effective duration is 0 (i.e. cut),
    // regardless of its per-output kind. The accessibility lever shouldn't
    // be defeatable per-output.
    readonly property string _transitionKind: {
        if (SettingsService.reduceMotion) return "cut"
        const dual = SettingsService.outputMode === "dual"
        if (dual && outputKind === "ndi")   return SettingsService.transitionForNdi
        if (dual && outputKind === "stage") return SettingsService.transitionForStage
        return SettingsService.transitionForPrimary
    }
    readonly property int _transMs: {
        if (SettingsService.reduceMotion) return 0
        if (_transitionKind === "cut")    return 0
        const dual = SettingsService.outputMode === "dual"
        if (dual && outputKind === "ndi")   return SettingsService.transitionMsForNdi
        if (dual && outputKind === "stage") return SettingsService.transitionMsForStage
        return SettingsService.transitionMsForPrimary
    }

    // ── Theme resolution (used for stage canvas dimensions only) ────────
    // The two layers each resolve their OWN theme from their held item —
    // this scene-level _theme exists solely to size the outer canvas.
    // Theme-canvas mismatch between two simultaneously-held items is an
    // edge case (most projects share a 1920×1080 canvas); we accept the
    // brief letterbox shift over the duration of a transition.
    property int _themeRevision: 0
    readonly property var _theme: {
        _themeRevision
        return AppState.resolveItemTheme(_item, outputKind)
    }

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

    readonly property var _tokens : _theme && _theme.tokens ? _theme.tokens : ({})
    readonly property var _canvas : _tokens.canvas || ({ width: 1920, height: 1080 })

    // ── A/B crossfade state ─────────────────────────────────────────────
    // Each layer holds a frozen snapshot of one ProjectionService state.
    // When ProjectionService changes, the currently INACTIVE layer is
    // overwritten with the new state and _liveLayer flips — the opacity
    // Behaviors on the two LiveContent instances then animate the
    // crossfade. After an outgoing layer fully fades to 0, its held state
    // is wiped so video decoders / async images / PDF rasterisers tear
    // down. Without that wipe, the back layer would keep its decoder
    // alive between transitions for no benefit.
    property string _liveLayer: "A"

    property var    _heldItemA : ({})
    property string _heldKindA : ""
    property int    _heldPageA : 0
    property bool   _heldClearA: false
    property rect   _heldCropA : Qt.rect(0, 0, 1, 1)

    property var    _heldItemB : ({})
    property string _heldKindB : ""
    property int    _heldPageB : 0
    property bool   _heldClearB: false
    property rect   _heldCropB : Qt.rect(0, 0, 1, 1)

    function _writeLayer(which, item, kind, page, isClear, cropRect) {
        if (which === "A") {
            _heldItemA  = item
            _heldKindA  = kind
            _heldPageA  = page
            _heldClearA = isClear
            _heldCropA  = cropRect
        } else {
            _heldItemB  = item
            _heldKindB  = kind
            _heldPageB  = page
            _heldClearB = isClear
            _heldCropB  = cropRect
        }
    }

    function _resetLayer(which) {
        // Empty kind gates every render branch off inside LiveContent —
        // MediaMonitor visible:false, Image source:"", Repeater model:[].
        // That's how the now-faded-out layer releases its resources.
        if (which === "A") {
            _heldItemA  = ({})
            _heldKindA  = ""
            _heldPageA  = 0
            _heldClearA = false
            _heldCropA  = Qt.rect(0, 0, 1, 1)
        } else {
            _heldItemB  = ({})
            _heldKindB  = ""
            _heldPageB  = 0
            _heldClearB = false
            _heldCropB  = Qt.rect(0, 0, 1, 1)
        }
    }

    function _stageTransition() {
        // Copy current live state into the INACTIVE layer, then flip which
        // layer is live. Opacity Behaviors on both LiveContent instances
        // do the rest — outgoing animates 1→0, incoming animates 0→1.
        // Cut transition collapses to duration 0, so the layers swap
        // instantly with no in-between frame.
        const incoming = _liveLayer === "A" ? "B" : "A"
        _writeLayer(incoming, _item, _kind, _page, _isClear, _cropRect)
        _liveLayer = incoming
    }

    Component.onCompleted: {
        // Seed both layers with the current ProjectionService snapshot so
        // the first stateChanged after instantiation doesn't fade in from
        // a stale "empty A" if the operator was already live when the scene
        // was rebuilt (e.g. they switched output displays mid-service).
        _writeLayer("A", _item, _kind, _page, _isClear, _cropRect)
        _writeLayer("B", _item, _kind, _page, _isClear, _cropRect)
    }

    Connections {
        target: ProjectionService
        function onStateChanged() { scene._stageTransition() }
    }

    // ── Letterbox: the *visible* canvas container ───────────────────────
    Item {
        id: letterbox
        anchors.centerIn: parent
        readonly property real _scale: Math.min(parent.width  / scene._canvas.width,
                                                parent.height / scene._canvas.height)
        width:  scene._canvas.width  * _scale
        height: scene._canvas.height * _scale
        clip: true

        // ── Stage: the *canvas-native* render surface ───────────────────
        // Always sized to theme canvas dimensions (typically 1920×1080).
        // grabToImage on this Item returns canvas-native pixels regardless
        // of how large the actual display window is.
        Item {
            id: stage
            width:  scene._canvas.width
            height: scene._canvas.height
            transformOrigin: Item.TopLeft
            scale: letterbox._scale

            // Content switcher — fades out as a whole when the logo
            // overlay is toggled on. The A/B crossfade lives INSIDE this
            // item; the contentSwitcher.opacity binding is independent
            // and only animates logo show/hide. That separation is what
            // lets the logo fade happen at the same per-output duration
            // as any other transition without conflating the two state
            // machines.
            Item {
                id: contentSwitcher
                anchors.fill: parent
                opacity: scene._showLogo ? 0 : 1
                Behavior on opacity {
                    NumberAnimation {
                        duration: scene._transMs
                        easing.type: Easing.InOutCubic
                    }
                }

                LiveContent {
                    id: layerA
                    anchors.fill: parent
                    item:          scene._heldItemA
                    kind:          scene._heldKindA
                    page:          scene._heldPageA
                    isClear:       scene._heldClearA
                    cropRect:      scene._heldCropA
                    outputKind:    scene.outputKind
                    themeRevision: scene._themeRevision
                    opacity:       scene._liveLayer === "A" ? 1.0 : 0.0
                    Behavior on opacity {
                        NumberAnimation {
                            duration: scene._transMs
                            easing.type: Easing.InOutCubic
                            onFinished: {
                                // Guard against the "interrupted by a
                                // rapid succession of transitions" case —
                                // only wipe if the layer has truly settled
                                // at 0. A new transition flipping back to
                                // A before the fade completes would have
                                // raised opacity again; we must not wipe
                                // the freshly-incoming state.
                                if (layerA.opacity === 0.0) scene._resetLayer("A")
                            }
                        }
                    }
                }
                LiveContent {
                    id: layerB
                    anchors.fill: parent
                    item:          scene._heldItemB
                    kind:          scene._heldKindB
                    page:          scene._heldPageB
                    isClear:       scene._heldClearB
                    cropRect:      scene._heldCropB
                    outputKind:    scene.outputKind
                    themeRevision: scene._themeRevision
                    opacity:       scene._liveLayer === "B" ? 1.0 : 0.0
                    Behavior on opacity {
                        NumberAnimation {
                            duration: scene._transMs
                            easing.type: Easing.InOutCubic
                            onFinished: {
                                if (layerB.opacity === 0.0) scene._resetLayer("B")
                            }
                        }
                    }
                }
            }

            // Logo overlay — sits above the content switcher when toggled
            // on. LogoView renders the configured image OR video, or a
            // "CRATER" fallback when no logo path is set. `active` gates
            // the video decoder; opacity drives the fade so the decoder
            // doesn't bounce on every fade tick.
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
                        duration: scene._transMs
                        easing.type: Easing.InOutCubic
                    }
                }
            }
        }
    }
}
