import QtQuick

// Strong's concordance tab. Two views, toggled in the action bar:
//   • Dictionary — search the lexicon by number (H430/G2424) or keyword.
//   • Reader     — a KJV chapter with tappable Strong's-tagged words.
// Both push a selected definition to Preview/Live as auto-sized slides. When
// the shipped data files are missing the whole tab shows a "not found" state.
Item {
    id: root

    readonly property string tabKey: "strongs"
    property string viewMode: "dictionary"   // "dictionary" | "reader"

    // The two views share one search box but read it differently (a word
    // or number vs a chapter reference), so each keeps its own text. Before,
    // the Reader's "Genesis 2" carried into the Dictionary and matched
    // nothing in either language.
    property string _shownMode: "dictionary"
    property var _searchByView: ({})
    onViewModeChanged: {
        _searchByView[_shownMode] = AppState.searchText.strongs || ""
        _shownMode = viewMode
        AppState.setSearch(tabKey, _searchByView[viewMode] || "")
    }

    // Greek / Hebrew in the sidebar only scope the Dictionary. Picking one
    // while reading opens the Dictionary in that language instead of
    // silently doing nothing.
    readonly property string language: AppState.activeLibraryGroup.strongs || ""
    onLanguageChanged: if (viewMode === "reader") viewMode = "dictionary"

    Rectangle {
        anchors.fill: parent
        color: Theme.color.bgContent
        z: -1
    }

    // Data unavailable (files not shipped / dev tree not reachable).
    EmptyState {
        anchors.fill: parent
        visible: !StrongsService.available
        iconName: "book"
        title: qsTr("Strong's data not found")
        body: qsTr("Place strongs-dictionary.sqlite and strongs-bible.sqlite next to the app (or run from the dev tree) to enable the concordance.")
    }

    // ── Action bar: view toggle + count ─────────────────────────────────
    Rectangle {
        id: actionBar
        visible: StrongsService.available
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: Theme.d(32)
        color: "transparent"

        Row {
            anchors.left: parent.left
            anchors.leftMargin: Theme.space.md
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            Repeater {
                model: [ { key: "dictionary", label: qsTr("Dictionary") },
                         { key: "reader",     label: qsTr("Reader") } ]
                delegate: Rectangle {
                    width: segText.implicitWidth + 20
                    height: 22
                    radius: 0
                    color: root.viewMode === modelData.key ? Theme.color.raised
                         : segMa.containsMouse ? Theme.color.rowHoverBrand : "transparent"
                    Text {
                        id: segText
                        anchors.centerIn: parent
                        text: modelData.label
                        color: root.viewMode === modelData.key ? Theme.color.textPrimary
                                                               : Theme.color.textSecondary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                        font.weight: root.viewMode === modelData.key ? Theme.font.weightMedium
                                                                     : Theme.font.weightRegular
                    }
                    MouseArea {
                        id: segMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.viewMode = modelData.key
                    }
                }
            }
        }

        Text {
            anchors.centerIn: parent
            text: {
                var c = contentLoader.item ? contentLoader.item.count : 0
                if (root.viewMode === "dictionary") {
                    const n = c + " " + (c === 1 ? qsTr("entry") : qsTr("entries"))
                    return root.language === "hebrew" ? qsTr("Hebrew") + " · " + n
                         : root.language === "greek"  ? qsTr("Greek")  + " · " + n
                         : n
                }
                return c + " " + qsTr("verses")
            }
            color: Theme.color.textTertiary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.smallSize
        }

        Rectangle {
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: 1
            color: Theme.color.borderSubtle
        }
    }

    Loader {
        id: contentLoader
        visible: StrongsService.available
        anchors.top: actionBar.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        sourceComponent: root.viewMode === "reader" ? readerComp : dictComp
    }

    Component { id: dictComp;   StrongsDictionaryView { tabKey: root.tabKey } }
    Component { id: readerComp; StrongsReaderView     { tabKey: root.tabKey } }
}
