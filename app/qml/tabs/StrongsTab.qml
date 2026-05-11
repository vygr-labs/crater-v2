import QtQuick

// Strong's tab — placeholder until a real concordance service exists.
// The empty state copy explains what the tab will do once built.
Item {
    id: root

    EmptyState {
        anchors.fill: parent
        iconName: "book"
        title: qsTr("Strong's Concordance")
        body: qsTr("Search Strong's numbers, Greek, or Hebrew words. The concordance database loads on demand the first time you open this tab.")
    }
}
