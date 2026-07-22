import QtQuick
import QtQuick.Controls.Basic

// Strong's interlinear reader — a KJV chapter with every Strong's-tagged word
// rendered as a tappable token (blue superscript = Hebrew, green = Greek).
// The sidebar search box drives a reference lookup ("jn 3:16", "Genesis 1").
// Tapping a word looks up its definition, shows it in the detail bar, and
// pushes it to Preview; double-click / "Send to Live" projects it.
Item {
    id: root

    property string tabKey: "strongs"

    // Consumed by the parent action bar's count label.
    property int count: verses.length

    // ── Reference resolution ────────────────────────────────────────────
    readonly property string rawQuery: AppState.searchText.strongs || ""
    property string debouncedQuery: rawQuery
    Timer {
        id: queryDebounce
        interval: 150
        onTriggered: root.debouncedQuery = root.rawQuery
    }
    onRawQueryChanged: queryDebounce.restart()
    onDebouncedQueryChanged: root._applyQuery()

    // Default landing: Genesis 1.
    property int    book: 1
    property int    chapterNum: 1
    property string bookName: "Genesis"

    // Verse to scroll to once the chapter loads (0 = none).
    property int _pendingVerse: 0

    readonly property var verses: StrongsService.chapter(root.book, root.chapterNum)

    function _applyQuery() {
        var q = (root.debouncedQuery || "").trim()
        if (q.length === 0) return
        var r = StrongsService.resolveReference(q)
        if (!r || !r.valid) return
        root.book        = r.book
        root.bookName    = r.bookName
        root.chapterNum  = r.chapter
        root._pendingVerse = r.verse
    }

    function _indexOfVerse(vn) {
        for (var i = 0; i < verses.length; i++)
            if (verses[i].verse === vn) return i
        return -1
    }

    onVersesChanged: {
        if (_pendingVerse > 0) {
            var idx = _indexOfVerse(_pendingVerse)
            _pendingVerse = 0
            if (idx >= 0) Qt.callLater(function() { list.positionViewAtIndex(idx, ListView.Beginning) })
        }
    }

    Component.onCompleted: root._applyQuery()

    function goChapter(delta) {
        var nc = root.chapterNum + delta
        if (nc < 1) return
        if (StrongsService.chapter(root.book, nc).length === 0) return
        root.chapterNum = nc
        root.selRef = ""
        Qt.callLater(function() { list.positionViewAtBeginning() })
        AppState.setSearch(root.tabKey, root.bookName + " " + nc)
    }

    // ── Selected word / definition ──────────────────────────────────────
    property string selRef: ""    // "H430" / "G2424"
    readonly property var selEntry: selRef.length > 0 ? StrongsService.lookup(selRef) : null

    function _themeId() {
        var t = ThemeService.defaultFor("strongs")
        if (t && t.id) return t.id
        var s = ThemeService.defaultFor("scripture")
        return (s && s.id) ? s.id : 0
    }

    function buildItemForWord(ref) {
        var e = StrongsService.lookup(ref)
        if (!e.valid) return null
        var secs = StrongsService.sections(e.word)
        var pages = []
        for (var i = 0; i < secs.length; i++)
            pages.push({ label: secs[i].label, content: secs[i].content })
        if (pages.length === 0)
            pages = [{ label: e.word, content: e.definition || e.word }]
        return {
            kind:       "strongs",
            title:      e.title,
            subtitle:   e.partOfSpeech || "",
            pages:      pages,
            themeId:    root._themeId(),
            strongsRef: { word: e.word }
        }
    }

    function selectWord(ref) {
        if (!ref || ref.length === 0) return
        root.selRef = ref
        AppState.setActiveFocus("library")
        if (AppState.tabKeys[AppState.activeTab] !== tabKey) return
        var item = buildItemForWord(ref)
        if (item) AppState.pushLibraryPreview(item)
    }

    function liveWord(ref) {
        var item = buildItemForWord(ref)
        if (item) AppState.pushLibraryLive(item)
    }

    Connections {
        target: AppState
        function onLibraryActivate() {
            if (AppState.tabKeys[AppState.activeTab] !== root.tabKey) return
            if (root.selRef.length > 0) root.liveWord(root.selRef)
        }
    }

    // ── Chapter header (prev / title / next) ────────────────────────────
    Rectangle {
        id: chapterHeader
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 34
        color: "transparent"

        Rectangle {
            id: prevBtn
            anchors.left: parent.left
            anchors.leftMargin: Theme.space.md
            anchors.verticalCenter: parent.verticalCenter
            width: 26; height: 22; radius: 0
            color: prevMa.containsMouse ? Theme.color.raised : "transparent"
            AppIcon { anchors.centerIn: parent; name: "chevron-left"; size: Theme.icon.sm
                      color: Theme.color.textSecondary }
            MouseArea { id: prevMa; anchors.fill: parent; hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor; onClicked: root.goChapter(-1) }
        }

        Text {
            anchors.centerIn: parent
            text: root.bookName + " " + root.chapterNum
            color: Theme.color.textSecondary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.bodySize
            font.weight: Theme.font.weightMedium
        }

        Rectangle {
            id: nextBtn
            anchors.right: parent.right
            anchors.rightMargin: Theme.space.md
            anchors.verticalCenter: parent.verticalCenter
            width: 26; height: 22; radius: 0
            color: nextMa.containsMouse ? Theme.color.raised : "transparent"
            AppIcon { anchors.centerIn: parent; name: "chevron-right"; size: Theme.icon.sm
                      color: Theme.color.textSecondary }
            MouseArea { id: nextMa; anchors.fill: parent; hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor; onClicked: root.goChapter(1) }
        }

        Rectangle { anchors.bottom: parent.bottom; anchors.left: parent.left
                    anchors.right: parent.right; height: 1; color: Theme.color.borderSubtle }
    }

    // ── Detail bar (bottom) ─────────────────────────────────────────────
    Rectangle {
        id: detailBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: (root.selEntry && root.selEntry.valid) ? 128 : 0
        visible: height > 0
        color: Theme.color.elevated
        clip: true

        Rectangle { anchors.top: parent.top; anchors.left: parent.left
                    anchors.right: parent.right; height: 1; color: Theme.color.borderSubtle }

        Item {
            anchors.fill: parent
            anchors.margins: Theme.space.lg

            Row {
                id: detailTitleRow
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: detailLiveBtn.left
                anchors.rightMargin: Theme.space.md
                spacing: Theme.space.sm
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: dbBadge.implicitWidth + 12; height: 18; radius: 0
                    color: (root.selEntry && root.selEntry.isHebrew) ? "#1d4ed8" : "#15803d"
                    Text {
                        id: dbBadge
                        anchors.centerIn: parent
                        text: root.selEntry ? root.selEntry.word : ""
                        color: "#ffffff"
                        font.family: Theme.font.monoFamily
                        font.pixelSize: 11
                        font.weight: Theme.font.weightBold
                    }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.selEntry ? root.selEntry.title : ""
                    color: Theme.color.textPrimary
                    font.family: Theme.font.family
                    font.pixelSize: 16
                    font.weight: Theme.font.weightSemiBold
                    elide: Text.ElideRight
                }
            }

            Rectangle {
                id: detailLiveBtn
                anchors.top: parent.top
                anchors.right: parent.right
                width: dbLiveRow.implicitWidth + Theme.space.lg * 2
                height: 28
                radius: 0
                color: dbLiveMa.containsMouse ? Theme.color.brand : Theme.color.raised
                Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
                Row {
                    id: dbLiveRow
                    anchors.centerIn: parent
                    spacing: Theme.space.sm
                    AppIcon { anchors.verticalCenter: parent.verticalCenter; name: "play"
                              size: Theme.icon.sm
                              color: dbLiveMa.containsMouse ? Theme.color.brandInk : Theme.color.textSecondary }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Send to Live")
                        color: dbLiveMa.containsMouse ? Theme.color.brandInk : Theme.color.textSecondary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                        font.weight: Theme.font.weightMedium
                    }
                }
                MouseArea { id: dbLiveMa; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.liveWord(root.selRef) }
            }

            Text {
                anchors.top: detailTitleRow.bottom
                anchors.topMargin: Theme.space.sm
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                text: root.selEntry ? (root.selEntry.definition || "") : ""
                color: Theme.color.textSecondary
                font.family: Theme.font.family
                font.pixelSize: 14
                wrapMode: Text.WordWrap
                elide: Text.ElideRight
            }
        }
    }

    // ── Verse list ──────────────────────────────────────────────────────
    EmptyState {
        anchors.top: chapterHeader.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: detailBar.top
        visible: root.verses.length === 0
        iconName: "book-x"
        title: qsTr("No chapter loaded")
        body: qsTr("Search a reference like \"John 3\" to open a chapter.")
    }

    ListView {
        id: list
        anchors.top: chapterHeader.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: detailBar.top
        anchors.topMargin: Theme.space.sm
        anchors.bottomMargin: Theme.space.sm
        ScrollBar.vertical: AppScrollBar {}
        clip: true
        cacheBuffer: 600
        boundsBehavior: Flickable.StopAtBounds
        visible: root.verses.length > 0
        model: root.verses
        spacing: Theme.space.sm

        delegate: Item {
            id: verseRow
            width: list.width - Theme.size.scrollBar
            implicitHeight: verseCol.implicitHeight + Theme.space.sm

            Column {
                id: verseCol
                anchors.left: parent.left
                anchors.leftMargin: Theme.space.lg
                anchors.right: parent.right
                anchors.rightMargin: Theme.space.md
                spacing: 3

                Text {
                    text: qsTr("Verse ") + modelData.verse
                    color: Theme.color.textTertiary
                    font.family: Theme.font.monoFamily
                    font.pixelSize: 11
                    font.weight: Theme.font.weightBold
                    font.capitalization: Font.AllUppercase
                }

                Flow {
                    width: parent.width
                    spacing: 7

                    Repeater {
                        model: StrongsService.tokenize(modelData.text)

                        delegate: Item {
                            id: tok
                            readonly property bool _tag: modelData.hasStrongs
                            readonly property bool _sel: root.selRef.length > 0 && modelData.ref === root.selRef
                            implicitWidth: tokRow.implicitWidth + 4
                            implicitHeight: Math.round(20 * Theme.uiScale) + 8

                            Rectangle {
                                anchors.fill: parent
                                radius: 0
                                visible: tok._tag
                                color: tok._sel ? Theme.color.brandSubtle
                                     : (tokMa.containsMouse ? Theme.color.rowHoverBrand : "transparent")
                            }

                            Row {
                                id: tokRow
                                anchors.centerIn: parent
                                spacing: 1

                                Text {
                                    anchors.bottom: parent.bottom
                                    text: modelData.text
                                    color: tok._tag ? Theme.color.textPrimary : "#d4d4d8"
                                    font.family: Theme.font.family
                                    font.pixelSize: Math.round(16 * Theme.uiScale)
                                    font.underline: tok._tag
                                }
                                Text {
                                    visible: tok._tag
                                    anchors.top: parent.top
                                    text: modelData.ref.length > 1 ? modelData.ref.substring(1) : ""
                                    color: modelData.language === "hebrew" ? "#60a5fa" : "#4ade80"
                                    font.family: Theme.font.monoFamily
                                    font.pixelSize: Math.round(9 * Theme.uiScale)
                                    font.weight: Theme.font.weightBold
                                }
                            }

                            MouseArea {
                                id: tokMa
                                anchors.fill: parent
                                enabled: tok._tag
                                hoverEnabled: true
                                cursorShape: tok._tag ? Qt.PointingHandCursor : Qt.ArrowCursor
                                onClicked: root.selectWord(modelData.ref)
                                onDoubleClicked: root.liveWord(modelData.ref)
                            }
                        }
                    }
                }
            }
        }
    }
}
