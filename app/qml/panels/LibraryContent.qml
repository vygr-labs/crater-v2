import QtQuick
import QtQuick.Layouts

// Right side of the bottom row — the actual tab content. Lazy: each tab
// is a Loader that becomes active only after first visit and stays active
// afterward (preserving scroll position and other transient UI state).
//
// Every child shares the same geometry via StackLayout; only the child at
// currentIndex is shown. Inactive Loaders cost nothing until first viewed.
StackLayout {
    id: root

    // Fixed slot order of the Loader children below — this never changes,
    // not even when the Strong's tab is hidden. The operator's current tab
    // is identified by KEY via AppState.tabKeys[activeTab]; _slotKeys maps
    // that key back to its StackLayout slot.
    //
    // Binding currentIndex straight to AppState.activeTab would be wrong:
    // when "Show Strong's tab" is off, AppState.tabKeys drops an entry, so
    // activeTab counts over {songs, scripture, media, presentations, themes}
    // — but these children still include strongs at slot 2. Indexing by the
    // raw activeTab would then render Strong's for "media" and Media for
    // "presentations". Resolving through the key keeps the tab strip and the
    // content panel in agreement.
    readonly property var _slotKeys: ["songs", "scripture", "strongs", "media",
                                      "presentations", "themes"]

    currentIndex: Math.max(0, _slotKeys.indexOf(AppState.tabKeys[AppState.activeTab]))

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

    // AppState.viewedTabs holds the KEYS of visited tabs (see AppState.qml) —
    // each Loader stays active once its own key has been seen. Keying off the
    // string rather than a slot index is what survives a Strong's show/hide.
    Loader {
        Layout.fillWidth: true
        Layout.fillHeight: true
        asynchronous: true
        active: AppState.viewedTabs.indexOf("songs") !== -1
        sourceComponent: songsComp
    }
    Loader {
        Layout.fillWidth: true
        Layout.fillHeight: true
        asynchronous: true
        active: AppState.viewedTabs.indexOf("scripture") !== -1
        sourceComponent: scriptureComp
    }
    Loader {
        Layout.fillWidth: true
        Layout.fillHeight: true
        asynchronous: true
        active: AppState.viewedTabs.indexOf("strongs") !== -1
        sourceComponent: strongsComp
    }
    Loader {
        Layout.fillWidth: true
        Layout.fillHeight: true
        asynchronous: true
        active: AppState.viewedTabs.indexOf("media") !== -1
        sourceComponent: mediaComp
    }
    Loader {
        Layout.fillWidth: true
        Layout.fillHeight: true
        asynchronous: true
        active: AppState.viewedTabs.indexOf("presentations") !== -1
        sourceComponent: presentationsComp
    }
    Loader {
        Layout.fillWidth: true
        Layout.fillHeight: true
        asynchronous: true
        active: AppState.viewedTabs.indexOf("themes") !== -1
        sourceComponent: themesComp
    }

    // Components reference module-registered types by name. The Crater
    // module includes all qml/tabs/*.qml files, so SongsTab, ScriptureTab,
    // etc. resolve without any source-path gymnastics.
    Component { id: songsComp;     SongsTab     { } }
    Component { id: scriptureComp; ScriptureTab { } }
    Component { id: strongsComp;   StrongsTab   { } }
    Component { id: mediaComp;     MediaTab     { } }
    Component { id: presentationsComp; PresentationsTab { } }
    Component { id: themesComp;    ThemesTab    { } }
}
