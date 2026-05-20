import QtQuick
import QtQuick.Layouts

// Middle top pane — what the operator is *staging*. Shows pages of the
// currently-selected schedule item. A page-row list at the top, a mini
// monitor at the bottom.
Rectangle {
    id: root

    // Panel surface — matches electron's `bg.muted` panel container.
    color: Theme.color.elevated

    // What's currently in the Preview pane. Two sources:
    //   1. AppState.libraryPreviewItem ─ set when the operator clicks a row in
    //      Songs/Scripture/Media tab. Takes priority because library navigation
    //      is the most-recent intent.
    //   2. ScheduleService.currentItems[selectedScheduleIndex] ─ the existing
    //      schedule-driven selection.
    // Clicking a schedule row clears libraryPreviewItem (see AppState.selectScheduleItem),
    // so the two never disagree silently.
    readonly property var selectedItem:
        AppState.libraryPreviewItem !== null
            ? AppState.libraryPreviewItem
            : (AppState.selectedScheduleIndex >= 0
               && AppState.selectedScheduleIndex < ScheduleService.currentItems.length
                   ? ScheduleService.currentItems[AppState.selectedScheduleIndex]
                   : null)

    // Canonical-shape items carry `pages` (array of {label, content}).
    //
    // Filter to pages that have *content* to display in the list. Media
    // items (image/video) carry a single placeholder page with empty
    // content — there's nothing textual to project, so showing an empty
    // bordered row for them is just visual noise. ThemedMonitor reads
    // item.pages directly (not this filtered list), so the bottom
    // thumbnail keeps rendering media correctly.
    readonly property var pages: {
        const raw = selectedItem && selectedItem.pages ? selectedItem.pages : []
        return raw.filter(function(p) {
            return p && p.content && String(p.content).length > 0
        })
    }

    // ── Header ──────────────────────────────────────────────────────────
    Item {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 40

        Row {
            anchors.left: parent.left
            anchors.leftMargin: Theme.space.lg
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.space.sm

            AppIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "eye"
                color: Theme.color.preview
                size: Theme.icon.md
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("Preview")
                color: Theme.color.textPrimary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize
                font.weight: Theme.font.weightMedium
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.pages.length > 0
                text: "· " + (AppState.previewSubIndex + 1) + " / " + root.pages.length
                color: Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
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
                    { label: qsTr("Sort by index"),   iconName: "sliders" },
                    { label: qsTr("Refresh"),         iconName: "refresh-cw" },
                    { separator: true },
                    { label: qsTr("Preview settings…"), iconName: "settings",
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

    // ── Body: empty state OR page list ──────────────────────────────────
    Item {
        anchors.top: header.bottom
        anchors.bottom: monitorWrap.top
        anchors.bottomMargin: Theme.space.md
        anchors.left: parent.left
        anchors.right: parent.right

        EmptyState {
            anchors.fill: parent
            visible: !root.selectedItem
            iconName: "eye"
            title: qsTr("No item selected")
            body: qsTr("Select an item from the schedule to preview")
        }

        ListView {
            id: pagesList
            anchors.fill: parent
            anchors.leftMargin: Theme.space.lg
            anchors.rightMargin: Theme.space.lg
            anchors.topMargin: Theme.space.sm
            visible: root.selectedItem !== null
            model: root.pages
            clip: true
            cacheBuffer: 200
            spacing: Theme.space.sm

            // Production-cue card delegate. Three zones:
            //   • indexCol — a full-height 32px left strip carrying the
            //     page number (1, 2, …). Sits flush against the card's
            //     left edge so the column reads as a stable rail
            //     regardless of card height.
            //   • headerBand — top strip carrying just the section title
            //     ("Verse 1" / "Genesis 1:8 · KJV"). No play icon, no
            //     counter — both lived in this band before but moved out
            //     so the title gets the full width.
            //   • bodyArea — wrapped content.
            // Header band is the focal device — its colour shifts on
            // selection while the body stays calm. Card height stays
            // content-determined, but active vs inactive cards share the
            // same geometry (only colour changes), so selection produces
            // a colour event, not a geometry change.
            delegate: Rectangle {
                id: card

                readonly property bool   isActive: AppState.previewSubIndex === index
                readonly property bool   isHover:  pageMa.containsMouse
                // True while the Preview pane owns keyboard focus. When
                // focus moves to Schedule / Library / Live, gold chrome on
                // the active card mutes — bg drops to neutral, border drops
                // to previewMuted desat-gold. The channel identity persists
                // as a faint warm tint without shouting from an unfocused
                // pane.
                readonly property bool   _paneFocused: AppState.activeFocusPanel === "preview"
                // modelData.label carries meaningful context: "Genesis 1:8"
                // for scripture, "Verse 1" / "Chorus" for songs. Empty
                // string when a page has no label (the page index already
                // carries identity via the left-rail indexCol).
                readonly property string headLabel: (modelData && modelData.label && String(modelData.label).length > 0)
                                                    ? String(modelData.label)
                                                    : ""
                // Translation badge — only rendered when the parent item is
                // a scripture verse with a translationCode. Songs/media omit
                // the slot entirely so absence doesn't perform itself.
                readonly property string translationCode:
                    (root.selectedItem && root.selectedItem.scriptureRef && root.selectedItem.scriptureRef.translationCode)
                        ? String(root.selectedItem.scriptureRef.translationCode)
                        : ""
                // Header band hides entirely (height collapses to 0) when
                // there's nothing to render in it — songs without section
                // labels and any other pages whose `label` is empty. Saves
                // the operator from looking at an empty coloured strip.
                readonly property bool hasHeader: headLabel.length > 0
                                               || translationCode.length > 0

                width:  pagesList.width
                height: bodyArea.y + bodyArea.height + 1

                color: isActive && _paneFocused ? Theme.color.previewSubtle
                                                : isHover  ? Theme.color.overlay
                                                           : Theme.color.raised
                border.color: isActive
                              ? (_paneFocused ? Theme.color.preview
                                              : Theme.color.previewMuted)
                            : isHover  ? Qt.rgba(205/255, 183/255, 142/255, 0.22)
                                       : "transparent"
                border.width: 1

                                
                // ── Index column (left rail) ────────────────────────────
                // Tinted to match the header band so the L-shape (left
                // rail + top band) reads as one continuous frame around
                // the body. Index uses mono font so digit widths stay
                // consistent across 1-50 (single-digit cards don't look
                // misaligned next to double-digit ones).
                Rectangle {
                    id: indexCol
                    anchors.top:    parent.top
                    anchors.left:   parent.left
                    anchors.bottom: parent.bottom
                    anchors.topMargin:    1
                    anchors.leftMargin:   1
                    anchors.bottomMargin: 1
                    width: 32

                    color: card.isActive && card._paneFocused ? "#4a3d28"
                                                              : card.isHover  ? "#22222a"
                                                                              : "#1c1c20"
                    
                    Text {
                        anchors.centerIn: parent
                        text: (index + 1).toString()
                        // White on active for symmetry with LivePanel's
                        // index rail. Mid-luminance brand colors (the
                        // champagne `Theme.color.preview`) read fine
                        // against #4a3d28, but textPrimary is even more
                        // legible and gives a consistent "active digit"
                        // appearance across both Preview and Live.
                        color: card.isActive ? Theme.color.textPrimary
                                             : Theme.color.textTertiary
                        font.family:    Theme.font.monoFamily
                        font.pixelSize: Theme.font.bodySize
                        font.weight:    Theme.font.weightSemiBold
                                            }
                }

                // ── Vertical demarcator ─────────────────────────────────
                // 1px line separating the indexCol from the title/body
                // area. Without it the left rail and the right side read
                // as one continuous coloured block when their tints
                // happen to match (e.g. active card has both in champagne).
                Rectangle {
                    id: vDivider
                    anchors.top:    parent.top
                    anchors.bottom: parent.bottom
                    anchors.left:   indexCol.right
                    anchors.topMargin:    1
                    anchors.bottomMargin: 1
                    width: 1
                    color: card.isActive && card._paneFocused
                           ? Qt.rgba(205/255, 183/255, 142/255, 0.30)
                           : Theme.color.borderSubtle
                                    }

                // ── Header band ─────────────────────────────────────────
                // Collapses to zero height when there's no label to show
                // (and no scripture translation code) — see `hasHeader`
                // above. The horizontal `divider` collapses too, so
                // bodyArea naturally seats flush against the top inset.
                Rectangle {
                    id: headerBand
                    visible: card.hasHeader
                    height:  card.hasHeader ? 22 : 0
                    anchors.top:   parent.top
                    anchors.left:  vDivider.right
                    anchors.right: parent.right
                    anchors.rightMargin: 1
                    anchors.topMargin:   1

                    color: card.isActive && card._paneFocused ? "#4a3d28"
                                                              : card.isHover  ? "#22222a"
                                                                              : "#1c1c20"
                    
                    Text {
                        anchors.fill: parent
                        anchors.leftMargin:  Theme.space.sm
                        anchors.rightMargin: Theme.space.sm
                        verticalAlignment: Text.AlignVCenter
                        // Concatenate "REF · TRANSLATION" only when a
                        // translation is present. Songs render just the
                        // section label.
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

                // 1px horizontal divider between header band and body.
                // Hidden along with the header when there's no label —
                // otherwise it'd render as a stray line at the card top.
                Rectangle {
                    id: divider
                    visible: card.hasHeader
                    height:  card.hasHeader ? 1 : 0
                    anchors.top:   headerBand.bottom
                    anchors.left:  vDivider.right
                    anchors.right: parent.right
                    anchors.rightMargin: 1
                    color: card.isActive && card._paneFocused
                           ? Qt.rgba(205/255, 183/255, 142/255, 0.30)
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
                        // Route through dslToHtml so inline formatting
                        // (bold/italic/underline/color) renders inline
                        // — keeps the card a faithful miniature of what
                        // the projection shows. Plain-text content is a
                        // valid DSL string with no markers, so unformatted
                        // lyrics still render as themselves.
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
                        AppState.previewSubIndex = index
                        // Claim arrow-key navigation for this panel — the
                        // operator clicked here, so subsequent Up/Down
                        // should move within the page list rather than
                        // through the library or schedule.
                        AppState.setActiveFocus("preview")
                    }
                    // Push the page to live but do NOT raise the projection
                    // window. The projection only raises via the explicit
                    // TopBar "Go Live" button (or schedule double-click).
                    // Preview-card double-click is meant to be a quick "stage
                    // this page" without surprising the operator with an
                    // audience-facing window pop.
                    onDoubleClicked: {
                        AppState.previewSubIndex = index
                        AppState.setActiveFocus("preview")
                        AppState.goLive(false)
                    }
                }
            }
        }

        // ── Keyboard navigation ─────────────────────────────────────────
        // Driven by Main.qml's window-level Up/Down shortcuts, which fan
        // out via AppState.previewNavigate{Up,Down} when
        // AppState.activeFocusPanel === "preview".
        //
        // Clamp-not-wrap matches the library list convention (see
        // ScriptureTab.onLibraryNavigateUp/Down). Scroll uses
        // ListView.Contain — only nudge the viewport when the active
        // card is off-screen, otherwise the list stays put. Matches the
        // scripture verse list's positionViewAtIndex policy.
        Connections {
            target: AppState
            function onPreviewNavigateUp() {
                if (root.pages.length === 0) return
                AppState.previewSubIndex = Math.max(AppState.previewSubIndex - 1, 0)
            }
            function onPreviewNavigateDown() {
                if (root.pages.length === 0) return
                AppState.previewSubIndex = Math.min(AppState.previewSubIndex + 1,
                                                   root.pages.length - 1)
            }
            function onPreviewSubIndexChanged() {
                // Fires on every previewSubIndex update — click, key,
                // schedule sync, anything. positionViewAtIndex with
                // Contain is a no-op when the card is already fully
                // visible (the common case on click), so the unified
                // handler is safe to wire here.
                if (pagesList.visible && AppState.previewSubIndex >= 0
                                      && AppState.previewSubIndex < root.pages.length) {
                    pagesList.positionViewAtIndex(AppState.previewSubIndex,
                                                  ListView.Contain)
                }
            }
            function onPreviewActivate() {
                // Enter on a focused preview card → push to live. Same
                // call path as the preview-card double-click: goLive
                // with raise=false so the projection window isn't
                // forcibly raised (matches the operator's mental model
                // that arrow + Enter is a "quiet" stage action — they
                // pop the projector themselves when ready).
                if (root.pages.length === 0) return
                AppState.goLive(false)
            }
        }
    }

    // ── Mini monitor ────────────────────────────────────────────────────
    // Thumbnail-scale mirror of the projection: ThemedMonitor resolves the
    // appropriate theme for the selected item's kind (per-item override or
    // user default), or hands off to MediaMonitor when the item is an
    // image/video. Operator audio is muted here — live carries audio.
    //
    // Size + position policy:
    //   • Compact (page list has rows — songs, scripture): a small
    //     160×90 thumb anchored to the LEFT, with an info column to its
    //     right showing the item title and "Slide N of M". This gives
    //     the operator a "what's projected" reference alongside readable
    //     metadata without consuming centerline real estate.
    //   • Fullsize (page list is empty — media items, or pages all
    //     filtered for empty content): the monitor takes over the body
    //     area, centered horizontally. Info column hides — there's
    //     nothing to label that the bigger thumbnail isn't already
    //     showing.
    // Anchor swap is done via States/AnchorChanges (the only way QML
    // cleanly toggles between two anchors at runtime).
    Item {
        id: monitorWrap
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Theme.space.lg
        anchors.leftMargin: Theme.space.lg

        // Guard on selectedItem — otherwise the empty pages list when
        // nothing is selected (fresh open, or after clear) would fire
        // fullsize and the monitor would squash the "No item selected"
        // EmptyState. We only want to expand when something is selected
        // *and* it has no text pages to render (i.e. media items).
        readonly property bool fullsize: root.selectedItem !== null && root.pages.length === 0
        readonly property real maxFullW: parent.width - Theme.space.lg * 2
        readonly property real maxFullH: parent.height - header.height
                                          - Theme.space.md      // body top gap
                                          - Theme.space.lg      // monitor bottom gap

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

        // Smooth the swap so a media→song selection change doesn't pop.
        Behavior on width  { NumberAnimation { duration: Theme.motion.normal; easing.type: Easing.OutCubic } }
        Behavior on height { NumberAnimation { duration: Theme.motion.normal; easing.type: Easing.OutCubic } }

        Rectangle {
            anchors.fill: parent
            radius: 0
            color: "#000000"
            border.color: Theme.color.borderStrong
            border.width: 1
            // Sharp corners — matches the rest of the operator console
            // (library tiles, schedule rows, scripture rows). clip stays
            // true so the inner gradient/monitor doesn't overhang the edge.
            clip: true

            Rectangle {
                anchors.fill: parent
                anchors.margins: 1
                radius: 0
                gradient: Gradient {
                    GradientStop { position: 0.0; color: "#0d0d12" }
                    GradientStop { position: 1.0; color: "#050508" }
                }
            }

            ThemedMonitor {
                anchors.fill: parent
                anchors.margins: 1
                item: root.selectedItem
                pageIndex: AppState.previewSubIndex
                muted: true
            }
        }
    }

    // ── Item info (right of monitor when compact) ──────────────────────
    // Shows the selected item's title plus "Slide N of M". Hidden when
    // the monitor is fullsize because the media takeover already
    // commands the operator's attention — adding text alongside would
    // just compete.
    Column {
        id: monitorInfo
        visible: !monitorWrap.fullsize && root.selectedItem !== null
        anchors.left:           monitorWrap.right
        anchors.leftMargin:     Theme.space.lg
        anchors.right:          parent.right
        anchors.rightMargin:    Theme.space.lg
        anchors.verticalCenter: monitorWrap.verticalCenter
        spacing: Theme.space.xs

        Text {
            width: parent.width
            text:  root.selectedItem && root.selectedItem.title
                       ? String(root.selectedItem.title)
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
                    .arg(AppState.previewSubIndex + 1)
                    .arg(root.pages.length)
            color: Theme.color.textSecondary
            font.family:    Theme.font.family
            font.pixelSize: Theme.font.smallSize
        }
    }

    // Right divider
    Rectangle {
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 1
        color: Theme.color.borderSubtle
    }
}
