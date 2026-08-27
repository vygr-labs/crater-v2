import QtQuick
import QtQuick.Controls.Basic
import Crater

// Presentation editor — writes the sermon-notes deck the Presentations tab
// projects. Bound to modalProps:
//   presentationId: the deck to edit.
//
// Each slide picks a DESIGN from the theme, the way a PowerPoint slide picks
// a layout from its template, and the fields on offer follow from that
// choice:
//
//   Design         — which of the theme's layouts draws this slide. Chosen
//                    from live thumbnails of the real designs (LayoutStrip),
//                    because an operator picks "the one with the big centred
//                    heading", not the words "Section divider".
//   Title / Body /
//   Subtitle /
//   Right column /
//   Picture        — what the CONGREGATION sees. Which of these appear is
//                    DERIVED from the chosen design by scanning its nodes
//                    (ThemeService.layoutSlots), so a section divider does
//                    not offer a body box that renders nowhere, and nothing
//                    has to be kept in sync by hand.
//   Speaker notes  — what only the PREACHER sees. Never reaches the audience
//                    render; read solely by StageScene, so it appears on an
//                    output whose contentMode is "stage" and nowhere else.
//                    Always offered, whatever the design: notes are for the
//                    person talking, not for the layout.
//
// Everything is edited against an in-memory working copy and committed on
// Save. That is not just tidiness: the deck being edited may be the one
// currently live, and ProjectionService snapshots on goLive precisely so a
// half-typed sentence cannot reach the screen. Saving mid-service refreshes
// the operator's Preview; the audience output does not move until the next
// deliberate commit.
ModalShell {
    id: root

    dialogWidth: 1040
    dialogHeight: 760
    title: qsTr("Edit presentation")

    readonly property int deckId: AppState.modalProps.presentationId || 0
    readonly property var deck:   PresentationService.presentation(deckId)
    readonly property bool _valid: !!deck && (deck.id || 0) > 0

    // ── Working copy ────────────────────────────────────────────────────
    property string _title:   ""
    property var    _slides:  []
    property int    _sel:     0
    property int    _themeId: 0
    // Suppresses the write-back that firing a TextEdit's onTextChanged
    // would otherwise cause while we are loading a slide INTO the fields.
    property bool   _loading: false

    // The selected slide, for READS. Deliberately not the dependency any
    // derived property binds to: _setField reassigns _slides with slice(),
    // which is a SHALLOW copy, so this re-evaluates to the very same object
    // reference and QML suppresses the change signal. Anything that has to
    // update when a field changes must read through _slides itself - see
    // _slideOf below - or it will silently never fire.
    readonly property var _cur:
        (_sel >= 0 && _sel < _slides.length) ? _slides[_sel] : null

    // Same slide, reached in a way that DOES create a dependency on _slides
    // (and on _sel). Bindings that call this re-evaluate on every notifying
    // _setField, because QML captures property reads made inside a called
    // function just as it does inline ones.
    function _slideOf() {
        return (_sel >= 0 && _sel < _slides.length) ? _slides[_sel] : null
    }

    Component.onCompleted: {
        if (!_valid) return
        _title   = deck.title
        _themeId = deck.themeId || 0
        // Deep copy. PresentationService hands back fresh QVariantMaps, but
        // taking a copy here makes the "nothing is written until Save" rule
        // true by construction rather than by trusting the service.
        const src = PresentationService.slides(deckId)
        let out = []
        for (let i = 0; i < src.length; i++) out.push(_copySlide(src[i]))
        if (out.length === 0) out.push(_blankSlide(""))
        _slides = out
        _sel = 0
        _loadSlideIntoFields()
    }

    // One place that knows a slide's shape. Everything that mints or copies
    // a slide goes through these two, so adding a field later cannot leave
    // one of the four creation paths behind.
    function _blankSlide(layoutId) {
        return { title: "", body: "", notes: "",
                 layout: layoutId || "", subtitle: "", bodyRight: "", mediaId: 0 }
    }

    function _copySlide(s) {
        const v = s || {}
        return { title:     v.title     || "",
                 body:      v.body      || "",
                 notes:     v.notes     || "",
                 layout:    v.layout    || "",
                 subtitle:  v.subtitle  || "",
                 bodyRight: v.bodyRight || "",
                 mediaId:   v.mediaId   || 0 }
    }

    function _loadSlideIntoFields() {
        _loading = true
        const s = _cur || _blankSlide("")
        titleField.text     = s.title
        bodyField.text      = s.body
        notesField.text     = s.notes
        subtitleField.text  = s.subtitle
        bodyRightField.text = s.bodyRight
        _loading = false
    }

    // Fields that something OTHER than their own input reads, and so must
    // notify when they change:
    //   title / subtitle - the slide list's row label (subtitle is its
    //                      second fallback)
    //   layout           - the design strip's selection, the derived slot
    //                      set, and the row's design caption
    //   mediaId          - the picture row's name and clear button
    //
    // Mutating _slides[_sel] in place does NOT fire a binding: QML never
    // notifies on a sub-path of a `property var`, so the array has to be
    // reassigned to re-emit. Getting this wrong is silent - the value is
    // stored correctly and simply nothing on screen moves, which is exactly
    // how picking a design did nothing at all the first time round.
    //
    // body / bodyRight / notes are deliberately NOT in the list. Nothing but
    // their own TextEdit displays them, and reassigning on every keystroke
    // would rebuild every visible slide-list delegate mid-sentence.
    readonly property var _notifyingFields: ({
        "title": true, "subtitle": true, "layout": true, "mediaId": true
    })

    function _setField(field, value) {
        if (_loading) return
        if (_sel < 0 || _sel >= _slides.length) return
        _slides[_sel][field] = value
        if (_notifyingFields[field]) _slides = _slides.slice()
    }

    function _select(i) {
        if (i < 0 || i >= _slides.length) return
        _sel = i
        _loadSlideIntoFields()
    }

    // A new slide inherits the current slide's DESIGN rather than resetting
    // to the theme default. Decks are built in runs — five content slides,
    // then a divider — so inheriting is right far more often than not, and
    // the strip is one click away when it is not. It also means there is no
    // second layout picker hiding behind the + button.
    function _addSlide() {
        let out = _slides.slice()
        out.splice(_sel + 1, 0, _blankSlide(_cur ? _cur.layout : ""))
        _slides = out
        _select(_sel + 1)
        titleField.forceActiveFocus()
    }

    function _duplicateSlide() {
        if (!_cur) return
        let out = _slides.slice()
        out.splice(_sel + 1, 0, _copySlide(_cur))
        _slides = out
        _select(_sel + 1)
    }

    function _deleteSlide() {
        // Never drop to zero slides: a deck with no slides cannot be
        // projected, and an empty editor gives the operator nothing to type
        // into. Deleting the last one clears it instead.
        if (_slides.length <= 1) {
            _slides = [_blankSlide(_cur ? _cur.layout : "")]
            _select(0)
            return
        }
        let out = _slides.slice()
        out.splice(_sel, 1)
        _slides = out
        _select(Math.min(_sel, out.length - 1))
    }

    function _moveSlide(delta) {
        const to = _sel + delta
        if (to < 0 || to >= _slides.length) return
        let out = _slides.slice()
        const moved = out.splice(_sel, 1)[0]
        out.splice(to, 0, moved)
        _slides = out
        _select(to)
    }

    function _save() {
        if (!_valid) return
        const name = _title.trim()
        // A deck with no title is unfindable in a list whose only column is
        // the title, so an empty one is refused rather than silently stored.
        if (name.length === 0) {
            titleField.forceActiveFocus()
            return
        }
        PresentationService.rename(deckId, name)
        PresentationService.saveSlides(deckId, _slides)
        PresentationService.setThemeId(deckId, _themeId)
        AppState.closeModal()
    }

    // ── Resolved theme + the current slide's design ─────────────────────
    // The strip and the derived field set both need the theme this deck will
    // actually render with. That is the per-deck override when set, and the
    // per-kind default otherwise — the same fall-through
    // AppState.resolveItemTheme performs, minus the per-output slot, which
    // the editor has no single answer for (a deck can go to two outputs with
    // different pins). Editing against the default is the honest choice: it
    // is what the operator sees in Preview.
    //
    // The revision int forces re-evaluation when a theme is edited or the
    // default-for-kind changes while this dialog is open, mirroring the
    // pattern ThemedMonitor and ProjectionWindow already use.
    property int _themeRevision: 0

    Connections {
        target: ThemeService
        function onAllThemesChanged() { root._themeRevision++ }
        function onDefaultsChanged()  { root._themeRevision++ }
    }

    readonly property var _resolvedTheme: {
        _themeRevision   // dependency
        if (_themeId > 0) {
            const t = ThemeService.theme(_themeId)
            if (t && (t.id || 0) > 0) return t
        }
        return ThemeService.defaultFor("presentation")
    }

    readonly property var _themeTokens:
        _resolvedTheme && _resolvedTheme.tokens ? _resolvedTheme.tokens : ({})

    readonly property string _curLayout: {
        const s = _slideOf()
        return s ? (s.layout || "") : ""
    }

    // Likewise for the picture: the row's label, its clear button and the
    // popover's current selection all have to move when the slide's media
    // changes, and all three read this rather than _cur.mediaId.
    readonly property int _curMediaId: {
        const s = _slideOf()
        return s ? (s.mediaId || 0) : 0
    }

    // Which fields this design binds. Derived from the design's nodes, never
    // declared — see crater::tokens::layoutSlots. A design with no body node
    // yields body:false and the body box simply is not offered.
    readonly property var _slots: ThemeService.layoutSlots(_themeTokens, _curLayout)

    // True when the slide names a design this theme does not have, which
    // happens whenever a deck is moved between themes. The renderer falls
    // back to the theme's default; the editor says so rather than letting
    // the fallback pass for a choice.
    readonly property bool _layoutMissing:
        _curLayout.length > 0 && !ThemeService.hasLayout(_themeTokens, _curLayout)

    function _layoutNameOf(slide) {
        const id = (slide && slide.layout) || ""
        if (id.length === 0) return ""
        const all = ThemeService.themeLayouts(_themeTokens)
        for (let i = 0; i < all.length; i++) {
            if (all[i].id === id) return all[i].name
        }
        return ThemeService.defaultLayoutName(id)
    }

    // ── Theme picker options ────────────────────────────────────────────
    // Presentation-kind themes only, plus a "Default" entry that clears the
    // per-deck override so the deck follows whatever the output pin or the
    // per-kind default resolves to.
    readonly property var _themeOptions: {
        const all = ThemeService.allThemes
        let out = [{ label: qsTr("Default presentation theme"), value: "0" }]
        for (let i = 0; i < all.length; i++) {
            if (all[i].kind !== "presentation") continue
            out.push({ label: all[i].name, value: String(all[i].id) })
        }
        return out
    }
    readonly property string _themeLabel: {
        const opts = _themeOptions
        const want = String(_themeId)
        for (let i = 0; i < opts.length; i++) {
            if (opts[i].value === want) return opts[i].label
        }
        // The pinned theme was deleted. Say so rather than silently reading
        // as "Default", which would hide that the deck lost its look.
        return qsTr("(missing theme)")
    }

    Item {
        anchors.fill: parent
        anchors.margins: Theme.space.lg

        // ── Footer (declared first so the body can anchor above it) ──────
        Item {
            id: footer
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: 40

            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.space.sm

                GhostButton {
                    text: qsTr("Cancel")
                    onClicked: AppState.closeModal()
                }
                PrimaryButton {
                    text: qsTr("Save")
                    enabled: root._valid
                    onClicked: root._save()
                }
            }
        }

        // ── Deck title + theme ───────────────────────────────────────────
        Rectangle {
            id: header
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: 44
            color: Theme.color.canvas
            border.color: deckTitleInput.activeFocus ? Theme.color.brand
                                                     : Theme.color.borderStrong
            border.width: 1

            TextInput {
                id: deckTitleInput
                anchors.left: parent.left
                anchors.right: themeWrap.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.leftMargin: Theme.space.md
                anchors.rightMargin: Theme.space.md
                verticalAlignment: TextInput.AlignVCenter
                color: Theme.color.textPrimary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize + 3
                font.weight: Theme.font.weightSemiBold
                selectByMouse: true
                text: root._title
                onTextEdited: root._title = text

                Text {
                    visible: deckTitleInput.text.length === 0
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Sermon title…")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize + 3
                    font.weight: Theme.font.weightSemiBold
                }
            }

            Item {
                id: themeWrap
                anchors.right: parent.right
                anchors.rightMargin: Theme.space.sm
                anchors.verticalCenter: parent.verticalCenter
                width: 260
                height: 32
                // The combobox popover reparents to the window root, so this
                // wrapper only needs to reserve the trigger's footprint.
                z: 5

                Combobox {
                    anchors.fill: parent
                    searchable: root._themeOptions.length > 8
                    options: root._themeOptions
                    value: root._themeLabel
                    placeholder: qsTr("Theme")
                    onValueSelected: function(v) {
                        const n = parseInt(v, 10)
                        root._themeId = isNaN(n) ? 0 : n
                    }
                }
            }
        }

        // ── Slide list ───────────────────────────────────────────────────
        Rectangle {
            id: slidePane
            anchors.top: header.bottom
            anchors.topMargin: Theme.space.md
            anchors.bottom: footer.top
            anchors.bottomMargin: Theme.space.md
            anchors.left: parent.left
            width: 260
            color: Theme.color.canvas
            border.color: Theme.color.borderSubtle
            border.width: 1

            ListView {
                id: slideList
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: slideTools.top
                anchors.margins: 1
                clip: true
                model: root._slides
                currentIndex: root._sel
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: AppScrollBar {}

                delegate: Item {
                    width: slideList.width - Theme.size.scrollBar
                    height: 52

                    readonly property bool _isSel: index === root._sel

                    Rectangle {
                        anchors.fill: parent
                        color: parent._isSel     ? Theme.color.brandSubtle
                             : slideMa.containsMouse ? Theme.color.overlay
                                                     : "transparent"
                    }

                    Text {
                        id: num
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.space.md
                        anchors.verticalCenter: parent.verticalCenter
                        width: 20
                        text: index + 1
                        color: Theme.color.textTertiary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                    }

                    Column {
                        anchors.left: num.right
                        anchors.leftMargin: Theme.space.sm
                        anchors.right: notesDot.left
                        anchors.rightMargin: Theme.space.sm
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 1

                        Text {
                            width: parent.width
                            // Falls back to the body so a body-only slide is
                            // still identifiable in the list. An untitled,
                            // empty slide reads as "Empty slide" rather than
                            // as a blank row indistinguishable from its
                            // neighbours.
                            text: {
                                const s = modelData || {}
                                if ((s.title || "").length > 0) return s.title
                                if ((s.body || "").length > 0)  return s.body
                                if ((s.subtitle || "").length > 0) return s.subtitle
                                return qsTr("Empty slide")
                            }
                            elide: Text.ElideRight
                            maximumLineCount: 1
                            color: (modelData && ((modelData.title || "").length > 0
                                                  || (modelData.body || "").length > 0))
                                       ? Theme.color.textPrimary
                                       : Theme.color.textTertiary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.smallSize
                            font.weight: Theme.font.weightMedium
                        }

                        // Which design draws this slide. Shown per row so a
                        // deck reads as a structure at a glance -- title,
                        // divider, three content slides -- instead of as an
                        // undifferentiated stack. Blank for a slide on the
                        // theme's default, which needs no label.
                        Text {
                            width: parent.width
                            visible: text.length > 0
                            text: root._layoutNameOf(modelData)
                            elide: Text.ElideRight
                            maximumLineCount: 1
                            color: Theme.color.textTertiary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.smallSize - 1
                        }
                    }

                    // A dot marks slides that carry speaker notes, so the
                    // operator can see at a glance which points the preacher
                    // has written against without clicking through each one.
                    Rectangle {
                        id: notesDot
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.space.md
                        anchors.verticalCenter: parent.verticalCenter
                        width: 6; height: 6; radius: 3
                        visible: modelData && (modelData.notes || "").length > 0
                        color: Theme.color.warning
                    }

                    MouseArea {
                        id: slideMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root._select(index)
                    }
                }
            }

            Row {
                id: slideTools
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.leftMargin: Theme.space.sm
                anchors.bottomMargin: Theme.space.sm
                spacing: 2

                GhostButton { iconName: "plus";        onClicked: root._addSlide() }
                GhostButton { iconName: "copy";        onClicked: root._duplicateSlide() }
                GhostButton { iconName: "chevron-up";   onClicked: root._moveSlide(-1) }
                GhostButton { iconName: "chevron-down"; onClicked: root._moveSlide(1) }
                GhostButton { iconName: "trash";       onClicked: root._deleteSlide() }
            }
        }

        // ── Slide fields ─────────────────────────────────────────────────
        // Which boxes appear is driven entirely by root._slots, derived from
        // the chosen design. Column skips invisible children outright, so a
        // hidden field costs no gap either.
        Column {
            id: fields
            anchors.top: header.bottom
            anchors.topMargin: Theme.space.md
            anchors.bottom: footer.top
            anchors.bottomMargin: Theme.space.md
            anchors.left: slidePane.right
            anchors.leftMargin: Theme.space.md
            anchors.right: parent.right
            spacing: Theme.space.sm

            // Multiline boxes share whatever is left after the design strip
            // and the single-line rows, so a design with four text fields
            // and one with two both fill the pane instead of overflowing or
            // leaving a gap.
            //
            // Measuring against `height` is safe here specifically because
            // this Column is anchored top AND bottom: its height comes from
            // the anchors, not from its children, so reading it back inside
            // a child's height is not the binding loop it would be in a
            // Column that sized itself to its content.
            readonly property int _labelH: Theme.font.smallSize + 5
            readonly property int _multiCount:
                (root._slots.body ? 1 : 0) + (root._slots.bodyRight ? 1 : 0)

            // Everything that is NOT a multiline box, plus the gaps between
            // every visible row. Counted from the same _slots the fields
            // themselves are gated on, so hiding a field cannot leave its
            // height reserved.
            readonly property int _fixedH: {
                let h = _labelH + 96            // Design label + strip
                let rows = 2
                if (root._slots.title)     { h += _labelH + 36; rows += 2 }
                if (root._slots.subtitle)  { h += _labelH + 36; rows += 2 }
                if (root._slots.image)     { h += _labelH + 40; rows += 2 }
                if (root._slots.body)      { h += _labelH;      rows += 1 }
                if (root._slots.bodyRight) { h += _labelH;      rows += 1 }
                h += _labelH + 90; rows += 2    // Speaker notes label + box
                rows += _multiCount
                return h + Math.max(0, rows - 1) * spacing
            }

            // The floor matters more than the split: a design with two
            // columns AND a picture leaves little room, and a box too short
            // to show one line is worse than a pane that scrolls slightly
            // out of view.
            readonly property int _multiH:
                _multiCount <= 0 ? 0
                                 : Math.max(72, Math.floor((height - _fixedH) / _multiCount))

            // ── Design ───────────────────────────────────────────────────
            FieldLabel {
                label:  qsTr("Design")
                detail: root._layoutMissing
                            ? qsTr("this theme has no such design, showing its default")
                            : qsTr("from the theme")
            }

            LayoutStrip {
                width: parent.width
                height: 96
                theme: root._resolvedTheme
                layoutId: root._curLayout
                onLayoutPicked: function(id) { root._setField("layout", id) }
            }

            // ── Title ────────────────────────────────────────────────────
            FieldLabel { visible: root._slots.title; label: qsTr("Slide title") }

            Rectangle {
                visible: root._slots.title
                width: parent.width
                height: 36
                color: Theme.color.canvas
                border.color: titleField.activeFocus ? Theme.color.brand
                                                     : Theme.color.borderStrong
                border.width: 1

                TextInput {
                    id: titleField
                    anchors.fill: parent
                    anchors.leftMargin: Theme.space.md
                    anchors.rightMargin: Theme.space.md
                    verticalAlignment: TextInput.AlignVCenter
                    color: Theme.color.textPrimary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize
                    selectByMouse: true
                    onTextChanged: root._setField("title", text)

                    Text {
                        visible: titleField.text.length === 0
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Heading shown on the slide")
                        color: Theme.color.textTertiary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.bodySize
                    }
                }
            }

            // ── Subtitle ─────────────────────────────────────────────────
            FieldLabel { visible: root._slots.subtitle; label: qsTr("Subtitle") }

            Rectangle {
                visible: root._slots.subtitle
                width: parent.width
                height: 36
                color: Theme.color.canvas
                border.color: subtitleField.activeFocus ? Theme.color.brand
                                                        : Theme.color.borderStrong
                border.width: 1

                TextInput {
                    id: subtitleField
                    anchors.fill: parent
                    anchors.leftMargin: Theme.space.md
                    anchors.rightMargin: Theme.space.md
                    verticalAlignment: TextInput.AlignVCenter
                    color: Theme.color.textPrimary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize
                    selectByMouse: true
                    onTextChanged: root._setField("subtitle", text)

                    Text {
                        visible: subtitleField.text.length === 0
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Series, date or reference")
                        color: Theme.color.textTertiary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.bodySize
                    }
                }
            }

            // ── Picture ──────────────────────────────────────────────────
            FieldLabel { visible: root._slots.image; label: qsTr("Picture") }

            Rectangle {
                id: pictureSlot
                visible: root._slots.image
                width: parent.width
                height: 40
                color: Theme.color.canvas
                border.color: pictureMa.containsMouse ? Theme.color.borderStrong
                                                      : Theme.color.borderSubtle
                border.width: 1

                // The chosen media's own title, looked up per render rather
                // than copied onto the slide: renaming a picture in the Media
                // tab should not leave a stale name sitting in a deck.
                readonly property string _mediaTitle: {
                    const id = root._curMediaId
                    if (id <= 0) return ""
                    const m = MediaService.byId(id)
                    return (m && m.title) || ""
                }

                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.space.md
                    anchors.right: clearPic.left
                    anchors.rightMargin: Theme.space.sm
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    maximumLineCount: 1
                    text: pictureSlot._mediaTitle.length > 0
                              ? pictureSlot._mediaTitle
                              : qsTr("Choose a picture")
                    color: pictureSlot._mediaTitle.length > 0 ? Theme.color.textPrimary
                                                              : Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize
                }

                GhostButton {
                    id: clearPic
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.space.xs
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root._curMediaId > 0
                    iconName: "x"
                    onClicked: root._setField("mediaId", 0)
                }

                MouseArea {
                    id: pictureMa
                    anchors.fill: parent
                    anchors.rightMargin: clearPic.visible ? clearPic.width : 0
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: mediaPicker.openAt(pictureSlot)
                }
            }

            // ── Body ─────────────────────────────────────────────────────
            FieldLabel {
                visible: root._slots.body
                label: root._slots.bodyRight ? qsTr("Left column") : qsTr("Slide body")
            }

            Rectangle {
                visible: root._slots.body
                width: parent.width
                height: fields._multiH
                color: Theme.color.canvas
                border.color: bodyField.activeFocus ? Theme.color.brand
                                                    : Theme.color.borderStrong
                border.width: 1

                Flickable {
                    id: bodyScroll
                    anchors.fill: parent
                    anchors.margins: Theme.space.sm
                    contentHeight: Math.max(height, bodyField.contentHeight)
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: AppScrollBar {}

                    TextEdit {
                        id: bodyField
                        width: bodyScroll.width - Theme.size.scrollBar
                        height: Math.max(contentHeight, bodyScroll.height)
                        color: Theme.color.textPrimary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.bodySize
                        selectByMouse: true
                        wrapMode: TextEdit.Wrap
                        onTextChanged: root._setField("body", text)

                        Text {
                            visible: bodyField.text.length === 0
                            text: root._slots.bodyRight
                                      ? qsTr("Left-hand text.")
                                      : qsTr("What the congregation reads. One point per slide.")
                            color: Theme.color.textTertiary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.bodySize
                        }
                    }
                }
            }

            // ── Right column ─────────────────────────────────────────────
            FieldLabel { visible: root._slots.bodyRight; label: qsTr("Right column") }

            Rectangle {
                visible: root._slots.bodyRight
                width: parent.width
                height: fields._multiH
                color: Theme.color.canvas
                border.color: bodyRightField.activeFocus ? Theme.color.brand
                                                         : Theme.color.borderStrong
                border.width: 1

                Flickable {
                    id: bodyRightScroll
                    anchors.fill: parent
                    anchors.margins: Theme.space.sm
                    contentHeight: Math.max(height, bodyRightField.contentHeight)
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: AppScrollBar {}

                    TextEdit {
                        id: bodyRightField
                        width: bodyRightScroll.width - Theme.size.scrollBar
                        height: Math.max(contentHeight, bodyRightScroll.height)
                        color: Theme.color.textPrimary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.bodySize
                        selectByMouse: true
                        wrapMode: TextEdit.Wrap
                        onTextChanged: root._setField("bodyRight", text)

                        Text {
                            visible: bodyRightField.text.length === 0
                            text: qsTr("Right-hand text.")
                            color: Theme.color.textTertiary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.bodySize
                        }
                    }
                }
            }

            // ── Speaker notes ────────────────────────────────────────────
            FieldLabel {
                label:  qsTr("Speaker notes")
                detail: qsTr("stage monitor only, never shown to the audience")
            }

            Rectangle {
                width: parent.width
                height: 90
                color: Theme.color.canvas
                border.color: notesField.activeFocus ? Theme.color.brand
                                                     : Theme.color.borderStrong
                border.width: 1

                Flickable {
                    id: notesScroll
                    anchors.fill: parent
                    anchors.margins: Theme.space.sm
                    contentHeight: Math.max(height, notesField.contentHeight)
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: AppScrollBar {}

                    TextEdit {
                        id: notesField
                        width: notesScroll.width - Theme.size.scrollBar
                        height: Math.max(contentHeight, notesScroll.height)
                        color: Theme.color.textPrimary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.bodySize
                        selectByMouse: true
                        wrapMode: TextEdit.Wrap
                        onTextChanged: root._setField("notes", text)

                        Text {
                            visible: notesField.text.length === 0
                            text: qsTr("Your prompts for this point.")
                            color: Theme.color.textTertiary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.bodySize
                        }
                    }
                }
            }
        }
    }

    // Floating picture picker, reparented to the window root on openAt() so
    // the list is not clipped by the dialog's own bounds.
    MediaPickerPopover {
        id: mediaPicker
        targetId: root._curMediaId
        onMediaChosen: function(id) { root._setField("mediaId", id) }
    }

    // Small label + optional muted qualifier. Inline component rather than a
    // shared control: three uses, all in this file, and none of them wants
    // the padding or hierarchy a general form-label control would carry.
    component FieldLabel: Row {
        id: fieldLabel

        property string label: ""
        property string detail: ""

        spacing: Theme.space.sm

        Text {
            text: fieldLabel.label
            color: Theme.color.textSecondary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.smallSize
            font.weight: Theme.font.weightSemiBold
        }
        Text {
            visible: fieldLabel.detail.length > 0
            anchors.verticalCenter: parent.verticalCenter
            text: fieldLabel.detail
            color: Theme.color.textTertiary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.smallSize
        }
    }
}
