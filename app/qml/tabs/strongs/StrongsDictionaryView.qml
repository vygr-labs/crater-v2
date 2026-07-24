import QtQuick
import QtQuick.Controls.Basic

// Strong's dictionary (lexicon) view — a results list on the left, the full
// definition on the right. Search text comes from the sidebar TabSearchBar
// (AppState.searchText.strongs); the greek/hebrew sidebar group scopes the
// language. Single click selects + pushes Preview; double-click / "Send to
// Live" pushes the definition Live as auto-sized slides.
Item {
    id: root

    property string tabKey: "strongs"

    // Consumed by the parent action bar's count label.
    property int count: results.length

    // ── Query + language ────────────────────────────────────────────────
    readonly property string rawQuery: AppState.searchText.strongs || ""
    property string debouncedQuery: rawQuery
    Timer {
        id: queryDebounce
        interval: 150
        onTriggered: root.debouncedQuery = root.rawQuery
    }
    onRawQueryChanged: queryDebounce.restart()

    // Sidebar group ("greek" / "hebrew") narrows the language. Any other value
    // (shouldn't occur for this tab) means no language filter.
    readonly property string _group: AppState.activeLibraryGroup.strongs || ""
    readonly property string language:
        (_group === "hebrew" || _group === "greek") ? _group : ""

    readonly property var results: StrongsService.search(root.debouncedQuery, root.language)

    property int selIndex: -1
    readonly property var selEntry:
        (selIndex >= 0 && selIndex < results.length) ? results[selIndex] : null

    // ── Item building (projectable strongs slides) ──────────────────────
    // strongs has no dedicated theme kind yet, so fall back to the scripture
    // default — its reference node renders the word title, its body node the
    // definition text. A future dedicated "strongs" theme is picked up first.
    function _themeId() {
        var t = ThemeService.defaultFor("strongs")
        if (t && t.id) return t.id
        var s = ThemeService.defaultFor("scripture")
        return (s && s.id) ? s.id : 0
    }

    function buildItem(entry) {
        if (!entry || !entry.valid) return null
        var secs = StrongsService.sections(entry.word)
        var pages = []
        for (var i = 0; i < secs.length; i++)
            pages.push({ label: secs[i].label, content: secs[i].content })
        if (pages.length === 0)
            pages = [{ label: entry.word, content: entry.definition || entry.word }]
        return {
            kind:       "strongs",
            title:      entry.title,
            subtitle:   entry.partOfSpeech || "",
            pages:      pages,
            themeId:    root._themeId(),
            strongsRef: { word: entry.word }
        }
    }

    function pushPreviewFor(idx) {
        if (AppState.tabKeys[AppState.activeTab] !== tabKey) return
        var e = (idx >= 0 && idx < results.length) ? results[idx] : null
        var item = buildItem(e)
        if (item) AppState.pushLibraryPreview(item)
        else      AppState.clearLibraryPreview()
    }

    function pushLiveFor(idx) {
        var e = (idx >= 0 && idx < results.length) ? results[idx] : null
        var item = buildItem(e)
        if (item) AppState.pushLibraryLive(item)
    }

    onResultsChanged: {
        if (results.length === 0) { selIndex = -1; return }
        var idx = (selIndex >= 0 && selIndex < results.length) ? selIndex : 0
        selIndex = idx
        if (AppState.tabKeys[AppState.activeTab] === tabKey) pushPreviewFor(idx)
    }

    Component.onCompleted: {
        if (results.length > 0) { selIndex = 0; pushPreviewFor(0) }
    }

    Connections {
        target: AppState
        function onActiveTabChanged() {
            if (AppState.tabKeys[AppState.activeTab] !== root.tabKey) return
            if (root.selIndex >= 0) root.pushPreviewFor(root.selIndex)
        }
        function onLibraryNavigateDown() {
            if (AppState.tabKeys[AppState.activeTab] !== root.tabKey) return
            if (root.results.length === 0) return
            root.selIndex = Math.min((root.selIndex < 0 ? -1 : root.selIndex) + 1,
                                     root.results.length - 1)
            root.pushPreviewFor(root.selIndex)
        }
        function onLibraryNavigateUp() {
            if (AppState.tabKeys[AppState.activeTab] !== root.tabKey) return
            if (root.results.length === 0) return
            root.selIndex = Math.max(root.selIndex - 1, 0)
            root.pushPreviewFor(root.selIndex)
        }
        function onLibraryActivate() {
            if (AppState.tabKeys[AppState.activeTab] !== root.tabKey) return
            if (root.selIndex >= 0) root.pushLiveFor(root.selIndex)
        }
    }

    // ── Empty state ─────────────────────────────────────────────────────
    EmptyState {
        anchors.fill: parent
        visible: root.results.length === 0
        iconName: "search-x"
        title: root.rawQuery.length > 0 ? qsTr("No matches") : qsTr("Search Strong's")
        body: root.rawQuery.length > 0
              ? qsTr("No entries match \"") + root.rawQuery + "\""
              : qsTr("Type a Strong's number (e.g. H430) or an English word.")
    }

    // ── Split: results list + definition detail ─────────────────────────
    Row {
        anchors.fill: parent
        visible: root.results.length > 0
        spacing: 0

        // Results list
        Item {
            id: listPane
            width: Math.max(300, Math.round(parent.width * 0.42))
            height: parent.height

            ListView {
                id: list
                anchors.fill: parent
                ScrollBar.vertical: AppScrollBar {}
                clip: true
                cacheBuffer: 400
                boundsBehavior: Flickable.StopAtBounds
                model: root.results

                onCurrentIndexChanged: {
                    if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
                }

                delegate: Item {
                    id: entryRow
                    width: list.width - Theme.size.scrollBar
                    height: 52

                    // Bold the matched query terms in the lemma / definition
                    // when there's a query and the operator hasn't turned
                    // Strong's highlighting off (Settings › Search). Strong's had
                    // no highlight before; this brings it in line with Songs and
                    // Scripture. A Strong's-number query (e.g. "H430") simply
                    // finds nothing to bold in the prose — harmless.
                    readonly property bool _colorize:
                        root.debouncedQuery.length > 0
                        && SettingsService.highlightStrongsMatches

                    readonly property bool _sel: list.currentIndex === index
                    readonly property bool _isLive:
                        ProjectionService.contentKind === "strongs"
                        && ProjectionService.currentItem
                        && ProjectionService.currentItem.strongsRef
                        && ProjectionService.currentItem.strongsRef.word === modelData.word

                    Rectangle {
                        anchors.fill: parent
                        radius: 0
                        color: entryRow._sel ? Theme.color.brandSubtle
                             : rowMa.containsMouse ? Theme.color.rowHoverBrand
                                                   : "transparent"
                    }
                    Rectangle {
                        anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
                        width: 2
                        color: Theme.color.brand
                        visible: entryRow._sel
                    }

                    // Language badge (blue = Hebrew, green = Greek).
                    Rectangle {
                        id: badge
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.space.lg
                        anchors.verticalCenter: parent.verticalCenter
                        width: badgeText.implicitWidth + 12
                        height: 18
                        radius: 0
                        color: modelData.isHebrew ? "#1d4ed8" : "#15803d"
                        Text {
                            id: badgeText
                            anchors.centerIn: parent
                            text: modelData.word
                            color: "#ffffff"
                            font.family: Theme.font.monoFamily
                            font.pixelSize: 11
                            font.weight: Theme.font.weightBold
                        }
                    }

                    // LIVE pill (right).
                    Rectangle {
                        id: livePill
                        visible: entryRow._isLive
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.space.md
                        anchors.verticalCenter: parent.verticalCenter
                        width: liveText.implicitWidth + 10
                        height: 14
                        radius: 0
                        color: Theme.color.live
                        Text {
                            id: liveText
                            anchors.centerIn: parent
                            text: "LIVE"
                            // White on the crimson `live` pill — matches the
                            // LivePanel LIVE indicator. (Was `brandInk`.)
                            color: "#ffffff"
                            font.family: Theme.font.monoFamily
                            font.pixelSize: 11
                            font.weight: Theme.font.weightBold
                        }
                    }

                    Column {
                        anchors.left: badge.right
                        anchors.leftMargin: Theme.space.md
                        anchors.right: livePill.visible ? livePill.left : parent.right
                        anchors.rightMargin: Theme.space.md
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 1

                        Text {
                            width: parent.width
                            readonly property string _primary: {
                                if (modelData.lemma && modelData.lemma.length > 0) {
                                    return modelData.transliteration.length > 0
                                        ? modelData.lemma + "   " + modelData.transliteration
                                        : modelData.lemma
                                }
                                return modelData.transliteration.length > 0
                                    ? modelData.transliteration
                                    : modelData.word
                            }
                            textFormat: entryRow._colorize ? Text.StyledText : Text.PlainText
                            text: entryRow._colorize
                                    ? SearchFormat.markup(_primary, root.debouncedQuery, Theme.color.brand)
                                    : _primary
                            color: entryRow._sel ? Theme.color.textPrimary : Theme.color.textTitle
                            font.family: Theme.font.family
                            font.pixelSize: 15
                            font.weight: entryRow._sel ? Theme.font.weightMedium : Theme.font.weightRegular
                            elide: Text.ElideRight
                        }
                        Text {
                            readonly property string _def: modelData.definition || ""
                            visible: _def.length > 0
                            width: parent.width
                            textFormat: entryRow._colorize ? Text.StyledText : Text.PlainText
                            text: entryRow._colorize
                                    ? SearchFormat.markup(_def, root.debouncedQuery, Theme.color.brand)
                                    : _def
                            color: entryRow._sel ? Theme.color.textSecondary : Theme.color.textTertiary
                            font.family: Theme.font.family
                            font.pixelSize: 13
                            elide: Text.ElideRight
                        }
                    }

                    MouseArea {
                        id: rowMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.selIndex = index
                            AppState.setActiveFocus("library")
                            root.pushPreviewFor(index)
                        }
                        onDoubleClicked: {
                            root.selIndex = index
                            AppState.setActiveFocus("library")
                            root.pushLiveFor(index)
                        }
                    }
                }
            }

            // Survives model swaps (results re-query) — see ScriptureTab's note
            // on why an inline currentIndex binding breaks on model reassignment.
            Binding {
                target: list
                property: "currentIndex"
                value: root.selIndex
                restoreMode: Binding.RestoreBindingOrValue
            }

            Rectangle {  // right divider
                anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom
                width: 1
                color: Theme.color.borderSubtle
            }
        }

        // Definition detail
        Item {
            id: detailPane
            width: parent.width - listPane.width
            height: parent.height

            // Header: title + part of speech + Send to Live
            Item {
                id: detailHeader
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: Theme.space.lg
                height: root.selEntry ? headerCol.implicitHeight : 0
                visible: root.selEntry

                Column {
                    id: headerCol
                    anchors.left: parent.left
                    anchors.right: liveBtn.left
                    anchors.rightMargin: Theme.space.md
                    spacing: 2
                    Text {
                        width: parent.width
                        text: root.selEntry ? root.selEntry.title : ""
                        color: Theme.color.textPrimary
                        font.family: Theme.font.family
                        font.pixelSize: 20
                        font.weight: Theme.font.weightSemiBold
                        wrapMode: Text.WordWrap
                    }
                    Text {
                        visible: text.length > 0
                        width: parent.width
                        text: root.selEntry ? root.selEntry.partOfSpeech : ""
                        color: Theme.color.textTertiary
                        font.family: Theme.font.family
                        font.pixelSize: 13
                    }
                }

                // Send to Live
                Rectangle {
                    id: liveBtn
                    anchors.right: parent.right
                    anchors.top: parent.top
                    width: liveBtnRow.implicitWidth + Theme.space.lg * 2
                    height: 30
                    radius: 0
                    color: liveBtnMa.containsMouse ? Theme.color.brand : Theme.color.raised
                    Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
                    Row {
                        id: liveBtnRow
                        anchors.centerIn: parent
                        spacing: Theme.space.sm
                        AppIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: "play"
                            size: Theme.icon.sm
                            color: liveBtnMa.containsMouse ? Theme.color.brandInk : Theme.color.textSecondary
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: qsTr("Send to Live")
                            color: liveBtnMa.containsMouse ? Theme.color.brandInk : Theme.color.textSecondary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.smallSize
                            font.weight: Theme.font.weightMedium
                        }
                    }
                    MouseArea {
                        id: liveBtnMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.pushLiveFor(root.selIndex)
                    }
                }
            }

            Rectangle {
                anchors.top: detailHeader.bottom
                anchors.topMargin: Theme.space.sm
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Theme.space.lg
                anchors.rightMargin: Theme.space.lg
                height: 1
                color: Theme.color.borderSubtle
                visible: root.selEntry
                id: detailDivider
            }

            // Full definition (rich text). Cross-reference links (#dH433) drive
            // a new search so the operator can walk the lexicon.
            Flickable {
                id: defScroll
                anchors.top: detailDivider.bottom
                anchors.topMargin: Theme.space.md
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Theme.space.lg
                anchors.rightMargin: Theme.space.lg
                anchors.bottomMargin: Theme.space.md
                clip: true
                contentWidth: width
                contentHeight: defText.implicitHeight
                ScrollBar.vertical: AppScrollBar {}
                visible: root.selEntry

                Text {
                    id: defText
                    width: defScroll.width - Theme.size.scrollBar
                    text: root.selEntry ? root.selEntry.html : ""
                    textFormat: Text.RichText
                    wrapMode: Text.WordWrap
                    color: Theme.color.textSecondary
                    font.family: Theme.font.family
                    font.pixelSize: Math.round(15 * Theme.uiScale)
                    onLinkActivated: function(link) {
                        if (link.indexOf("#d") === 0)
                            AppState.setSearch("strongs", link.substring(2))
                    }

                    // Pointing-hand cursor while hovering a cross-reference link
                    // (the blue #dG71 anchors). acceptedButtons: NoButton lets
                    // presses fall through to onLinkActivated and drags reach the
                    // Flickable for scrolling; hover still reaches defText, so
                    // hoveredLink stays accurate and the cursor is a hand only
                    // over an actual link, an arrow over plain definition text.
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.NoButton
                        cursorShape: defText.hoveredLink.length > 0
                                     ? Qt.PointingHandCursor : Qt.ArrowCursor
                    }
                }
            }
        }
    }
}
