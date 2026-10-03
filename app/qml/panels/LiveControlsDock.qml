import QtQuick
import QtQuick.Controls.Basic

// LiveControlsDock — live controls that stay usable while a dialog is open.
//
// A dialog covers the console, and every console shortcut is gated off while
// one is open (AppState.consoleShortcutsActive), so before this the operator
// had to abandon a lyric edit to advance a slide. ModalLayer mounts this
// above the dialogs whenever AppState.liveDockShown (Settings > Projection >
// Keep live controls beside dialogs).
//
// It is a second view of the SAME live channel, never a copy: the slide rows
// are AppState.livePages, a click is AppState.commitLivePage, prev / next is
// AppState.stepLivePage, Logo / Clear are toggleLogo / clearLive, and the
// scripture switch goes live through AppState.pushLibraryLive, the path a
// Scripture tab double-click takes.
//
// Placement (session-only, in AppState):
//   docked    — pinned to the window's right edge. ModalShell centres the
//               dialog card in the space left of it (liveDockReservedWidth).
//   floating  — dragging the header lifts it out at liveDockX / Y; it then
//               reserves nothing. The dock button snaps it back.
//   collapsed — either form folds to a thin vertical tab. Click to unfold,
//               drag to move.
//
// Focus: nothing here takes keyboard focus on its own. The reference input
// takes it when clicked, and clicking a slide or a nav button focuses the
// panel so Up / Down / Page keys step slides from then on. Typing in the
// dialog's editors is never interrupted.
//
// Never open a modal from here (menus included): there is one modal slot,
// and opening anything would replace the dialog the operator is editing.
Item {
    id: root

    readonly property int  _margin:   AppState.liveDockMargin
    // Keep clear of the custom title bar (TitleBar.qml, 32px) so the
    // window's minimise / maximise / close buttons stay reachable.
    readonly property int  _top:      32 + _margin
    readonly property bool _collapsed: AppState.liveDockCollapsed
    readonly property bool _floating:  AppState.liveDockFloating
    readonly property bool _onLive:    AppState.liveDockTab === "live"

    // ── Frame geometry ──────────────────────────────────────────────────
    readonly property real _expandedW:
        Math.min(AppState.liveDockWidth, width - _margin * 2)
    // Attached to the dialog card's right edge (see ModalShell), matching
    // its top and height. Never shorter than 420 so a small dialog still
    // leaves room for the slide list.
    readonly property rect _card: AppState.modalCardRect
    readonly property bool _attached: !_floating && _card.width > 0
    readonly property real _expandedH: _floating
        ? Math.min(560, height - _top - _margin)
        : _attached
            ? Math.min(Math.max(_card.height, 420), height - _card.y - _margin)
            : height - _top - _margin
    readonly property real _tabH: 148

    readonly property real _frameW: _collapsed ? AppState.liveDockCollapsedWidth : _expandedW
    readonly property real _frameH: _collapsed ? _tabH : _expandedH

    function _clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

    // ── Dragging ────────────────────────────────────────────────────────
    // Shared by the header and the collapsed tab. Movement under a few
    // pixels is a click, so the tab can both unfold and be dragged.
    property point _pressAt: Qt.point(0, 0)
    property point _grabOffset: Qt.point(0, 0)
    property bool  _dragging: false

    function _beginDrag(area, mouse) {
        const p = area.mapToItem(root, mouse.x, mouse.y)
        _pressAt = p
        _grabOffset = Qt.point(p.x - frame.x, p.y - frame.y)
        _dragging = false
    }

    function _dragTo(area, mouse) {
        const p = area.mapToItem(root, mouse.x, mouse.y)
        if (!_dragging) {
            if (Math.abs(p.x - _pressAt.x) + Math.abs(p.y - _pressAt.y) < 6) return
            _dragging = true
        }
        // Position before the floating flip, so the frame's x / y bindings
        // never see the stale coordinates of a previous drag.
        AppState.liveDockX = p.x - _grabOffset.x
        AppState.liveDockY = p.y - _grabOffset.y
        AppState.liveDockFloating = true
    }

    // Installed translation codes for the scripture picker. Built with a
    // loop rather than .map so it does not depend on how the QList<Translation>
    // sequence converts.
    function _translationCodes() {
        const trs = BibleService.translations()
        const out = []
        for (let i = 0; i < trs.length; ++i) out.push(String(trs[i].code).toUpperCase())
        return out
    }

    function _focusPanel() { frame.forceActiveFocus() }

    // ── Panel ───────────────────────────────────────────────────────────
    FocusScope {
        id: frame

        width:  root._frameW
        height: root._frameH
        x: root._floating
           ? root._clamp(AppState.liveDockX, root._margin, root.width - width - root._margin)
           : root._attached
               ? root._card.x + root._card.width + root._margin
               : root.width - width - root._margin
        y: root._floating
           ? root._clamp(AppState.liveDockY, root._top, root.height - height - root._margin)
           : root._attached
               ? root._card.y
               : (root._collapsed ? (root.height - height) / 2 : root._top)

        // Fade in with the dialog rather than blink into place.
        opacity: 0
        Component.onCompleted: opacity = 1
        Behavior on opacity {
            NumberAnimation { duration: Theme.motion.normal; easing.type: Easing.OutCubic }
        }

        // Slide keys once the operator has clicked into the panel. Console
        // shortcuts are off while a dialog is open, so these do not collide
        // with Main.qml's Up / Down. The reference input keeps its own keys.
        Keys.onPressed: function(event) {
            if (!root._onLive || root._collapsed) return
            switch (event.key) {
            case Qt.Key_Up:
            case Qt.Key_Left:
            case Qt.Key_PageUp:
                AppState.stepLivePage(-1); event.accepted = true; break
            case Qt.Key_Down:
            case Qt.Key_Right:
            case Qt.Key_PageDown:
            case Qt.Key_Space:
                AppState.stepLivePage(1); event.accepted = true; break
            }
        }

        Rectangle {
            anchors.fill: parent
            color: Theme.color.elevated
            border.color: frame.activeFocus || inputBox.inputFocused
                          ? Theme.color.borderStrong : Theme.color.borderSubtle
            border.width: 1
        }

        // Absorb every event on the panel's blank areas. Without this a
        // click between controls would fall through to the dialog's
        // backdrop, which closes the dialog. Same idiom as ModalShell's card.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            hoverEnabled: true
            onPressed:       function(m) { m.accepted = true }
            onClicked:       function(m) { m.accepted = true }
            onDoubleClicked: function(m) { m.accepted = true }
            onWheel:         function(w) { w.accepted = true }
        }

        // ── Collapsed tab ───────────────────────────────────────────────
        Item {
            id: tab
            anchors.fill: parent
            visible: root._collapsed

            Column {
                anchors.centerIn: parent
                spacing: Theme.space.md

                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 8; height: 8; radius: 4
                    color: AppState.liveIsActive ? Theme.color.live : Theme.color.textTertiary
                    SequentialAnimation on opacity {
                        running: AppState.liveIsActive && root._collapsed
                        loops: Animation.Infinite
                        NumberAnimation { from: 1.0; to: 0.4; duration: 800; easing.type: Easing.InOutQuad }
                        NumberAnimation { from: 0.4; to: 1.0; duration: 800; easing.type: Easing.InOutQuad }
                    }
                }

                // Rotated label. The Item carries the rotated footprint so
                // the Column spaces it correctly.
                Item {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: tabLabel.implicitHeight
                    height: tabLabel.implicitWidth
                    Text {
                        id: tabLabel
                        anchors.centerIn: parent
                        rotation: -90
                        text: qsTr("LIVE")
                        color: AppState.liveIsActive ? Theme.color.textPrimary : Theme.color.textSecondary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.microSize
                        font.weight: Theme.font.weightSemiBold
                        font.letterSpacing: 1.2
                    }
                }

                AppIcon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    name: "chevron-left"
                    color: tabMa.containsMouse ? Theme.color.textPrimary : Theme.color.textTertiary
                    size: Theme.icon.sm
                }
            }

            MouseArea {
                id: tabMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: root._dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                onPressed:         function(m) { root._beginDrag(tabMa, m) }
                onPositionChanged: function(m) { if (pressed) root._dragTo(tabMa, m) }
                onReleased: {
                    if (!root._dragging) AppState.liveDockCollapsed = false
                    root._dragging = false
                }
            }
        }

        // ── Expanded panel ──────────────────────────────────────────────
        Item {
            id: expanded
            anchors.fill: parent
            visible: !root._collapsed

            // Header: drag handle, tabs, dock and fold buttons.
            Item {
                id: header
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                height: 40

                // Drag surface first so the tabs and buttons above win.
                MouseArea {
                    id: dragMa
                    anchors.fill: parent
                    cursorShape: root._dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                    onPressed:         function(m) { root._beginDrag(dragMa, m) }
                    onPositionChanged: function(m) { if (pressed) root._dragTo(dragMa, m) }
                    onReleased: root._dragging = false
                }

                AppIcon {
                    id: grip
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.space.sm
                    anchors.verticalCenter: parent.verticalCenter
                    name: "grip-vertical"
                    color: Theme.color.textTertiary
                    size: Theme.icon.sm
                }

                Row {
                    anchors.left: grip.right
                    anchors.leftMargin: Theme.space.sm
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    spacing: Theme.space.md

                    Repeater {
                        model: [
                            { key: "live",      label: qsTr("Live") },
                            { key: "scripture", label: qsTr("Scripture") }
                        ]
                        delegate: Item {
                            id: tabBtn
                            required property var modelData
                            readonly property bool current: AppState.liveDockTab === modelData.key
                            width: tabText.implicitWidth
                            height: parent.height

                            Text {
                                id: tabText
                                anchors.verticalCenter: parent.verticalCenter
                                text: tabBtn.modelData.label
                                color: tabBtn.current ? Theme.color.textPrimary
                                     : tabBtnMa.containsMouse ? Theme.color.textSecondary
                                                              : Theme.color.textTertiary
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.smallSize
                                font.weight: Theme.font.weightSemiBold
                            }
                            Rectangle {
                                anchors.bottom: parent.bottom
                                anchors.left: parent.left
                                anchors.right: parent.right
                                height: 2
                                visible: tabBtn.current
                                color: tabBtn.modelData.key === "live" ? Theme.color.live : Theme.color.brand
                            }
                            MouseArea {
                                id: tabBtnMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: AppState.liveDockTab = tabBtn.modelData.key
                            }
                        }
                    }
                }

                Row {
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.space.xs
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 0

                    // Back to the right-edge dock. Only meaningful once the
                    // operator has dragged the panel out.
                    IconButton {
                        visible: root._floating
                        iconName: "align-end-vertical"
                        iconSize: Theme.icon.sm
                        onClicked: AppState.liveDockFloating = false
                    }
                    IconButton {
                        iconName: "chevron-right"
                        iconSize: Theme.icon.sm
                        onClicked: AppState.liveDockCollapsed = true
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

            // ── Live tab ────────────────────────────────────────────────
            Item {
                id: liveTab
                anchors.top: header.bottom
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: Theme.space.md
                visible: root._onLive

                // Live pill + item title.
                Row {
                    id: liveTitleRow
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    spacing: Theme.space.sm
                    height: 22

                    Rectangle {
                        id: livePill
                        anchors.verticalCenter: parent.verticalCenter
                        height: 20
                        width: livePillRow.implicitWidth + Theme.space.sm * 2
                        color: AppState.liveIsActive ? Theme.color.live : Theme.color.raised

                        Row {
                            id: livePillRow
                            anchors.centerIn: parent
                            spacing: Theme.space.xs
                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 6; height: 6; radius: 3
                                color: AppState.liveIsActive ? "#ffffff" : Theme.color.textTertiary
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: qsTr("LIVE")
                                color: AppState.liveIsActive ? "#ffffff" : Theme.color.textSecondary
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.microSize
                                font.weight: Theme.font.weightSemiBold
                                font.letterSpacing: 1.0
                            }
                        }
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: liveTitleRow.width - livePill.width - liveTitleRow.spacing
                        text: AppState.liveIsActive && AppState.liveItem && AppState.liveItem.title
                              ? String(AppState.liveItem.title)
                              : qsTr("Nothing live")
                        color: AppState.liveIsActive ? Theme.color.textPrimary : Theme.color.textTertiary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                        font.weight: Theme.font.weightMedium
                        elide: Text.ElideRight
                    }
                }

                // Mini monitor. Same ThemedMonitor + LogoView pairing and
                // bindings as LivePanel's, always muted: LivePanel is still
                // alive under the dialog and keeps the audio role.
                Rectangle {
                    id: monitor
                    anchors.top: liveTitleRow.bottom
                    anchors.topMargin: Theme.space.sm
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: width * 9 / 16
                    color: "#000000"
                    border.color: AppState.liveIsActive ? Theme.color.live : Theme.color.borderStrong
                    border.width: 1.5
                    clip: true

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 1.5
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: "#0d0d12" }
                            GradientStop { position: 1.0; color: "#050508" }
                        }
                    }

                    // Loaded only while the Live tab is on screen, so a
                    // folded or Scripture-side panel renders nothing.
                    Loader {
                        anchors.fill: parent
                        anchors.margins: 1.5
                        active: root._onLive && !root._collapsed
                        sourceComponent: Item {
                            ThemedMonitor {
                                anchors.fill: parent
                                item: AppState.liveItem
                                pageIndex: AppState.liveSubIndex
                                muted: true
                                isClear: AppState.isClear
                                showLogo: AppState.showLogo
                                cropRect: ProjectionService.cropRect
                            }
                            LogoView {
                                anchors.fill: parent
                                active: AppState.showLogo
                                visible: AppState.showLogo
                            }
                        }
                    }
                }

                // Prev / position / next, then Logo and Clear.
                Item {
                    id: controlsRow
                    anchors.top: monitor.bottom
                    anchors.topMargin: Theme.space.sm
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: 30

                    Row {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 0

                        IconButton {
                            iconName: "chevron-up"
                            iconSize: Theme.icon.md
                            enabled: AppState.livePages.length > 0 && AppState.liveSubIndex > 0
                            onClicked: { root._focusPanel(); AppState.stepLivePage(-1) }
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.max(implicitWidth, 40)
                            horizontalAlignment: Text.AlignHCenter
                            text: AppState.livePages.length > 0
                                  ? qsTr("%1 / %2").arg(AppState.liveSubIndex + 1).arg(AppState.livePages.length)
                                  : "-"
                            color: Theme.color.textSecondary
                            font.family: Theme.font.monoFamily
                            font.pixelSize: Theme.font.smallSize
                        }
                        IconButton {
                            iconName: "chevron-down"
                            iconSize: Theme.icon.md
                            enabled: AppState.livePages.length > 0
                                     && AppState.liveSubIndex < AppState.livePages.length - 1
                            onClicked: { root._focusPanel(); AppState.stepLivePage(1) }
                        }
                    }

                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.space.xs

                        DockToggle {
                            iconName: "image"
                            text: qsTr("Logo")
                            active: AppState.showLogo
                            onClicked: AppState.toggleLogo()
                        }
                        DockToggle {
                            iconName: "eye-off"
                            text: qsTr("Clear")
                            active: AppState.isClear
                            onClicked: AppState.clearLive()
                        }
                    }
                }

                // Slides of the live item.
                ListView {
                    id: slideList
                    anchors.top: controlsRow.bottom
                    anchors.topMargin: Theme.space.sm
                    anchors.bottom: parent.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    visible: AppState.liveIsActive && AppState.livePages.length > 0
                    model: AppState.livePages
                    clip: true
                    spacing: Theme.space.xs
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: AppScrollBar {}

                    function _follow() {
                        if (visible && AppState.liveSubIndex >= 0
                                    && AppState.liveSubIndex < count)
                            positionViewAtIndex(AppState.liveSubIndex, ListView.Contain)
                    }
                    onCountChanged: Qt.callLater(_follow)
                    Component.onCompleted: Qt.callLater(_follow)
                    Connections {
                        target: AppState
                        function onLiveSubIndexChanged() { slideList._follow() }
                    }

                    delegate: Rectangle {
                        id: row
                        required property var modelData
                        required property int index
                        readonly property bool current: AppState.liveSubIndex === index
                        readonly property string label:
                            modelData && modelData.label ? String(modelData.label) : ""
                        // Same text and size the Live panel shows for this
                        // slide, so the dock never hides a line.
                        readonly property string mode: SettingsService.liveCardMode
                        readonly property string html: {
                            const raw = modelData && modelData.content ? String(modelData.content) : ""
                            return LyricsService.dslToHtml(mode === "lines"
                                                           ? raw.split("\n").join(" / ") : raw)
                        }

                        // Full width until the list overflows, then make room
                        // for the scrollbar.
                        width: slideList.width
                               - (slideList.contentHeight > slideList.height ? Theme.size.scrollBar + 2 : 0)
                        height: Math.max(36, rowText.implicitHeight + Theme.space.sm * 2)
                        color: current ? Theme.color.liveSubtle
                             : rowMa.containsMouse ? Theme.color.overlay
                                                   : Theme.color.raised
                        border.color: current ? Theme.color.live : "transparent"
                        border.width: 1

                        Text {
                            id: rowNum
                            anchors.left: parent.left
                            anchors.top: parent.top
                            anchors.topMargin: Theme.space.sm
                            width: 26
                            horizontalAlignment: Text.AlignHCenter
                            text: (row.index + 1).toString()
                            color: row.current ? Theme.color.textPrimary : Theme.color.textTertiary
                            font.family: Theme.font.monoFamily
                            font.pixelSize: Theme.font.smallSize
                            font.weight: Theme.font.weightSemiBold
                        }

                        Column {
                            id: rowText
                            anchors.left: rowNum.right
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.space.sm
                            anchors.top: parent.top
                            anchors.topMargin: Theme.space.sm
                            spacing: 2

                            Text {
                                width: parent.width
                                visible: row.label.length > 0
                                text: row.label.toUpperCase()
                                color: row.current ? Theme.color.textPrimary : Theme.color.textSecondary
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.microSize
                                font.weight: Theme.font.weightSemiBold
                                font.letterSpacing: 1.0
                                elide: Text.ElideRight
                            }
                            Text {
                                width: parent.width
                                visible: text.length > 0
                                textFormat: Text.RichText
                                text: row.html
                                color: Theme.color.textPrimary
                                font.family: Theme.font.family
                                font.pixelSize: row.mode === "full" ? Theme.font.bodySize : Theme.font.smallSize
                                lineHeight: row.mode === "full" ? 1.25 : 1.05
                                wrapMode: Text.WordWrap
                                maximumLineCount: row.mode === "lines" ? 1 : 100000
                                clip: row.mode === "lines"
                            }
                        }

                        MouseArea {
                            id: rowMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            // A click is "audience sees this now", same as a
                            // LivePanel card.
                            onClicked: {
                                root._focusPanel()
                                AppState.commitLivePage(row.index)
                            }
                        }
                    }
                }

                // Nothing live, or a media item with no text slides.
                Text {
                    anchors.top: controlsRow.bottom
                    anchors.topMargin: Theme.space.lg
                    anchors.left: parent.left
                    anchors.right: parent.right
                    visible: !slideList.visible
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    text: AppState.liveIsActive
                          ? qsTr("This item has no text slides")
                          : qsTr("Nothing is live. Use the Scripture tab to send a passage.")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                }
            }

            // ── Scripture tab ───────────────────────────────────────────
            Item {
                id: scriptureTab
                anchors.top: header.bottom
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: Theme.space.md
                visible: !root._onLive

                // Translation the typed reference resolves in: the operator's
                // pick from the dropdown, else the live passage's, else the
                // Scripture tab's. A code typed in the reference beats all
                // three (handled by scripturePassageFromText).
                readonly property string _liveCode:
                    AppState.liveItem && AppState.liveItem.kind === "scripture"
                        && AppState.liveItem.scriptureRef
                        ? String(AppState.liveItem.scriptureRef.translationCode || "").toUpperCase()
                        : ""
                readonly property string translation:
                    AppState.liveDockTranslation !== "" ? AppState.liveDockTranslation
                  : _liveCode !== ""                    ? _liveCode
                  : String(AppState.activeLibraryGroup.scripture || "").toUpperCase()

                readonly property var pending:
                    AppState.scripturePassageFromText(AppState.liveDockScriptureQuery,
                                                      translation)

                readonly property bool liveIsScripture:
                    AppState.liveIsActive && !!AppState.liveItem
                    && AppState.liveItem.kind === "scripture"
                    && !!AppState.liveItem.scriptureRef

                function send() {
                    if (!pending) return
                    AppState.pushLibraryLive(pending, 0)
                    // Ready for the next reference: typing replaces this one.
                    if (refInput.activeFocus) refInput.selectAll()
                }

                Text {
                    id: sendLabel
                    anchors.top: parent.top
                    anchors.left: parent.left
                    text: qsTr("SEND A PASSAGE")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.microSize
                    font.weight: Theme.font.weightSemiBold
                    font.letterSpacing: 1.0
                }

                Item {
                    id: inputRow
                    anchors.top: sendLabel.bottom
                    anchors.topMargin: Theme.space.sm
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: Theme.size.controlHeight

                    Rectangle {
                        id: inputBox
                        readonly property bool inputFocused: refInput.activeFocus
                        anchors.left: parent.left
                        anchors.right: translationPick.left
                        anchors.rightMargin: Theme.space.sm
                        height: parent.height
                        color: Theme.color.canvas
                        border.color: refInput.activeFocus ? Theme.color.brand : Theme.color.borderStrong
                        border.width: 1

                        AppIcon {
                            id: refIcon
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.space.sm
                            anchors.verticalCenter: parent.verticalCenter
                            name: "book-open"
                            color: Theme.color.textTertiary
                            size: Theme.icon.sm
                        }

                        TextInput {
                            id: refInput
                            anchors.left: refIcon.right
                            anchors.leftMargin: Theme.space.sm
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.space.sm
                            anchors.verticalCenter: parent.verticalCenter
                            color: Theme.color.textPrimary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.bodySize
                            selectByMouse: true
                            clip: true
                            // Takes focus only on click (the TextInput
                            // default), never on show.
                            Component.onCompleted: text = AppState.liveDockScriptureQuery
                            onTextChanged: AppState.liveDockScriptureQuery = text
                            onAccepted: scriptureTab.send()

                            // Escape clears the box instead of closing the
                            // dialog behind it (Main.qml's window Escape).
                            Keys.onShortcutOverride: function(event) {
                                if (event.key === Qt.Key_Escape && text.length > 0)
                                    event.accepted = true
                            }
                            Keys.onEscapePressed: text = ""

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: refInput.text.length === 0
                                text: qsTr("jn 3:16-18")
                                color: Theme.color.textTertiary
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.bodySize
                            }
                        }
                    }

                    Combobox {
                        id: translationPick
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: 84
                        searchable: false
                        options: root._translationCodes()
                        value: scriptureTab.translation
                        onValueSelected: function(v) { AppState.liveDockTranslation = v }
                    }
                }

                // What the box resolves to, before it goes anywhere.
                Text {
                    id: interpreted
                    anchors.top: inputRow.bottom
                    anchors.topMargin: Theme.space.xs
                    anchors.left: parent.left
                    anchors.right: parent.right
                    text: scriptureTab.pending
                          ? String(scriptureTab.pending.title)
                          : (AppState.liveDockScriptureQuery.trim().length > 0
                             ? qsTr("No matching passage")
                             : qsTr("Type a reference like rom 8:28 NIV"))
                    color: scriptureTab.pending ? Theme.color.textSecondary : Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                    elide: Text.ElideRight
                }

                PrimaryButton {
                    id: sendBtn
                    anchors.top: interpreted.bottom
                    anchors.topMargin: Theme.space.sm
                    anchors.left: parent.left
                    anchors.right: parent.right
                    variant: "live"
                    iconName: "radio"
                    text: qsTr("Go live")
                    enabled: !!scriptureTab.pending
                    onClicked: scriptureTab.send()
                }

                Rectangle {
                    id: scriptureDivider
                    anchors.top: sendBtn.bottom
                    anchors.topMargin: Theme.space.lg
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: 1
                    color: Theme.color.borderSubtle
                }

                Text {
                    id: liveVerseLabel
                    anchors.top: scriptureDivider.bottom
                    anchors.topMargin: Theme.space.md
                    anchors.left: parent.left
                    text: qsTr("LIVE PASSAGE")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.microSize
                    font.weight: Theme.font.weightSemiBold
                    font.letterSpacing: 1.0
                }

                Text {
                    id: liveVerseTitle
                    anchors.top: liveVerseLabel.bottom
                    anchors.topMargin: Theme.space.xs
                    anchors.left: parent.left
                    anchors.right: parent.right
                    text: scriptureTab.liveIsScripture
                          ? String(AppState.liveItem.title || "")
                          : qsTr("No scripture is live")
                    color: scriptureTab.liveIsScripture ? Theme.color.textPrimary : Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize
                    font.weight: Theme.font.weightMedium
                    elide: Text.ElideRight
                }

                // Step the live passage a verse at a time, across chapter
                // and book ends (AppState.stepLiveScripture).
                Row {
                    anchors.top: liveVerseTitle.bottom
                    anchors.topMargin: Theme.space.sm
                    anchors.left: parent.left
                    anchors.right: parent.right
                    spacing: Theme.space.sm
                    enabled: scriptureTab.liveIsScripture

                    GhostButton {
                        width: (parent.width - parent.spacing) / 2
                        iconName: "chevron-left"
                        text: qsTr("Previous verse")
                        onClicked: AppState.stepLiveScripture(-1)
                    }
                    GhostButton {
                        width: (parent.width - parent.spacing) / 2
                        iconName: "chevron-right"
                        text: qsTr("Next verse")
                        onClicked: AppState.stepLiveScripture(1)
                    }
                }
            }
        }
    }

    // Compact Logo / Clear toggle. GhostButton's chrome at a height and
    // padding that fit two of them beside the slide nav in a 300px panel.
    component DockToggle: Rectangle {
        id: toggle
        property string iconName: ""
        property string text: ""
        property bool   active: false
        signal clicked()

        implicitHeight: 28
        implicitWidth: toggleRow.implicitWidth + Theme.space.sm * 2
        color: active ? Theme.color.brandSubtle
             : toggleMa.containsMouse ? Theme.color.overlay
                                      : "transparent"
        border.color: active ? Theme.color.brand : Theme.color.borderStrong
        border.width: 1

        Row {
            id: toggleRow
            anchors.centerIn: parent
            spacing: Theme.space.xs
            AppIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: toggle.iconName
                color: toggle.active ? Theme.color.textPrimary : Theme.color.textSecondary
                size: Theme.icon.sm
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: toggle.text
                color: Theme.color.textPrimary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                font.weight: Theme.font.weightMedium
            }
        }

        MouseArea {
            id: toggleMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: toggle.clicked()
        }
    }
}
