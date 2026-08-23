import QtQuick
import QtQuick.Controls.Basic
import Crater

// Presentation editor — writes the sermon-notes deck the Presentations tab
// projects. Bound to modalProps:
//   presentationId: the deck to edit.
//
// Three fields per slide, and the split between them is the whole feature:
//
//   Title / Body   — what the CONGREGATION sees. Bound by a presentation
//                    theme's presentationTitle / presentationBody text nodes.
//   Speaker notes  — what only the PREACHER sees. Never reaches the audience
//                    render; read solely by StageScene, so it appears on an
//                    output whose contentMode is "stage" and nowhere else.
//
// Everything is edited against an in-memory working copy and committed on
// Save. That is not just tidiness: the deck being edited may be the one
// currently live, and ProjectionService snapshots on goLive precisely so a
// half-typed sentence cannot reach the screen. Saving mid-service refreshes
// the operator's Preview; the audience output does not move until the next
// deliberate commit.
ModalShell {
    id: root

    dialogWidth: 960
    dialogHeight: 660
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

    readonly property var _cur:
        (_sel >= 0 && _sel < _slides.length) ? _slides[_sel] : null

    Component.onCompleted: {
        if (!_valid) return
        _title   = deck.title
        _themeId = deck.themeId || 0
        // Deep copy. PresentationService hands back fresh QVariantMaps, but
        // taking a copy here makes the "nothing is written until Save" rule
        // true by construction rather than by trusting the service.
        const src = PresentationService.slides(deckId)
        let out = []
        for (let i = 0; i < src.length; i++) {
            const s = src[i] || {}
            out.push({ title: s.title || "", body: s.body || "", notes: s.notes || "" })
        }
        if (out.length === 0) out.push({ title: "", body: "", notes: "" })
        _slides = out
        _sel = 0
        _loadSlideIntoFields()
    }

    function _loadSlideIntoFields() {
        _loading = true
        const s = _cur || { title: "", body: "", notes: "" }
        titleField.text = s.title
        bodyField.text  = s.body
        notesField.text = s.notes
        _loading = false
    }

    function _setField(field, value) {
        if (_loading) return
        if (_sel < 0 || _sel >= _slides.length) return
        _slides[_sel][field] = value
        // Only the title shows in the slide list, so only a title edit needs
        // the model to re-emit. Reassigning the array on every body or notes
        // keystroke would rebuild every visible delegate for a change none of
        // them display.
        if (field === "title") _slides = _slides.slice()
    }

    function _select(i) {
        if (i < 0 || i >= _slides.length) return
        _sel = i
        _loadSlideIntoFields()
    }

    function _addSlide() {
        let out = _slides.slice()
        out.splice(_sel + 1, 0, { title: "", body: "", notes: "" })
        _slides = out
        _select(_sel + 1)
        titleField.forceActiveFocus()
    }

    function _duplicateSlide() {
        if (!_cur) return
        let out = _slides.slice()
        out.splice(_sel + 1, 0,
                   { title: _cur.title, body: _cur.body, notes: _cur.notes })
        _slides = out
        _select(_sel + 1)
    }

    function _deleteSlide() {
        // Never drop to zero slides: a deck with no slides cannot be
        // projected, and an empty editor gives the operator nothing to type
        // into. Deleting the last one clears it instead.
        if (_slides.length <= 1) {
            _slides = [{ title: "", body: "", notes: "" }]
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
                    height: 44

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
        Column {
            anchors.top: header.bottom
            anchors.topMargin: Theme.space.md
            anchors.bottom: footer.top
            anchors.bottomMargin: Theme.space.md
            anchors.left: slidePane.right
            anchors.leftMargin: Theme.space.md
            anchors.right: parent.right
            spacing: Theme.space.sm

            FieldLabel { label: qsTr("Slide title") }

            Rectangle {
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

            FieldLabel { label: qsTr("Slide body") }

            Rectangle {
                width: parent.width
                // Body gets the larger share: it is the thing on screen.
                height: Math.max(80, (parent.height - 210) * 0.55)
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
                            text: qsTr("What the congregation reads. One point per slide.")
                            color: Theme.color.textTertiary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.bodySize
                        }
                    }
                }
            }

            FieldLabel {
                label:  qsTr("Speaker notes")
                detail: qsTr("stage monitor only — never shown to the audience")
            }

            Rectangle {
                width: parent.width
                height: Math.max(60, (parent.height - 210) * 0.45)
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
