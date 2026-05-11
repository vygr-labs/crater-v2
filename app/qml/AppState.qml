pragma Singleton

import QtQuick

// AppState — single source of truth for transient UI state.
//
// Per ARCHITECTURE.md §9, anything that holds selected-row, hover, focus,
// or modal-open state lives in QML, not C++. This file is the QML side
// of that contract: no persistence, no DB, no IPC. When a real service
// lands (SongService, ScheduleService, etc.), the *lists* below will be
// replaced by service-exposed models — but the *flow state* (activeTab,
// activeModal, selectedScheduleIndex) stays here forever.
//
// Performance note: ListModels emit granular insert/remove/move signals
// that ListView consumes for animated updates. Using `property var` for
// these would force a full re-bind on every mutation.
QtObject {
    id: state

    // ─── Tab navigation ─────────────────────────────────────────────────
    readonly property int tabCount: 5
    readonly property var tabKeys: ["songs", "scripture", "strongs", "media", "themes"]

    property int activeTab: 0
    property var viewedTabs: [0]   // tabs that have been visited (keeps Loaders alive)

    function setActiveTab(i) {
        if (i < 0 || i >= tabCount) return
        if (activeTab === i) return
        if (viewedTabs.indexOf(i) === -1) {
            viewedTabs = viewedTabs.concat([i])
        }
        activeTab = i
    }

    function cycleTab(dir) {
        // dir: +1 forward, -1 back, wraps around
        const next = (activeTab + dir + tabCount) % tabCount
        setActiveTab(next)
    }

    // ─── Schedule selection & live state ────────────────────────────────
    property int  selectedScheduleIndex: -1   // what's in Preview pane (-1 = nothing)
    property int  liveScheduleIndex:     -1   // what's on Live pane (-1 = nothing)
    property int  previewSubIndex:        0   // page within selected item shown in Preview
    property int  liveSubIndex:           0   // page within live item shown in Live
    property bool showLogo:           false   // Logo button toggled on/off
    property bool isClear:            false   // display cleared (overrides live content)

    function selectScheduleItem(i) {
        if (i < 0 || i >= scheduleItems.count) {
            selectedScheduleIndex = -1
            previewSubIndex = 0
            return
        }
        selectedScheduleIndex = i
        previewSubIndex = 0
    }

    function goLive() {
        // Promote the previewed item to live. Cheap no-op if nothing previewed.
        if (selectedScheduleIndex < 0) return
        liveScheduleIndex = selectedScheduleIndex
        liveSubIndex = previewSubIndex
        isClear = false
    }

    function clearLive() {
        isClear = true
        liveScheduleIndex = -1
        liveSubIndex = 0
    }

    function toggleLogo() {
        showLogo = !showLogo
        // Real wiring: when ProjectionService lands, this'll signal
        // it to render the logo overlay regardless of live content.
    }

    // ─── Modal stack ────────────────────────────────────────────────────
    // Single active modal (presentation UIs rarely need stacked modals;
    // we can grow to a stack array later if a flow demands it).
    property string activeModal: ""        // "" | "settings" | "songEditor" | "themeEditor" | "naming" | "confirm" | "import" | "scheduleDropdown"
    property var    modalProps: ({})       // dict of props passed to the modal (title, body, callbacks, etc.)
    property string settingsSection: "appearance"  // current section in SettingsDialog

    function openModal(name, props) {
        modalProps = props || {}
        activeModal = name
    }

    function closeModal() {
        activeModal = ""
        modalProps = {}
    }

    // ─── Per-tab search & group selection ───────────────────────────────
    // Stored as JS objects keyed by tabKey. Switching tabs and back
    // preserves where you were — important when building a service from
    // multiple sources.
    property var searchText: ({
        "songs": "", "scripture": "", "strongs": "", "media": "", "themes": ""
    })

    property var activeLibraryGroup: ({
        "songs":     "all-songs",
        "scripture": "kjv",
        "strongs":   "greek",
        "media":     "all-media",
        "themes":    "all-themes"
    })

    function setSearch(tabKey, text) {
        // Mutating a property var means reassigning the whole object so QML
        // emits the change signal. (Direct key mutation doesn't fire bindings.)
        let copy = Object.assign({}, searchText)
        copy[tabKey] = text
        searchText = copy
    }

    function setLibraryGroup(tabKey, group) {
        let copy = Object.assign({}, activeLibraryGroup)
        copy[tabKey] = group
        activeLibraryGroup = copy
    }

    // ─── Schedule items (the working "playlist") ────────────────────────
    readonly property ListModel scheduleItems: ListModel { }

    function addScheduleItem(item) {
        scheduleItems.append(item)
    }

    function removeScheduleItem(i) {
        if (i < 0 || i >= scheduleItems.count) return
        scheduleItems.remove(i)
        if (selectedScheduleIndex === i) {
            selectedScheduleIndex = -1
        } else if (selectedScheduleIndex > i) {
            selectedScheduleIndex -= 1
        }
        if (liveScheduleIndex === i) {
            liveScheduleIndex = -1
        } else if (liveScheduleIndex > i) {
            liveScheduleIndex -= 1
        }
    }

    function moveScheduleItem(from, to) {
        if (from === to) return
        scheduleItems.move(from, to, 1)
        // Selection indices need fixup
        const fixup = (idx) => {
            if (idx === from) return to
            if (from < to && idx > from && idx <= to) return idx - 1
            if (from > to && idx >= to && idx < from) return idx + 1
            return idx
        }
        selectedScheduleIndex = fixup(selectedScheduleIndex)
        liveScheduleIndex     = fixup(liveScheduleIndex)
    }

    // ─── Library data (mock — replaced by services later) ───────────────
    readonly property ListModel songsList: ListModel { }
    readonly property ListModel savedSchedules: ListModel { }
    readonly property ListModel bibleVersions: ListModel { }
    readonly property ListModel themesList: ListModel { }
    readonly property ListModel mediaList: ListModel { }
    readonly property ListModel collectionsList: ListModel { }

    // ─── Mock-data seeding ──────────────────────────────────────────────
    // Done at construction. When services land, delete this whole block;
    // the QML upstream binds to model.count etc. and naturally handles
    // empty initial states.
    Component.onCompleted: {
        // Songs — 8 hymns/worship songs as plausible content.
        const songs = [
            { title: "Amazing Grace",                 author: "John Newton",        favorite: true,  ccli: "22025" },
            { title: "How Great Thou Art",            author: "Stuart K. Hine",     favorite: true,  ccli: "14181" },
            { title: "Be Thou My Vision",             author: "Traditional Irish",  favorite: false, ccli: "30639" },
            { title: "10,000 Reasons (Bless the Lord)",author: "Matt Redman",       favorite: true,  ccli: "6016351" },
            { title: "In Christ Alone",               author: "Keith Getty",        favorite: false, ccli: "3350395" },
            { title: "Cornerstone",                   author: "Hillsong",           favorite: false, ccli: "6158927" },
            { title: "What a Beautiful Name",         author: "Hillsong Worship",   favorite: true,  ccli: "7068424" },
            { title: "Goodness of God",               author: "Bethel Music",       favorite: false, ccli: "7117726" }
        ]
        for (let i = 0; i < songs.length; i++) songsList.append(songs[i])

        // Saved schedules — what the Schedule dropdown popover shows.
        savedSchedules.append({ name: "Sunday AM — 2026-05-10",     items: 8, modified: "2 days ago" })
        savedSchedules.append({ name: "Wednesday Bible Study",      items: 4, modified: "5 days ago" })
        savedSchedules.append({ name: "Easter Service 2026",        items: 14, modified: "3 weeks ago" })

        // Bible translations.
        bibleVersions.append({ abbrev: "KJV", name: "King James Version",     installed: true  })
        bibleVersions.append({ abbrev: "NIV", name: "New International Vers.", installed: true  })
        bibleVersions.append({ abbrev: "ESV", name: "English Standard Vers.",  installed: true  })
        bibleVersions.append({ abbrev: "NLT", name: "New Living Translation",  installed: false })

        // Themes.
        themesList.append({ name: "Classic Dark",       background: "#0a0a0d", accent: "#d4a574" })
        themesList.append({ name: "Stage Bold",         background: "#1a0b1f", accent: "#e85a4a" })
        themesList.append({ name: "Minimalist Light",   background: "#f5f5f0", accent: "#3a3a45" })

        // Media — 6 placeholder gradient tiles.
        for (let m = 1; m <= 6; m++) {
            mediaList.append({ name: "Background " + m, type: m % 2 === 0 ? "video" : "image" })
        }

        // Collections (for the Songs sidebar's "My Collections" sub-tree).
        collectionsList.append({ name: "Hymns",         count: 24 })
        collectionsList.append({ name: "Modern Worship", count: 18 })
        collectionsList.append({ name: "Christmas",      count: 12 })

        // Seed 2 schedule items so the flow is immediately demonstrable
        // (preview/go-live/clear work on launch with zero clicks).
        scheduleItems.append({
            title:    "Amazing Grace",
            subtitle: "5 verses · 3 min",
            typeName: "SONG",
            typeColor: "#d4a574",
            data:     [
                { content: "Amazing grace, how sweet the sound\nThat saved a wretch like me" },
                { content: "I once was lost, but now am found\nWas blind, but now I see" },
                { content: "'Twas grace that taught my heart to fear\nAnd grace my fears relieved" },
                { content: "How precious did that grace appear\nThe hour I first believed" },
                { content: "When we've been there ten thousand years\nBright shining as the sun" }
            ]
        })
        scheduleItems.append({
            title:    "John 3:16",
            subtitle: "KJV · 1 verse",
            typeName: "SCRIPTURE",
            typeColor: "#5b9df0",
            data:     [
                { content: "For God so loved the world, that he gave his only begotten Son,\nthat whosoever believeth in him should not perish, but have everlasting life." }
            ]
        })
    }
}
