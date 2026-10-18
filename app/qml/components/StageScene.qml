import QtQuick
import Crater

// The stage / confidence display — what the preacher or worship leader sees,
// as opposed to what the congregation sees.
//
// This is the OTHER half of multi-display. ProjectionScene renders the
// audience view and every extra output could only ever mirror it, which
// makes a second screen a bigger version of the first. A stage display is
// useful precisely because it is DIFFERENT: it shows the live words plus the
// things the audience must never see — the preacher's own notes, what is
// coming next, and the time.
//
// Mounted by OutputWindow when its output's contentMode is "stage" (see
// OutputBinding::contentMode). Any output can be put in this mode, so a
// church with three displays can run audience + stage + overflow without
// registering anything special.
//
// Deliberately NOT themed. A .craterheme is an audience design — background
// art, drop shadows, a font chosen to look good behind a worship band. None
// of that helps somebody reading their next line from twelve feet away in a
// dark room, and an animated mesh gradient on a third output is real frame
// budget on the Intel HD 4000 this app is specified down to
// (ARCHITECTURE.md §6). So the palette below is fixed, flat and high
// contrast, and the whole scene is text on solid colour.
Item {
    id: stage

    // The output id this scene belongs to. Not used for theme resolution
    // (there is no theme here) but kept so the component has the same shape
    // as ProjectionScene.
    property string outputKind: "stage"

    // What to show and how large, from Settings > Projection > Stage
    // display. One set for every stage output: a church with two stage
    // monitors wants them to agree.
    readonly property var  _opts: SettingsService.stageDisplay
    readonly property bool _showNext:  _opts.showNext !== false
    readonly property bool _showNotes: _opts.showNotes !== false
    readonly property bool _showClock: _opts.showClock !== false
    readonly property bool _showTimer: _opts.showTimer !== false && StageTimer.active
    readonly property real _scale: (_opts.textScale || 100) / 100

    // ── Live state ──────────────────────────────────────────────────────
    // Read straight off ProjectionService, exactly like ProjectionScene.
    // No snapshotting and no transition machinery: a confidence monitor
    // wants the next line the instant the operator commits it, and a
    // crossfade between two blocks of reading material is an obstacle, not
    // a polish.
    readonly property var    _item:  ProjectionService.currentItem
    readonly property string _kind:  ProjectionService.contentKind
    readonly property int    _page:  ProjectionService.pageIndex
    readonly property bool   _clear: ProjectionService.isClear
    readonly property bool   _logo:  ProjectionService.showLogo

    readonly property var _pages: (_item && _item.pages) || []
    readonly property int _pageCount: _pages.length

    function _pageAt(i) {
        if (i < 0 || i >= _pages.length) return null
        return _pages[i]
    }

    readonly property var    _cur:     _pageAt(_page)
    readonly property var    _next:    _pageAt(_page + 1)
    readonly property string _curText: (_cur && _cur.content) || ""
    // Slide heading and speaker notes only exist on presentation pages.
    // Songs and scriptures simply leave the keys unset, so these resolve to
    // "" and their rows collapse — the same page shape serves every kind.
    readonly property string _curTitle: (_cur && _cur.title) || ""
    readonly property string _curNotes: (_cur && _cur.notes) || ""

    readonly property string _itemTitle:
        (_item && (_item.title || _item.reference)) || ""

    // A song's section name ("Verse 2") is worth a glance in the header. The
    // other kinds' page labels repeat what is already on screen (the
    // reference, the slide heading), so they are left out.
    readonly property string _curSection: (_kind === "song" && _cur && _cur.label) || ""

    readonly property bool _hasLive: _kind.length > 0 && _pageCount > 0
    readonly property bool _blanked: _clear || _logo

    // ── What comes next ─────────────────────────────────────────────────
    // The next page of this item, as its label (section name, verse
    // reference, slide heading) and its first two lines. Past the last page
    // it is the next schedule row, so the person on stage can see what the
    // operator moves to.
    readonly property var _nextRow: {
        if (_next || AppState.libraryLiveActive) return null
        const i = AppState.liveScheduleIndex
        const rows = ScheduleService.currentItems
        return (i >= 0 && i + 1 < rows.length) ? rows[i + 1] : null
    }
    readonly property string _nextLabel: _next
        ? (_next.title || _next.label || "")
        : (_nextRow ? (_nextRow.title || "") : "")
    readonly property string _nextLines: {
        if (!_next) return ""
        const out = []
        const lines = String(_next.content || "").split("\n")
        for (let i = 0; i < lines.length && out.length < 2; i++) {
            const t = LyricsService.flattenLine(lines[i]).trim()
            if (t.length > 0) out.push(t)
        }
        return out.join("\n")
    }
    readonly property bool _hasNext: _showNext && (_nextLabel.length > 0 || _nextLines.length > 0)

    // ── Palette ─────────────────────────────────────────────────────────
    // Fixed, not Theme.color. The console palette follows the operator's
    // light/dark preference; a stage display is furniture in a dim room and
    // must not turn white because somebody picked the Sepia console theme.
    readonly property color _bg:      "#08090c"
    readonly property color _panel:   "#12141a"
    readonly property color _rule:    "#262a33"
    readonly property color _text:    "#f5f7fa"
    readonly property color _dim:     "#8b93a3"
    readonly property color _accent:  "#67e8f9"
    readonly property color _notesFg: "#fde68a"
    readonly property color _over:    "#f87171"

    // Type scale derived from height so the layout holds from a 720p
    // confidence monitor to a 4K panel without a second set of numbers.
    // The text size setting scales all of it. For the live words it moves
    // the ceiling the fit can reach, since they are already as large as the
    // area allows.
    readonly property real _u: height * _scale
    readonly property int _chromeSize: Math.max(11, Math.round(_u * 0.030))
    readonly property int _titleSize:  Math.max(14, Math.round(_u * 0.042))
    readonly property int _bodyMax:    Math.max(20, Math.round(_u * 0.115))
    readonly property int _bodyMin:    Math.max(12, Math.round(height * 0.022))
    readonly property int _footSize:   Math.max(12, Math.round(_u * 0.030))
    // Next is read from across the stage, so its two lines are set well
    // above the notes size rather than shrunk to fit a box.
    readonly property int _nextSize:   Math.max(14, Math.round(_u * 0.050))
    readonly property int _pad:        Math.max(12, Math.round(height * 0.030))

    // Inline lyric/scripture markup ({color=…}, **bold**) reaches us in the
    // same DSL the audience renderer receives. Route it through the same
    // service so a highlighted verse reads identically on both screens
    // rather than showing raw markers here. Show verse numbers applies here
    // too, so the stage display matches the audience screen.
    function _rich(s) {
        const t = AppState.withVerseNumberSetting(s)
        return t.length > 0 ? LyricsService.dslToHtml(t, "") : ""
    }

    function _escape(s) {
        return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    }

    // No anchors on the root: a Loader already sizes its item, and a component
    // that anchors to its own parent cannot be embedded anywhere that wants to
    // place it (a future stage-preview tile in the console, for instance).
    Rectangle {
        anchors.fill: parent
        color: stage._bg
    }

    // ── Header: what is live, where we are in it, and the time ──────────
    Item {
        id: header
        anchors { top: parent.top; left: parent.left; right: parent.right }
        anchors.margins: stage._pad
        height: stage._chromeSize * 1.6

        Text {
            id: liveLabel
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(0, parent.width - status.width - counter.width - timer.width
                                  - clock.width - stage._pad * 4)
            text: stage._curSection.length > 0
                  ? stage._itemTitle + "  ·  " + stage._curSection
                  : stage._itemTitle
            color: stage._accent
            elide: Text.ElideRight
            font.family: Theme.font.family
            font.pixelSize: stage._chromeSize
            font.weight: Theme.font.weightSemiBold
        }

        // The audience screen being blanked or showing the logo is information
        // the person on stage needs, otherwise they keep preaching to a black
        // screen believing their point is up. A tag up here says so without
        // covering the words, which stay readable through a blank: that is
        // the reason to blank in the first place.
        Rectangle {
            id: status
            anchors.right: counter.left
            anchors.rightMargin: stage._pad
            anchors.verticalCenter: parent.verticalCenter
            visible: stage._blanked
            width: visible ? statusLabel.implicitWidth + stage._pad : 0
            height: statusLabel.implicitHeight + Math.round(stage._pad * 0.4)
            color: stage._notesFg

            Text {
                id: statusLabel
                anchors.centerIn: parent
                text: stage._logo ? qsTr("LOGO ON SCREEN") : qsTr("SCREEN BLANKED")
                color: stage._bg
                font.family: Theme.font.family
                font.pixelSize: stage._chromeSize
                font.weight: Theme.font.weightBold
                font.letterSpacing: 1
            }
        }

        Text {
            id: counter
            anchors.right: timer.left
            anchors.rightMargin: stage._pad
            anchors.verticalCenter: parent.verticalCenter
            visible: stage._pageCount > 1
            width: visible ? implicitWidth : 0
            text: (stage._page + 1) + " / " + stage._pageCount
            color: stage._dim
            font.family: Theme.font.family
            font.pixelSize: stage._chromeSize
        }

        // The service timer or countdown, started from the console's Stage
        // timer menu. Labelled, so twelve minutes left is never read as the
        // time of day. Amber for the last two minutes of a countdown, red
        // and counting up once it is over.
        Row {
            id: timer
            anchors.right: clock.left
            anchors.rightMargin: stage._pad
            anchors.verticalCenter: parent.verticalCenter
            visible: stage._showTimer
            width: visible ? implicitWidth : 0
            spacing: Math.round(stage._pad * 0.4)

            readonly property color _tone: StageTimer.overtime ? stage._over
                                         : StageTimer.nearEnd ? stage._notesFg
                                         : stage._text

            Text {
                anchors.baseline: timerValue.baseline
                text: !StageTimer.running ? qsTr("PAUSED")
                    : StageTimer.overtime ? qsTr("OVER")
                    : StageTimer.mode === "countdown" ? qsTr("LEFT")
                    : qsTr("SERVICE")
                color: StageTimer.running ? timer._tone : stage._dim
                font.family: Theme.font.family
                font.pixelSize: Math.round(stage._chromeSize * 0.7)
                font.weight: Theme.font.weightBold
                font.letterSpacing: 1
            }
            Text {
                id: timerValue
                text: StageTimer.text
                color: StageTimer.running ? timer._tone : stage._dim
                font.family: Theme.font.family
                font.pixelSize: stage._chromeSize
                font.weight: Theme.font.weightBold
                // Even-width digits, so the time does not shift sideways
                // every second.
                font.features: { "tnum": 1 }
            }
        }

        // Wall clock. The single most-requested thing on a confidence monitor
        // and the cheapest one to give them: a string property and a timer,
        // no service.
        //
        // The value lives in a plain property that ONLY the timer writes.
        // Binding `text` to Qt.formatDateTime(new Date(), …) directly would
        // look right and be wrong twice over: the expression has no reactive
        // dependency so it would never update on its own, and the timer's
        // first imperative write to `text` would silently break the binding
        // anyway.
        Text {
            id: clock
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: stage._showClock
            width: visible ? implicitWidth : 0
            color: stage._text
            font.family: Theme.font.family
            font.pixelSize: stage._chromeSize
            font.weight: Theme.font.weightSemiBold

            property string now: ""
            text: now
            Component.onCompleted: now = Qt.formatDateTime(new Date(), "HH:mm")

            Timer {
                // 15 s rather than 1 s: the display shows minutes, so a
                // per-second tick would wake the render thread sixty times
                // for every visible change. Worst case the clock is a
                // quarter-minute stale, which nobody reading it can tell.
                interval: 15000
                running: true
                repeat: true
                onTriggered: clock.now = Qt.formatDateTime(new Date(), "HH:mm")
            }
        }
    }

    Rectangle {
        id: headerRule
        anchors { top: header.bottom; left: parent.left; right: parent.right }
        anchors.topMargin: Math.round(stage._pad / 2)
        // Amber while the audience screen is blanked or on the logo, so the
        // state shows across the whole width, not only in the tag.
        height: stage._blanked ? Math.max(2, Math.round(stage._pad / 5)) : 1
        color: stage._blanked ? stage._notesFg : stage._rule
    }

    // ── Footer: speaker notes and what is next ──────────────────────────
    // Declared before the body so the body can anchor to its top and take
    // whatever height is left. Hidden entirely when there is nothing to put
    // in either half, which gives the live text the whole screen for a song
    // with no notes and no next verse.
    Item {
        id: footer
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        anchors.margins: stage._pad
        visible: _hasNotes || stage._hasNext

        readonly property bool _hasNotes: stage._showNotes && stage._curNotes.length > 0
        readonly property real _gap: stage._pad
        readonly property real _inset: Math.round(stage._pad * 0.7)
        readonly property real _spacing: Math.round(stage._pad * 0.4)
        // Next only needs its label and two lines. Notes are prose the
        // preacher reads, so they get a fixed share of the screen.
        readonly property real _nextNeeds: _inset * 2 + nextHead.implicitHeight
                                           + (stage._nextLines.length > 0
                                              ? _spacing + nextLines.implicitHeight : 0)
        height: !visible ? 0
              : _hasNotes ? Math.max(Math.round(stage.height * 0.30), _nextNeeds)
              : _nextNeeds

        Rectangle {
            id: notesPanel
            visible: footer._hasNotes
            anchors { top: parent.top; bottom: parent.bottom; left: parent.left }
            // Notes take the larger share when both are present: notes are
            // read, next is a glance.
            width: stage._hasNext
                       ? Math.round((parent.width - footer._gap) * 0.6)
                       : parent.width
            color: stage._panel
            border.color: stage._rule
            border.width: 1

            Column {
                anchors.fill: parent
                anchors.margins: footer._inset
                spacing: footer._spacing

                Text {
                    id: notesHead
                    text: qsTr("NOTES")
                    color: stage._notesFg
                    font.family: Theme.font.family
                    font.pixelSize: stage._footSize
                    font.weight: Theme.font.weightBold
                    font.letterSpacing: 1
                }
                Text {
                    width: parent.width
                    height: parent.height - notesHead.height - parent.spacing
                    text: stage._curNotes
                    color: stage._text
                    wrapMode: Text.Wrap
                    elide: Text.ElideRight
                    font.family: Theme.font.family
                    font.pixelSize: Math.round(stage._footSize * 1.2)
                    // Fit rather than clip: a long note shrinks to fit its
                    // panel. Notes are the one thing on this screen the
                    // operator cannot re-read later. Plain text, where
                    // Qt's own fit works.
                    fontSizeMode: Text.Fit
                    minimumPixelSize: Math.max(9, Math.round(stage._footSize * 0.55))
                }
            }
        }

        Rectangle {
            id: nextPanel
            visible: stage._hasNext
            anchors { top: parent.top; bottom: parent.bottom; right: parent.right }
            width: footer._hasNotes
                       ? (parent.width - notesPanel.width - footer._gap)
                       : parent.width
            color: stage._panel
            border.color: stage._rule
            border.width: 1
            clip: true

            Column {
                anchors.fill: parent
                anchors.margins: footer._inset
                spacing: footer._spacing

                // "NEXT  Verse 2", or "NEXT ITEM  Amazing Grace" past the
                // last page.
                Text {
                    id: nextHead
                    width: parent.width
                    elide: Text.ElideRight
                    textFormat: Text.StyledText
                    text: "<b>" + (stage._next ? qsTr("NEXT") : qsTr("NEXT ITEM")) + "</b>"
                          + (stage._nextLabel.length > 0
                             ? "&nbsp;&nbsp;&nbsp;<font color=\"" + stage._accent + "\">"
                               + stage._escape(stage._nextLabel) + "</font>"
                             : "")
                    color: stage._dim
                    font.family: Theme.font.family
                    font.pixelSize: stage._footSize
                    font.letterSpacing: 1
                }
                Text {
                    id: nextLines
                    visible: stage._nextLines.length > 0
                    width: parent.width
                    text: stage._nextLines
                    textFormat: Text.PlainText
                    color: stage._text
                    opacity: 0.8
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    font.family: Theme.font.family
                    font.pixelSize: stage._nextSize
                    font.weight: Theme.font.weightMedium
                }
            }
        }
    }

    // ── Body: the live words, as large as they will go ──────────────────
    // The words are RichText (inline colour and bold), and Qt's own
    // fontSizeMode: Text.Fit does nothing for RichText, so the text used to
    // stay at its largest size and run over the header and the Next panel.
    // The size is found here instead, by the same probe-and-binary-search
    // NodeRenderer uses: the largest size at which the heading and the words
    // together fit the area. The area also clips, so nothing can ever draw
    // outside it.
    Item {
        id: body
        anchors {
            top: headerRule.bottom
            left: parent.left
            right: parent.right
            bottom: footer.visible ? footer.top : parent.bottom
        }
        anchors.margins: stage._pad
        visible: stage._hasLive
        clip: true

        // A presentation is a heading with points under it, read like a
        // page. Lyrics and scripture are centred, as on the audience screen.
        readonly property bool _isPage: stage._kind === "presentation"
        readonly property string _html: stage._rich(stage._curText)
        readonly property real _titleRatio: 1.15

        property int _size: stage._bodyMax
        function _gapFor(size) {
            return stage._curTitle.length > 0 && _html.length > 0 ? Math.round(size * 0.45) : 0
        }

        function _refit() {
            if (width <= 0 || height <= 0) return
            titleProbe.text = stage._curTitle
            bodyProbe.text = _html
            let lo = stage._bodyMin, hi = stage._bodyMax, best = stage._bodyMin
            while (lo <= hi) {
                const mid = (lo + hi) >> 1
                titleProbe.font.pixelSize = Math.round(mid * _titleRatio)
                bodyProbe.font.pixelSize = mid
                const h = (titleProbe.text.length > 0 ? titleProbe.paintedHeight : 0)
                        + _gapFor(mid)
                        + (bodyProbe.text.length > 0 ? bodyProbe.paintedHeight : 0)
                const w = Math.max(titleProbe.paintedWidth, bodyProbe.paintedWidth)
                if (h <= height && w <= width) {
                    best = mid
                    lo = mid + 1
                } else {
                    hi = mid - 1
                }
            }
            _size = best
        }

        // Synchronous, so a new slide appears at its fitted size in one
        // step rather than flashing at the largest size for a frame.
        readonly property string _fitKey: stage._curTitle + "\u0001" + _html
                                          + "\u0001" + width + "x" + height
        on_FitKeyChanged: _refit()
        Component.onCompleted: _refit()

        // Hidden measuring copies. Same width, wrap, weight and format as
        // what is drawn, so their painted size is the drawn size.
        Text {
            id: titleProbe
            visible: false
            width: body.width
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            font.family: Theme.font.family
            font.weight: Theme.font.weightBold
        }
        Text {
            id: bodyProbe
            visible: false
            width: body.width
            textFormat: Text.RichText
            wrapMode: Text.Wrap
            font.family: Theme.font.family
            font.weight: Theme.font.weightMedium
        }

        Column {
            width: parent.width
            // Centred when it fits. At the smallest size it can still be
            // taller than the area, and then the top stays in view.
            y: Math.max(0, Math.round((parent.height - height) / 2))
            spacing: body._gapFor(body._size)

            Text {
                width: parent.width
                visible: stage._curTitle.length > 0
                text: stage._curTitle
                textFormat: Text.PlainText
                color: stage._accent
                wrapMode: Text.Wrap
                horizontalAlignment: body._isPage ? Text.AlignLeft : Text.AlignHCenter
                font.family: Theme.font.family
                font.pixelSize: Math.round(body._size * body._titleRatio)
                font.weight: Theme.font.weightBold
            }
            Text {
                width: parent.width
                visible: body._html.length > 0
                text: body._html
                textFormat: Text.RichText
                color: stage._text
                wrapMode: Text.Wrap
                horizontalAlignment: body._isPage ? Text.AlignLeft : Text.AlignHCenter
                font.family: Theme.font.family
                font.pixelSize: body._size
                font.weight: Theme.font.weightMedium
            }
        }
    }

    // Nothing committed yet. Says so rather than showing a black rectangle
    // the operator cannot distinguish from a dead cable.
    Text {
        anchors.centerIn: parent
        visible: !stage._hasLive
        text: qsTr("Stage display ready")
        color: stage._dim
        font.family: Theme.font.family
        font.pixelSize: stage._titleSize
    }
}
