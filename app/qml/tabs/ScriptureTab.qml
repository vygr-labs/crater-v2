import QtQuick
import QtQuick.Layouts

// Scripture tab — version selector + book/chapter navigation.
// Stubbed for UI-flow only; real Bible data lands when BibleService is built.
Item {
    id: root

    // Stub book list (66 books of the Bible — only the first few shown to
    // make the demo feel real without dragging in the full data set).
    readonly property var stubBooks: [
        { name: "Genesis",     chapters: 50 },
        { name: "Exodus",      chapters: 40 },
        { name: "Leviticus",   chapters: 27 },
        { name: "Numbers",     chapters: 36 },
        { name: "Deuteronomy", chapters: 34 },
        { name: "Joshua",      chapters: 24 },
        { name: "Matthew",     chapters: 28 },
        { name: "Mark",        chapters: 16 },
        { name: "Luke",        chapters: 24 },
        { name: "John",        chapters: 21 },
        { name: "Romans",      chapters: 16 },
        { name: "Revelation",  chapters: 22 }
    ]

    readonly property var filtered: {
        const q = (AppState.searchText.scripture || "").toLowerCase()
        if (q.length === 0) return stubBooks
        return stubBooks.filter(b => b.name.toLowerCase().indexOf(q) !== -1)
    }

    EmptyState {
        anchors.fill: parent
        visible: root.filtered.length === 0
        iconName: "book-open"
        title: qsTr("No matches")
        body: qsTr("Try a different search")
    }

    // Header: which version is active.
    Row {
        id: versionRow
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: Theme.space.md
        anchors.leftMargin: Theme.space.lg
        spacing: Theme.space.sm
        visible: root.filtered.length > 0

        AppIcon {
            anchors.verticalCenter: parent.verticalCenter
            name: "book-open"
            color: Theme.color.preview
            size: 14
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: (AppState.activeLibraryGroup.scripture || "kjv").toUpperCase()
            color: Theme.color.textPrimary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.bodySize
            font.weight: Theme.font.weightSemiBold
            font.letterSpacing: 0.8
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "· " + root.filtered.length + " " + qsTr("books")
            color: Theme.color.textTertiary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.smallSize
        }
    }

    ListView {
        id: bookList
        anchors.top: versionRow.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: Theme.space.md
        anchors.leftMargin: Theme.space.md
        anchors.rightMargin: Theme.space.md
        anchors.bottomMargin: Theme.space.md
        visible: root.filtered.length > 0
        model: root.filtered
        clip: true
        cacheBuffer: 300
        spacing: 2

        delegate: Item {
            width: bookList.width
            height: 44

            Rectangle {
                anchors.fill: parent
                anchors.leftMargin: Theme.space.sm
                anchors.rightMargin: Theme.space.sm
                radius: Theme.radius.md
                color: bookMa.containsMouse ? Theme.color.elevated : "transparent"

                Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
            }

            Text {
                anchors.left: parent.left
                anchors.leftMargin: Theme.space.xl
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.name
                color: Theme.color.textPrimary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize
                font.weight: Theme.font.weightMedium
            }

            Text {
                anchors.right: parent.right
                anchors.rightMargin: Theme.space.xl
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.chapters + " " + qsTr("chapters")
                color: Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
            }

            MouseArea {
                id: bookMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onDoubleClicked: {
                    AppState.addScheduleItem({
                        title:     modelData.name + " 1:1",
                        subtitle:  (AppState.activeLibraryGroup.scripture || "KJV").toUpperCase() + " · 1 " + qsTr("verse"),
                        typeName:  "SCRIPTURE",
                        typeColor: Theme.color.typeScripture,
                        data:      [{ content: qsTr("Verse content placeholder for ") + modelData.name + " 1:1" }]
                    })
                }
            }
        }
    }
}
