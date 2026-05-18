import QtQuick
import QtQuick.Layouts

// Right side of the bottom row — the actual tab content. Lazy: each tab
// is a Loader that becomes active only after first visit and stays active
// afterward (preserving scroll position and other transient UI state).
//
// All 5 children share the same geometry via StackLayout; only the child
// at currentIndex is shown. Inactive Loaders cost nothing until first viewed.
StackLayout {
    id: root

    currentIndex: AppState.activeTab

    // ── Focus claim for empty-space clicks ──────────────────────────────
    // Covers the "clicked inside the library area but not on any row"
    // case — gaps between rows, padding around the list, headers
    // without their own click handler, etc. Row clicks themselves go
    // through each tab's MouseArea, which grabs the press exclusively
    // before this TapHandler sees it; those handlers call
    // AppState.setActiveFocus("library") directly. Splitting the work
    // this way is what's needed because PointerHandlers don't preempt
    // MouseArea exclusive grabs — they only fire for events that no
    // child MouseArea claims.
    TapHandler {
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onPressedChanged: if (pressed) AppState.setActiveFocus("library")
    }

    Loader {
        Layout.fillWidth: true
        Layout.fillHeight: true
        asynchronous: true
        active: AppState.viewedTabs.indexOf(0) !== -1
        sourceComponent: songsComp
    }
    Loader {
        Layout.fillWidth: true
        Layout.fillHeight: true
        asynchronous: true
        active: AppState.viewedTabs.indexOf(1) !== -1
        sourceComponent: scriptureComp
    }
    Loader {
        Layout.fillWidth: true
        Layout.fillHeight: true
        asynchronous: true
        active: AppState.viewedTabs.indexOf(2) !== -1
        sourceComponent: strongsComp
    }
    Loader {
        Layout.fillWidth: true
        Layout.fillHeight: true
        asynchronous: true
        active: AppState.viewedTabs.indexOf(3) !== -1
        sourceComponent: mediaComp
    }
    Loader {
        Layout.fillWidth: true
        Layout.fillHeight: true
        asynchronous: true
        active: AppState.viewedTabs.indexOf(4) !== -1
        sourceComponent: themesComp
    }

    // Components reference module-registered types by name. The Crater
    // module includes all qml/tabs/*.qml files, so SongsTab, ScriptureTab,
    // etc. resolve without any source-path gymnastics.
    Component { id: songsComp;     SongsTab     { } }
    Component { id: scriptureComp; ScriptureTab { } }
    Component { id: strongsComp;   StrongsTab   { } }
    Component { id: mediaComp;     MediaTab     { } }
    Component { id: themesComp;    ThemesTab    { } }
}
