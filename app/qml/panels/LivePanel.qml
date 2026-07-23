import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic

// Right top pane — what's currently on the projector. Shows the live
// item's pages with the live page highlighted in red.
Rectangle {
    id: root

    // Panel surface — matches electron's `bg.muted` panel container.
    color: Theme.color.elevated

    // Live item — two sources. When the library pushed straight to live
    // (operator double-clicked a song / verse / media item without first
    // routing through the schedule), ProjectionService.currentItem holds the
    // canonical item. Otherwise read from ScheduleService.currentItems via
    // the live index.
    readonly property var liveItem:
        AppState.libraryLiveActive
            ? ProjectionService.currentItem
            : (AppState.liveScheduleIndex >= 0
               && AppState.liveScheduleIndex < ScheduleService.currentItems.length
                   ? ScheduleService.currentItems[AppState.liveScheduleIndex]
                   : null)

    // Filter to pages that have *content* to display. Media items
    // (image/video) carry one placeholder page with empty content — we
    // suppress empty rows here. ThemedMonitor reads item.pages directly,
    // so the bottom thumbnail still renders the media. Mirrors the same
    // filter in PreviewPanel.
    readonly property var pages: {
        const raw = liveItem && liveItem.pages ? liveItem.pages : []
        return raw.filter(function(p) {
            return p && p.content && String(p.content).length > 0
        })
    }
    // `isClear` no longer makes the live state collapse — clearing hides
    // text but keeps the theme background (and logo, if showing) on the
    // projector. From the operator's perspective the channel is still
    // live; only the audience-facing text content is suppressed.
    readonly property bool isLive:
        (AppState.libraryLiveActive && liveItem && (liveItem.pages || liveItem.title))
        || (AppState.liveScheduleIndex >= 0 && liveItem !== null)

    // ── Auto-advance ────────────────────────────────────────────────────
    // Steps a live, multi-slide item to its next page on a timer, honoring
    // the Settings > Song > Auto-advance preferences. Only songs (and any
    // future multi-page text kind) qualify — single-slide media/scripture
    // have pages.length <= 1 and are skipped. Blanking (AppState.isClear)
    // pauses it. The timer is re-armed for a FULL delay after every page
    // change (manual OR automatic) via _syncAutoAdvance(), so a manual jump
    // never gets a truncated interval and a resumed song starts fresh. We
    // drive start/stop imperatively rather than binding `running` because a
    // bound `running` can't coexist with the restart() we need for re-arming.
    Timer {
        id: autoAdvanceTimer
        interval: Math.max(1, SettingsService.autoAdvanceDelaySeconds) * 1000
        repeat: true
        onTriggered: {
            const last = root.pages.length - 1
            if (last < 1) { autoAdvanceTimer.stop(); return }
            if (AppState.liveSubIndex < last) {
                AppState.liveSubIndex = AppState.liveSubIndex + 1
                ProjectionService.setPage(AppState.liveSubIndex)
            } else if (SettingsService.autoAdvanceLoop) {
                AppState.liveSubIndex = 0
                ProjectionService.setPage(AppState.liveSubIndex)
            } else {
                autoAdvanceTimer.stop()   // reached the end, nothing to loop to
            }
        }
    }

    function _syncAutoAdvance() {
        const last = root.pages.length - 1
        const shouldRun = SettingsService.autoAdvance
                       && root.isLive
                       && last >= 1
                       && !AppState.isClear
                       && (SettingsService.autoAdvanceLoop || AppState.liveSubIndex < last)
        if (shouldRun) autoAdvanceTimer.restart()   // (re)arm a fresh full interval
        else           autoAdvanceTimer.stop()
    }

    // Re-sync on every input that gates or paces the timer. liveSubIndex
    // firing here (from either a manual jump or the timer's own advance) is
    // what re-arms the full delay for the next slide.
    onPagesChanged:  _syncAutoAdvance()
    onIsLiveChanged: _syncAutoAdvance()
    Connections {
        target: SettingsService
        function onAutoAdvanceChanged()             { root._syncAutoAdvance() }
        function onAutoAdvanceDelaySecondsChanged() { root._syncAutoAdvance() }
        function onAutoAdvanceLoopChanged()         { root._syncAutoAdvance() }
    }
    Connections {
        target: AppState
        function onIsClearChanged()      { root._syncAutoAdvance() }
        function onLiveSubIndexChanged() { root._syncAutoAdvance() }
    }

    // ── Header ──────────────────────────────────────────────────────────
    Item {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 40

        // LIVE pill — visible only when something's live.
        Rectangle {
            visible: root.isLive
            anchors.left: parent.left
            anchors.leftMargin: Theme.space.lg
            anchors.verticalCenter: parent.verticalCenter
            height: 22
            width: liveLabel.implicitWidth + Theme.space.md * 2 + liveDot.width + Theme.space.xs
            radius: 4
            color: Theme.color.live

            Row {
                anchors.centerIn: parent
                spacing: Theme.space.xs

                Rectangle {
                    id: liveDot
                    anchors.verticalCenter: parent.verticalCenter
                    width: 6; height: 6; radius: 3
                    color: "#ffffff"

                    SequentialAnimation on opacity {
                        running: root.isLive
                        loops: Animation.Infinite
                        NumberAnimation { from: 1.0; to: 0.4; duration: 800; easing.type: Easing.InOutQuad }
                        NumberAnimation { from: 0.4; to: 1.0; duration: 800; easing.type: Easing.InOutQuad }
                    }
                }
                Text {
                    id: liveLabel
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("LIVE")
                    color: "#ffffff"
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                    font.weight: Theme.font.weightSemiBold
                    font.letterSpacing: 1.0
                }
            }
        }

        // Idle label when nothing is live (keeps header height consistent).
        Row {
            visible: !root.isLive
            anchors.left: parent.left
            anchors.leftMargin: Theme.space.lg
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.space.sm

            AppIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "radio"
                color: Theme.color.textTertiary
                size: Theme.icon.md
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("Live")
                color: Theme.color.textSecondary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize
                font.weight: Theme.font.weightMedium
            }
        }

        IconButton {
            id: settingsBtn
            anchors.right: parent.right
            anchors.rightMargin: Theme.space.md
            anchors.verticalCenter: parent.verticalCenter
            iconName: "settings"
            iconSize: Theme.icon.sm
            onClicked: {
                AppState.openContextMenuAt(settingsBtn,
                    settingsBtn.width, settingsBtn.height + 4, [
                    { label: qsTr("Clear output"),     iconName: "x",
                      action: function() { AppState.clearLive() } },
                    { label: qsTr("Toggle logo"),      iconName: "image",
                      action: function() { AppState.toggleLogo() } },
                    { separator: true },
                    { label: qsTr("Output settings…"), iconName: "monitor",
                      action: function() { AppState.openModal("settings", {}) } }
                ], { dx: -220 })
            }
        }

        Rectangle {
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: 1
            color: Theme.color.borderSubtle
        }
    }

    // ── Body ────────────────────────────────────────────────────────────
    Item {
        anchors.top: header.bottom
        anchors.bottom: monitorWrap.top
        anchors.bottomMargin: Theme.space.md
        anchors.left: parent.left
        anchors.right: parent.right

        EmptyState {
            anchors.fill: parent
            visible: !root.isLive
            iconName: "radio"
            // `isClear` no longer collapses isLive (see property comment
            // above), so the previous "Display cleared" branch is now
            // unreachable. Single message when no live item exists.
            title: qsTr("Nothing live")
            body: qsTr("Double-click a preview item to go live")
        }

        ListView {
            id: pagesList
            ScrollBar.vertical: AppScrollBar {}
            anchors.fill: parent
            anchors.leftMargin: Theme.space.lg
            // Run to the panel's right edge so the scrollbar rides the gutter
            // instead of sitting on the cards; the delegate insets itself by
            // space.lg on the right (below) to keep the card width unchanged.
            anchors.rightMargin: 0
            anchors.topMargin: Theme.space.sm
            visible: root.isLive
            model: root.pages
            clip: true
            cacheBuffer: 200
            spacing: Theme.space.sm

            // Production-cue card delegate — same anatomy as PreviewPanel's
            // delegate, but channel-recoloured to crimson. Structure
            // mirrored so the operator sees a parallel pair of cue lists:
            // champagne = staged, crimson = on-air. Three zones (indexCol,
            // headerBand, bodyArea) — see PreviewPanel.qml for the
            // detailed rationale.
            delegate: Rectangle {
                id: card

                readonly property bool   isActive: AppState.liveSubIndex === index
                readonly property bool   isHover:  pageMa.containsMouse
                // True while the Live pane owns keyboard focus. When focus
                // moves to Schedule / Library / Preview, the crimson chrome
                // on the active card mutes — bg drops to neutral, border
                // drops to liveMuted desat-maroon. The channel identity
                // persists as a faint warm tint without shouting from an
                // unfocused pane. The "● LIVE" pill in the panel header is
                // NOT gated by this property — it lives in the header and
                // continues to read regardless of pane focus.
                readonly property bool   _paneFocused: AppState.activeFocusPanel === "live"
                readonly property string headLabel: (modelData && modelData.label && String(modelData.label).length > 0)
                                                    ? String(modelData.label)
                                                    : ""
                // Translation badge — scripture only. Songs/media omit the
                // separator and code entirely so absence doesn't perform.
                readonly property string translationCode:
                    (root.liveItem && root.liveItem.scriptureRef && root.liveItem.scriptureRef.translationCode)
                        ? String(root.liveItem.scriptureRef.translationCode)
                        : ""
                // Header band collapses to zero height when there's no
                // label and no translation code. Mirrors PreviewPanel.
                readonly property bool hasHeader: headLabel.length > 0
                                               || translationCode.length > 0

                // Inset on the right by space.lg + the scrollbar lane, so the
                // gap to the bar matches the space.lg gap on the left (equal
                // breathing room), with the bar beyond it at the panel edge.
                width:  pagesList.width - Theme.space.lg - Theme.size.scrollBar
                height: bodyArea.y + bodyArea.height + 1

                color: isActive && _paneFocused ? Theme.color.liveSubtle
                                                : isHover  ? Theme.color.overlay
                                                           : Theme.color.raised
                border.color: isActive
                              ? (_paneFocused ? Theme.color.live
                                              : Theme.color.liveMuted)
                            : isHover  ? Qt.rgba(177/255, 54/255, 52/255, 0.22)
                                       : "transparent"
                border.width: 1

                                
                // ── Index column (left rail) ────────────────────────────
                Rectangle {
                    id: indexCol
                    anchors.top:    parent.top
                    anchors.left:   parent.left
                    anchors.bottom: parent.bottom
                    anchors.topMargin:    1
                    anchors.leftMargin:   1
                    anchors.bottomMargin: 1
                    width: 32

                    color: card.isActive && card._paneFocused ? Theme.color.cueRailLive
                                                              : card.isHover  ? Theme.color.cueRailHover
                                                                              : Theme.color.cueRailIdle
                    
                    Text {
                        anchors.centerIn: parent
                        text: (index + 1).toString()
                        // Active text uses textPrimary (white) rather than
                        // a tinted crimson. Saturated reds like
                        // Theme.color.live sit at mid-luminance, so even
                        // lightened (Qt.lighter, 1.5x) they stay in the
                        // red family — close in brightness to the
                        // #4d1918 rail bg, giving the digit only a faint
                        // glow against it. The active "this is live" cue
                        // is already carried by the rail tint, the
                        // crimson card border, and the title in the
                        // header band; the digit doesn't also need to be
                        // red-on-red. White wins clarity outright.
                        color: card.isActive ? Theme.color.textPrimary
                                             : Theme.color.textTertiary
                        font.family:    Theme.font.monoFamily
                        font.pixelSize: Theme.font.bodySize
                        font.weight:    Theme.font.weightSemiBold
                                            }
                }

                // ── Vertical demarcator ─────────────────────────────────
                // Mirrors PreviewPanel — 1px line separating the indexCol
                // from the title/body area so the L-shape doesn't blur
                // into one continuous block when tints match.
                Rectangle {
                    id: vDivider
                    anchors.top:    parent.top
                    anchors.bottom: parent.bottom
                    anchors.left:   indexCol.right
                    anchors.topMargin:    1
                    anchors.bottomMargin: 1
                    width: 1
                    color: card.isActive && card._paneFocused
                           ? Qt.rgba(177/255, 54/255, 52/255, 0.30)
                           : Theme.color.borderSubtle
                                    }

                // ── Header band ─────────────────────────────────────────
                // Collapses to zero height when there's no label/translation.
                Rectangle {
                    id: headerBand
                    visible: card.hasHeader
                    height:  card.hasHeader ? 22 : 0
                    anchors.top:   parent.top
                    anchors.left:  vDivider.right
                    anchors.right: parent.right
                    anchors.rightMargin: 1
                    anchors.topMargin:   1

                    color: card.isActive && card._paneFocused ? Theme.color.cueRailLive
                                                              : card.isHover  ? Theme.color.cueRailHover
                                                                              : Theme.color.cueRailIdle
                    
                    Text {
                        anchors.fill: parent
                        anchors.leftMargin:  Theme.space.sm
                        anchors.rightMargin: Theme.space.sm
                        verticalAlignment: Text.AlignVCenter
                        text: card.headLabel.toUpperCase()
                              + (card.translationCode.length > 0
                                   ? "  ·  " + card.translationCode
                                   : "")
                        color: card.isActive ? Theme.color.textPrimary : Theme.color.textSecondary
                        font.family:    Theme.font.family
                        font.pixelSize: Theme.font.microSize
                        font.weight:    Theme.font.weightSemiBold
                        font.letterSpacing: 1.2
                        elide: Text.ElideRight
                                            }
                }

                // 1px horizontal divider — hides along with the header.
                Rectangle {
                    id: divider
                    visible: card.hasHeader
                    height:  card.hasHeader ? 1 : 0
                    anchors.top:   headerBand.bottom
                    anchors.left:  vDivider.right
                    anchors.right: parent.right
                    anchors.rightMargin: 1
                    color: card.isActive && card._paneFocused
                           ? Qt.rgba(177/255, 54/255, 52/255, 0.30)
                           : Theme.color.borderSubtle
                                    }

                // ── Body ────────────────────────────────────────────────
                Item {
                    id: bodyArea
                    anchors.top:   divider.bottom
                    anchors.left:  vDivider.right
                    anchors.right: parent.right
                    anchors.rightMargin: 1
                    height: pageText.implicitHeight + Theme.space.sm * 2

                    Text {
                        id: pageText
                        anchors.top:   parent.top
                        anchors.left:  parent.left
                        anchors.right: parent.right
                        anchors.topMargin:   Theme.space.sm
                        anchors.leftMargin:  Theme.space.sm
                        anchors.rightMargin: Theme.space.sm
                        // Mirror PreviewPanel: RichText so the live card
                        // shows the same formatting the projection does.
                        textFormat:     Text.RichText
                        text:           LyricsService.dslToHtml(modelData.content || "")
                        color:          Theme.color.textPrimary
                        font.family:    Theme.font.family
                        font.pixelSize: Theme.font.bodySize
                        wrapMode:       Text.WordWrap
                        lineHeight:     1.25
                    }
                }

                MouseArea {
                    id: pageMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape:  Qt.PointingHandCursor
                    onClicked: {
                        AppState.liveSubIndex = index
                        // Claim arrow-key navigation for this panel —
                        // mirrors PreviewPanel. Subsequent Up/Down moves
                        // through the live page list.
                        AppState.setActiveFocus("live")
                        // Push the page to the projection immediately.
                        // The Live pane is a control surface, not a
                        // preview — clicking a card is the operator
                        // commanding "audience sees this now", not just
                        // changing what the mini monitor renders. setPage
                        // is a no-op when the page is already current,
                        // and clears the m_isClear flag as a side effect
                        // (correct: an explicit click implies "show",
                        // overriding a previous Clear).
                        ProjectionService.setPage(index)
                    }
                }
            }
        }

        // ── Keyboard navigation ─────────────────────────────────────────
        // Mirrors PreviewPanel's Connections block but scrolls with
        // ListView.Center rather than ListView.Contain. Reason: the live
        // panel is the operator's "what's on the projector right now"
        // surface; keeping the active card centered means the cards
        // immediately before and after it are always visible, which is
        // what the operator looks at when deciding what to advance to
        // next. The preview panel uses Contain because that list is
        // about browsing stages, not anchoring on a single focal cue.
        Connections {
            target: AppState
            // Arrow-key navigation in the Live pane is a control gesture,
            // not a preview gesture — pressing Up/Down advances both the
            // operator's local highlight AND the audience-facing page.
            // Same rationale as the card-click handler (see pageMa above):
            // the Live pane is a control surface. setPage is a no-op when
            // the resolved index already matches, so clamp-at-bounds
            // keypresses don't burn a re-render.
            function onLiveNavigateUp() {
                if (root.pages.length === 0) return
                AppState.liveSubIndex = Math.max(AppState.liveSubIndex - 1, 0)
                ProjectionService.setPage(AppState.liveSubIndex)
            }
            function onLiveNavigateDown() {
                if (root.pages.length === 0) return
                AppState.liveSubIndex = Math.min(AppState.liveSubIndex + 1,
                                                 root.pages.length - 1)
                ProjectionService.setPage(AppState.liveSubIndex)
            }
            function onLiveSubIndexChanged() {
                // Fires on every liveSubIndex update — click, key,
                // schedule advance, etc. Centering on click is mostly
                // harmless: the clicked card was already visible, so
                // the scroll either no-ops or gently nudges to align,
                // which feels like "the panel snapping to its focal
                // point" rather than a jolt.
                if (pagesList.visible && AppState.liveSubIndex >= 0
                                      && AppState.liveSubIndex < root.pages.length) {
                    pagesList.positionViewAtIndex(AppState.liveSubIndex,
                                                  ListView.Center)
                }
            }
        }
    }

    // ── Mini monitor ────────────────────────────────────────────────────
    // Rendering priority (top -> bottom of z-stack):
    //   1. Logo overlay (when AppState.showLogo) — always wins.
    //   2. ThemedMonitor — renders the live item through its resolved theme
    //      (or via MediaMonitor for image/video kinds). isClear / showLogo
    //      are passed through so the content layer suppresses itself when
    //      output is cleared or logo is up.
    //   3. Gradient backdrop (always behind everything).
    //
    // Audio: ownership flips with OutputService.projectionOpen. When the
    // projection window is on the audience screen, ProjectionScene's
    // MediaMonitor is the unmuted subscriber (audience-facing) and this
    // monitor goes muted — same audio bus, single voice. When projection
    // is parked (NDI-only mode, or no second monitor configured yet), the
    // live mini-monitor unmutes so the operator still hears the clip. The
    // shared MediaPlaybackService takes the OR of all subscribers'
    // wantsAudio votes, so flipping this flag is a real "this surface
    // wants audio" toggle rather than a double-routing concern.
    // Size + position policy mirrors PreviewPanel:
    //   • Compact: 160×90 thumb anchored left, with the item info
    //     column on the right (title + "Slide N of M").
    //   • Fullsize (media items): centered, expanded to fit the body area.
    // Live shares Preview's base size (160×90). The crimson border on the
    // monitor frame is enough visual separation — making live physically
    // larger would over-emphasise it and break the paired-pane symmetry.
    Item {
        id: monitorWrap
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Theme.space.lg
        anchors.leftMargin: Theme.space.lg

        // Guard on isLive — otherwise the empty pages list on fresh open
        // (nothing live yet) would fire fullsize and the monitor would
        // bloom into the body, squashing the "Nothing live" EmptyState.
        // We only want to expand when there's a real live item *and* it
        // has no text pages to render (i.e. media items).
        readonly property bool fullsize: root.isLive && root.pages.length === 0
        readonly property real maxFullW: parent.width - Theme.space.lg * 2
        readonly property real maxFullH: parent.height - header.height
                                          - Theme.space.md
                                          - Theme.space.lg

        width:  fullsize ? Math.min(maxFullW, maxFullH * 16 / 9) : 160
        height: fullsize ? width * 9 / 16                        : 90

        state: fullsize ? "fullsize" : "compact"
        states: [
            State {
                name: "compact"
                AnchorChanges {
                    target: monitorWrap
                    anchors.left: monitorWrap.parent.left
                    anchors.horizontalCenter: undefined
                }
            },
            State {
                name: "fullsize"
                AnchorChanges {
                    target: monitorWrap
                    anchors.left: undefined
                    anchors.horizontalCenter: monitorWrap.parent.horizontalCenter
                }
            }
        ]

        Behavior on width  { NumberAnimation { duration: Theme.motion.normal; easing.type: Easing.OutCubic } }
        Behavior on height { NumberAnimation { duration: Theme.motion.normal; easing.type: Easing.OutCubic } }

        Rectangle {
            anchors.fill: parent
            radius: 0
            color: "#000000"
            border.color: root.isLive ? Theme.color.live : Theme.color.borderStrong
            border.width: 1.5
            clip: true

            Behavior on border.color { ColorAnimation { duration: Theme.motion.normal } }

            Rectangle {
                anchors.fill: parent
                anchors.margins: 1.5
                radius: 0
                gradient: Gradient {
                    GradientStop { position: 0.0; color: "#0d0d12" }
                    GradientStop { position: 1.0; color: "#050508" }
                }
            }

            ThemedMonitor {
                anchors.fill: parent
                anchors.margins: 1.5
                item: root.liveItem
                pageIndex: AppState.liveSubIndex
                // Mute when the audience-facing projection is up; unmute
                // when it's parked (NDI-only) so the operator still hears
                // the audio. See the audio-ownership paragraph above.
                muted: OutputService.projectionOpen
                isClear: AppState.isClear
                showLogo: AppState.showLogo
                // Mirror the audience's crop. The user instruction was
                // explicit: "Live Pane should only contain the section
                // being displayed." ProjectionService.cropRect is the
                // committed snapshot from the most recent goLive — image
                // and PDF live items render at that crop here, while
                // songs/scriptures get the identity rect their goLive()
                // overload resets to. No crop UI ever appears in Live
                // because LivePanel doesn't host CroppableMediaPreview;
                // only the rendered output reflects the operator's commit.
                cropRect: ProjectionService.cropRect
            }

            // Mirror the projection's logo overlay at mini-monitor scale —
            // LogoView renders the configured image OR video (or the
            // "CRATER" fallback) so the operator sees exactly what the
            // audience is seeing. Declared last so it sits above
            // ThemedMonitor when both are active.
            LogoView {
                anchors.fill: parent
                anchors.margins: 1.5
                active: AppState.showLogo
                visible: AppState.showLogo
            }
        }
    }

    // ── Item info (right of monitor when compact) ──────────────────────
    // Shows the live item's title plus "Slide N of M". Hidden when the
    // monitor is fullsize (media takeover already commands attention) or
    // when nothing is live (the EmptyState above carries the message).
    Column {
        id: monitorInfo
        visible: !monitorWrap.fullsize && root.isLive
        anchors.left:           monitorWrap.right
        anchors.leftMargin:     Theme.space.lg
        anchors.right:          parent.right
        anchors.rightMargin:    Theme.space.lg
        anchors.verticalCenter: monitorWrap.verticalCenter
        spacing: Theme.space.xs

        Text {
            width: parent.width
            text:  root.liveItem && root.liveItem.title
                       ? String(root.liveItem.title)
                       : ""
            color: Theme.color.textPrimary
            font.family:    Theme.font.family
            font.pixelSize: Theme.font.bodySize
            font.weight:    Theme.font.weightMedium
            elide: Text.ElideRight
        }

        Text {
            visible: root.pages.length > 1
            text: qsTr("Slide %1 of %2")
                    .arg(AppState.liveSubIndex + 1)
                    .arg(root.pages.length)
            color: Theme.color.textSecondary
            font.family:    Theme.font.family
            font.pixelSize: Theme.font.smallSize
        }
    }
}
