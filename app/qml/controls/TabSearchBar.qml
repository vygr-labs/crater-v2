import QtQuick

// Per-tab search bar. Renders a different input variant for each library tab
// so the search experience matches Electron:
//
//   songs     ─ leading "mode" button (opens popover) + clear (×) + Ctrl+A hint
//               Modes: title / lyrics / author / recent / oldest / newest
//   scripture ─ leading "mode" button (book-open ↔ search toggle) + Ctrl+F hint
//               Modes: reference (parses "jn 3:16") / search (FTS5)
//               Interpreted hint renders below the input when in reference mode.
//   media     ─ leading search icon + clear (×) + Ctrl+A hint
//   strongs / themes ─ plain search bar (mirrors the old SearchBar control)
//
// State for query + mode lives on AppState (searchText[tabKey] +
// librarySearchMode[tabKey]) so the tab content panel can re-read them. The
// bar itself stays presentational — no debouncing here.
//
// TODO (deferred): scripture reference mode in electron has TWO sub-modes
// keyed off settings.scriptureInputMode:
//   "controlled" — segmented stage editor: book → chapter → verse, each
//                  segment auto-selected; Tab/Space advances; Backspace at
//                  segment start retreats; click on a segment selects it
//   "crater"     — free-text + autocomplete: typing "gen " expands to
//                  "Genesis "; an "Interpreted: Genesis 1:1" preview line
//                  shows under the input; Tab/Enter accepts the parsed ref
// Today this Qt bar offers neither — operators type the full ref freehand and
// rely on BibleService.parseReference to find a match. See
// electron/src/components/app/scripture/ScriptureSelection.tsx
// (handleSpecialSearch / parseScriptureInput / handleInputKeyDown) for the
// full reference. Track as a follow-up; not blocking the basic UX.
Item {
    id: root

    readonly property string tabKey: AppState.tabKeys[AppState.activeTab]
    readonly property string mode:
        tabKey === "songs"     ? (AppState.librarySearchMode.songs     || "lyrics")
      : tabKey === "scripture" ? (AppState.librarySearchMode.scripture || "reference")
      : tabKey === "media"     ? (AppState.librarySearchMode.media     || "title")
                               : ""

    readonly property string queryText: AppState.searchText[tabKey] || ""

    // Songs search-mode metadata (icon + placeholder + label). Mirrors the
    // SONG_SEARCH_MODE_* constants in electron/.../SongSelection.tsx.
    readonly property var songModes: [
        { id: "title",   label: qsTr("Title"),              icon: "search",        placeholder: qsTr("Search by title…") },
        { id: "lyrics",  label: qsTr("Lyrics"),             icon: "file-text",     placeholder: qsTr("Search in lyrics…") },
        { id: "author",  label: qsTr("Author"),             icon: "user",          placeholder: qsTr("Search by author…") },
        { id: "recent",  label: qsTr("Recently Modified"),  icon: "clock",         placeholder: qsTr("Filter recently modified…") },
        { id: "oldest",  label: qsTr("Oldest First"),       icon: "sort-asc",      placeholder: qsTr("Filter oldest songs…") },
        { id: "newest",  label: qsTr("Newest First"),       icon: "sort-desc",     placeholder: qsTr("Filter newest songs…") }
    ]

    function songMode(id) {
        for (let i = 0; i < songModes.length; i++) {
            if (songModes[i].id === id) return songModes[i]
        }
        return songModes[1]   // lyrics default
    }

    // Compute placeholder + leading icon depending on tab + mode.
    readonly property string leadingIconName: {
        if (tabKey === "songs")     return songMode(mode).icon
        if (tabKey === "scripture") return mode === "reference" ? "book-open" : "search"
        return "search"
    }
    readonly property string placeholderText: {
        if (tabKey === "songs")     return songMode(mode).placeholder
        if (tabKey === "scripture") return mode === "reference" ? qsTr("Genesis 1:1") : qsTr("Search verses…")
        if (tabKey === "media")     return qsTr("Search media…")
        if (tabKey === "strongs")   return qsTr("Search Strong's…")
        if (tabKey === "themes")    return qsTr("Search themes…")
        return qsTr("Search…")
    }
    readonly property string shortcutLabel:
        tabKey === "scripture" ? "Ctrl+F" : "Ctrl+A"

    // Interpreted reference (scripture tab, reference mode only). The
    // BibleService.parseReference already returns the full Verse, so we just
    // display "<book> <chapter>:<verse>" or "—" when unparseable.
    readonly property string activeTranslation:
        (AppState.activeLibraryGroup.scripture || "").toUpperCase()
    readonly property var parsedRef: {
        if (tabKey !== "scripture") return null
        if (mode !== "reference")   return null
        if (!queryText)             return null
        if (!activeTranslation)     return null
        const v = BibleService.parseReference(queryText, activeTranslation)
        return (v && v.text && v.text.length > 0) ? v : null
    }

    // Expose the input field so the tab can forceActiveFocus on it when
    // toggling mode / clearing query.
    property alias input: inputField

    // Toggle the scripture search mode (also bound to Ctrl+F at app level).
    function toggleScriptureMode() {
        const next = mode === "reference" ? "search" : "reference"
        AppState.setLibrarySearchMode("scripture", next)
        AppState.setSearch("scripture", "")
        inputField.forceActiveFocus()
    }

    // Cycle / pick the songs search mode.
    function setSongsMode(id) {
        AppState.setLibrarySearchMode("songs", id)
        inputField.forceActiveFocus()
    }

    implicitHeight: hintLabel.visible ? (inputBox.height + hintLabel.height + 4)
                                      : inputBox.height
    implicitWidth: 240

    // Move focus into the search input when the operator switches tabs so
    // they can start typing immediately. Mirrors Electron's createEffect that
    // focuses the per-tab search input on panel-focus change.
    Connections {
        target: AppState
        function onActiveTabChanged() {
            Qt.callLater(function() { inputField.forceActiveFocus() })
        }
    }
    Component.onCompleted: Qt.callLater(function() { inputField.forceActiveFocus() })

    // ── Search input row ────────────────────────────────────────────────
    Rectangle {
        id: inputBox
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 36
        radius: Theme.radius.md
        color: Theme.color.canvas
        border.color: inputField.activeFocus ? Theme.color.brand : Theme.color.borderStrong
        border.width: 1

        Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }

        // ── Leading: mode trigger (clickable when mode-switching is allowed)
        Rectangle {
            id: modeButton
            anchors.left: parent.left
            anchors.leftMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            width: 28
            height: 28
            radius: 4
            // Songs and Scripture get a real trigger; others render as a static icon.
            readonly property bool interactive:
                root.tabKey === "songs" || root.tabKey === "scripture"
            color: interactive && modeMa.containsMouse ? Theme.color.overlay : "transparent"
            Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

            Row {
                anchors.centerIn: parent
                spacing: 2

                AppIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: root.leadingIconName
                    color: Theme.color.textSecondary
                    size: 15
                }
                AppIcon {
                    visible: root.tabKey === "songs"
                    anchors.verticalCenter: parent.verticalCenter
                    name: "chevron-down"
                    color: Theme.color.textTertiary
                    size: 9
                }
            }

            MouseArea {
                id: modeMa
                anchors.fill: parent
                enabled: modeButton.interactive
                hoverEnabled: true
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor

                onClicked: {
                    if (root.tabKey === "songs") {
                        // Build the popover menu items inline from songModes.
                        const items = []
                        for (let i = 0; i < root.songModes.length; i++) {
                            const m = root.songModes[i]
                            items.push({
                                label:    m.label,
                                iconName: m.icon,
                                detail:   root.mode === m.id ? "✓" : "",
                                action:   function() { root.setSongsMode(m.id) }
                            })
                        }
                        const p = modeButton.mapToItem(null, 0, modeButton.height + 6)
                        AppState.openModal("contextMenu", {
                            anchorX:   p.x,
                            anchorY:   p.y,
                            menuWidth: 200,
                            items:     items
                        })
                    } else if (root.tabKey === "scripture") {
                        root.toggleScriptureMode()
                    }
                }
            }
        }

        TextInput {
            id: inputField
            anchors.left: modeButton.right
            anchors.leftMargin: 4
            anchors.right: clearBtn.visible ? clearBtn.left
                          : hintChip.visible ? hintChip.left
                                             : parent.right
            anchors.rightMargin: Theme.space.sm
            anchors.verticalCenter: parent.verticalCenter
            color: Theme.color.textPrimary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.bodySize
            selectByMouse: true
            clip: true
            text: root.queryText
            onTextChanged: {
                if (text !== root.queryText) AppState.setSearch(root.tabKey, text)
            }

            // Claim keyboard-focus ownership for the library panel whenever
            // the input gains focus. Main.qml's window-level shortcuts read
            // AppState.activeFocusPanel to decide whether Up/Down navigates
            // the library list or the schedule list — without this claim,
            // the schedule would steal the arrows even while the operator
            // is clearly typing in the library search.
            onActiveFocusChanged: {
                if (activeFocus) AppState.setActiveFocus("library")
            }

            // Keyboard nav routed to the active library tab — but ONLY when
            // the library actually owns focus. If the operator clicked a
            // schedule row (flipping activeFocusPanel to "schedule") the
            // input may still hold OS-level focus visually; in that case we
            // bow out and let Main.qml's window shortcut route the key to
            // the schedule pane instead.
            Keys.onUpPressed: function(event) {
                if (AppState.activeFocusPanel !== "library") return
                AppState.libraryNavigateUp()
                event.accepted = true
            }
            Keys.onDownPressed: function(event) {
                if (AppState.activeFocusPanel !== "library") return
                AppState.libraryNavigateDown()
                event.accepted = true
            }
            Keys.onReturnPressed: function(event) {
                if (AppState.activeFocusPanel !== "library") return
                AppState.libraryActivate()
                event.accepted = true
            }
            Keys.onEnterPressed: function(event) {
                if (AppState.activeFocusPanel !== "library") return
                AppState.libraryActivate()
                event.accepted = true
            }

            // ShortcutOverride mirrors the same gate: when we own focus,
            // accept the override so the window-level Shortcut in Main.qml
            // is suppressed (preventing double-fire on Up/Down/Enter). When
            // we don't own focus, leave the override unaccepted so the
            // window Shortcut activates and routes to the right panel.
            Keys.onShortcutOverride: function(event) {
                if (AppState.activeFocusPanel !== "library") return
                if (event.key === Qt.Key_Up
                 || event.key === Qt.Key_Down
                 || event.key === Qt.Key_Return
                 || event.key === Qt.Key_Enter) {
                    event.accepted = true
                }
            }

            // Placeholder
            Text {
                visible: !inputField.activeFocus && inputField.text.length === 0
                anchors.verticalCenter: parent.verticalCenter
                text: root.placeholderText
                color: Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize
            }
        }

        // Clear (×) — shows whenever there's text.
        Rectangle {
            id: clearBtn
            visible: inputField.text.length > 0
            anchors.right: hintChip.visible ? hintChip.left : parent.right
            anchors.rightMargin: hintChip.visible ? 2 : 6
            anchors.verticalCenter: parent.verticalCenter
            width: 22
            height: 22
            radius: 4
            color: clearMa.containsMouse ? Theme.color.overlay : "transparent"
            Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

            AppIcon {
                anchors.centerIn: parent
                name: "x"
                color: Theme.color.textTertiary
                size: 12
            }

            MouseArea {
                id: clearMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    AppState.setSearch(root.tabKey, "")
                    inputField.forceActiveFocus()
                }
            }
        }

        // Shortcut hint chip — visible whenever the input is empty, including
        // while focused. Matches electron, where the ⌘F badge is always shown
        // until the operator starts typing. (Previous behavior hid it on
        // focus, so it disappeared the moment the tab opened.)
        Rectangle {
            id: hintChip
            anchors.right: parent.right
            anchors.rightMargin: 5
            anchors.verticalCenter: parent.verticalCenter
            visible: inputField.text.length === 0
            width: 32; height: 18
            radius: 3
            color: Theme.color.elevated
            border.color: Theme.color.borderStrong
            border.width: 1

            Text {
                anchors.centerIn: parent
                text: root.shortcutLabel
                color: Theme.color.textTertiary
                font.family: Theme.font.monoFamily
                font.pixelSize: 9
            }
        }
    }

    // ── Interpreted hint (scripture / reference only) ───────────────────
    Text {
        id: hintLabel
        anchors.top: inputBox.bottom
        anchors.topMargin: 4
        anchors.left: parent.left
        anchors.leftMargin: 6
        visible: root.tabKey === "scripture"
              && root.mode === "reference"
              && root.queryText.length > 0
        text: root.parsedRef
              ? qsTr("Interpreted: ") + root.parsedRef.book + " "
                + root.parsedRef.chapter + ":" + root.parsedRef.verse
              : qsTr("Interpreted: —")
        color: root.parsedRef ? Theme.color.textSecondary : Theme.color.textTertiary
        font.family: Theme.font.family
        font.pixelSize: Theme.font.smallSize
    }
}
