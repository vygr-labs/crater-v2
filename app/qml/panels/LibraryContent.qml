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
