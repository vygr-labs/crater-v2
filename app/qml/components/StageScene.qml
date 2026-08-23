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
    // as ProjectionScene and so future per-output stage preferences —
    // "show notes", "show clock" — have somewhere obvious to hang.
    property string outputKind: "stage"

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
    readonly property string _nextText: (_next && _next.content) || ""
    readonly property string _nextTitle: (_next && _next.title) || ""

    readonly property string _itemTitle:
        (_item && (_item.title || _item.reference)) || ""

    readonly property bool _hasLive: _kind.length > 0 && _pageCount > 0

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

    // Type scale derived from height so the layout holds from a 720p
    // confidence monitor to a 4K panel without a second set of numbers.
    readonly property int _chromeSize: Math.max(11, Math.round(height * 0.026))
    readonly property int _titleSize:  Math.max(14, Math.round(height * 0.042))
    readonly property int _bodyMax:    Math.max(20, Math.round(height * 0.115))
    readonly property int _footSize:   Math.max(12, Math.round(height * 0.030))
    readonly property int _pad:        Math.max(12, Math.round(height * 0.030))

    // Inline lyric/scripture markup ({color=…}, **bold**) reaches us in the
    // same DSL the audience renderer receives. Route it through the same
    // service so a highlighted verse reads identically on both screens
    // rather than showing raw markers here.
    function _rich(s) {
        return s.length > 0 ? LyricsService.dslToHtml(s, "") : ""
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
            width: parent.width - counter.width - clock.width - stage._pad * 2
            text: stage._itemTitle
            color: stage._accent
            elide: Text.ElideRight
            font.family: Theme.font.family
            font.pixelSize: stage._chromeSize
            font.weight: Theme.font.weightSemiBold
        }

        Text {
            id: counter
            anchors.right: clock.left
            anchors.rightMargin: stage._pad
            anchors.verticalCenter: parent.verticalCenter
            visible: stage._pageCount > 0
            text: (stage._page + 1) + " / " + stage._pageCount
            color: stage._dim
            font.family: Theme.font.family
            font.pixelSize: stage._chromeSize
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
        height: 1
        color: stage._rule
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
        height: visible ? Math.round(stage.height * 0.26) : 0
        visible: stage._curNotes.length > 0 || stage._nextText.length > 0
                 || stage._nextTitle.length > 0

        // Notes take two thirds when both are present: notes are prose the
        // preacher reads, next is a glance.
        readonly property bool _hasNotes: stage._curNotes.length > 0
        readonly property bool _hasNext:  stage._nextText.length > 0
                                       || stage._nextTitle.length > 0
        readonly property real _gap: stage._pad

        Rectangle {
            id: notesPanel
            visible: footer._hasNotes
            anchors { top: parent.top; bottom: parent.bottom; left: parent.left }
            width: footer._hasNext
                       ? Math.round((parent.width - footer._gap) * 0.62)
                       : parent.width
            color: stage._panel
            border.color: stage._rule
            border.width: 1

            Column {
                anchors.fill: parent
                anchors.margins: Math.round(stage._pad * 0.7)
                spacing: Math.round(stage._pad * 0.4)

                Text {
                    text: qsTr("NOTES")
                    color: stage._notesFg
                    font.family: Theme.font.family
                    font.pixelSize: Math.round(stage._footSize * 0.8)
                    font.weight: Theme.font.weightBold
                    font.letterSpacing: 2
                }
                Text {
                    width: parent.width
                    height: parent.height - stage._footSize * 1.6
                    text: stage._curNotes
                    color: stage._text
                    wrapMode: Text.Wrap
                    elide: Text.ElideRight
                    font.family: Theme.font.family
                    font.pixelSize: stage._footSize
                    // Fit rather than clip: a long note shrinks to fit its
                    // panel. Notes are the one thing on this screen the
                    // operator cannot re-read later.
                    fontSizeMode: Text.Fit
                    minimumPixelSize: Math.max(9, Math.round(stage._footSize * 0.55))
                }
            }
        }

        Rectangle {
            id: nextPanel
            visible: footer._hasNext
            anchors { top: parent.top; bottom: parent.bottom; right: parent.right }
            width: footer._hasNotes
                       ? (parent.width - notesPanel.width - footer._gap)
                       : parent.width
            color: stage._panel
            border.color: stage._rule
            border.width: 1

            Column {
                anchors.fill: parent
                anchors.margins: Math.round(stage._pad * 0.7)
                spacing: Math.round(stage._pad * 0.4)

                Text {
                    text: qsTr("NEXT")
                    color: stage._dim
                    font.family: Theme.font.family
                    font.pixelSize: Math.round(stage._footSize * 0.8)
                    font.weight: Theme.font.weightBold
                    font.letterSpacing: 2
                }
                Text {
                    width: parent.width
                    height: parent.height - stage._footSize * 1.6
                    text: stage._nextTitle.length > 0
                              ? stage._nextTitle + (stage._nextText.length > 0
                                                        ? "\n" + stage._nextText : "")
                              : stage._nextText
                    color: stage._dim
                    wrapMode: Text.Wrap
                    elide: Text.ElideRight
                    font.family: Theme.font.family
                    font.pixelSize: stage._footSize
                    fontSizeMode: Text.Fit
                    minimumPixelSize: Math.max(9, Math.round(stage._footSize * 0.55))
                }
            }
        }
    }

    // ── Body: the live words, as large as they will go ──────────────────
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

        Text {
            id: slideTitle
            anchors { top: parent.top; left: parent.left; right: parent.right }
            visible: stage._curTitle.length > 0
            height: visible ? implicitHeight : 0
            text: stage._curTitle
            color: stage._accent
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
            font.family: Theme.font.family
            font.pixelSize: stage._titleSize
            font.weight: Theme.font.weightBold
        }

        Text {
            anchors {
                top: slideTitle.visible ? slideTitle.bottom : parent.top
                topMargin: slideTitle.visible ? Math.round(stage._pad * 0.6) : 0
                left: parent.left
                right: parent.right
                bottom: parent.bottom
            }
            text: stage._rich(stage._curText)
            textFormat: Text.RichText
            color: stage._text
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            font.family: Theme.font.family
            font.pixelSize: stage._bodyMax
            font.weight: Theme.font.weightMedium
            // Qt's own fit, not the binary search NodeRenderer runs. That
            // one exists because a theme node must land on an exact pixel
            // size shared with a hidden measuring probe; here nothing else
            // depends on the resolved size, so the built-in mode is both
            // correct and much cheaper.
            fontSizeMode: Text.Fit
            minimumPixelSize: Math.max(14, Math.round(stage._bodyMax * 0.28))
        }
    }

    // ── Status overlays ─────────────────────────────────────────────────
    // The audience screen being blanked or showing the logo is information
    // the person on stage needs — otherwise they keep preaching to a black
    // screen believing their point is up. Shown as a banner rather than by
    // blanking this screen too: the notes stay readable through a blank,
    // which is the entire reason to blank in the first place.
    Rectangle {
        anchors.centerIn: body
        width: blankLabel.implicitWidth + stage._pad * 2
        height: blankLabel.implicitHeight + stage._pad
        visible: stage._clear || stage._logo
        color: "#cc000000"
        border.color: stage._rule
        border.width: 1

        Text {
            id: blankLabel
            anchors.centerIn: parent
            text: stage._logo ? qsTr("LOGO ON SCREEN") : qsTr("SCREEN BLANKED")
            color: stage._notesFg
            font.family: Theme.font.family
            font.pixelSize: stage._titleSize
            font.weight: Theme.font.weightBold
            font.letterSpacing: 3
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
