import QtQuick
import QtQuick.Layouts

// Scripture — default Bible version, verse number display, the translations
// this profile lists (and adding or removing Bibles from files), translation
// preloading, Strong's tab.
// Highlight-current-verse and footer-line rows are aspirational (no
// rendering site yet) and carry the "Soon" badge.
Item {
    id: root

    // All rows read/write SettingsService directly (defaultScriptureVersion,
    // showVerseNumbers, highlightCurrentVerse, showScriptureFooter,
    // showStrongsTab).

    Flickable {
        anchors.fill: parent
        contentHeight: layout.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: layout
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Theme.space.xl
            anchors.rightMargin: Theme.space.xl
            anchors.topMargin: Theme.space.xxxl
            spacing: 0

            // ── READING ──────────────────────────────────────────────────
            SettingsSectionHeader { title: qsTr("Reading"); first: true }

            SettingRow {
                title: qsTr("Default version")
                description: qsTr("Version preselected when opening Scripture")
                Combobox {
                    width: 180
                    searchable: false
                    // One option per installed translation, shown by code
                    // ("KJV", "NIV") — the same vocabulary the scripture
                    // sidebar uses. Follows translationsRevision, so a Bible
                    // added or removed shows up here at once.
                    options: {
                        BibleService.translationsRevision   // follow a reorder
                        return BibleService.translations().map(function(t) { return t.code })
                    }
                    value: SettingsService.defaultScriptureVersion
                    onValueSelected: function(code) {
                        // Persist for next launch AND apply immediately — flip
                        // the scripture tab to the chosen version now (same path
                        // as a sidebar translation switch). Without the live
                        // apply, the change would silently wait for a restart
                        // and read as broken.
                        SettingsService.defaultScriptureVersion = code
                        AppState.setLibraryGroup("scripture", code.toLowerCase())
                    }
                }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            SettingRow {
                title: qsTr("Show verse numbers")
                ToggleSwitch {
                    value: SettingsService.showVerseNumbers
                    onToggled: SettingsService.showVerseNumbers = !SettingsService.showVerseNumbers }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            SettingRow {
                title: qsTr("Highlight current verse")
                description: qsTr("Step a multi-verse passage one verse at a time, dimming the rest")
                ToggleSwitch {
                    value: SettingsService.highlightCurrentVerse
                    onToggled: SettingsService.highlightCurrentVerse = !SettingsService.highlightCurrentVerse }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            SettingRow {
                title: qsTr("Show book:chapter in footer")
                description: qsTr("Render a reference line at the bottom of the slide")
                ToggleSwitch {
                    value: SettingsService.showScriptureFooter
                    onToggled: SettingsService.showScriptureFooter = !SettingsService.showScriptureFooter }
            }

            // ── PERFORMANCE ──────────────────────────────────────────────
            // ── TRANSLATIONS ─────────────────────────────────────────────
            // The Bible library is shared by every profile. This list only
            // picks what this profile shows; unticked ones stay installed,
            // reachable from the sidebar's More card or by typing the code.
            SettingsSectionHeader { title: qsTr("Translations in this profile") }

            Text {
                Layout.fillWidth: true
                Layout.bottomMargin: Theme.space.sm
                text: qsTr("Every profile shares the same Bibles. Untick the ones this profile doesn't need in its lists. Drag the cards in the Scripture sidebar to change their order.")
                wrapMode: Text.WordWrap
                color: Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
            }

            Repeater {
                model: { BibleService.translationsRevision; return BibleService.allTranslations() }
                delegate: RowLayout {
                    id: translationRow
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: Theme.space.sm

                    CheckRow {
                        Layout.fillWidth: true
                        label: String(translationRow.modelData.code)
                        detail: String(translationRow.modelData.description || "")
                        checked: !translationRow.modelData.hidden
                        onToggled: {
                            const code = String(translationRow.modelData.code)
                            const up = code.toUpperCase()
                            let hidden = SettingsService.hiddenTranslations
                                .filter(function(c) { return String(c).toUpperCase() !== up })
                            if (!translationRow.modelData.hidden) {
                                // Keep at least one shown.
                                const shown = BibleService.translations().length
                                if (shown <= 1) return
                                hidden.push(code)
                            }
                            SettingsService.hiddenTranslations = hidden
                        }
                    }
                    // Only for a Bible someone added from a file. The ones
                    // Crater ships stay; unticking hides them instead.
                    GhostButton {
                        visible: translationRow.modelData.removable === true
                        enabled: root._removeRequest === -1   // one removal at a time
                        text: qsTr("Remove")
                        onClicked: root.askRemove(String(translationRow.modelData.code),
                                                  String(translationRow.modelData.description || ""))
                    }
                }
            }

            Row {
                Layout.topMargin: Theme.space.sm
                spacing: Theme.space.md
                GhostButton {
                    iconName: "plus"
                    text: qsTr("Add a Bible from a file...")
                    onClicked: AppState.openModal("bibleImport", {})
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Zefania XML, OpenSong, OSIS, USFM or USX")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                }
            }
            Text {
                visible: root.removeError.length > 0
                Layout.fillWidth: true
                Layout.topMargin: Theme.space.xs
                text: root.removeError
                wrapMode: Text.WordWrap
                color: Theme.color.live
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
            }

            SettingsSectionHeader { title: qsTr("Performance") }

            // The only row here whose description can run long (and grows
            // with the UI font size), so it wraps and sizes to its text
            // instead of eliding the memory cost away.
            SettingRow {
                title: qsTr("Preload all Bible translations")
                description: qsTr("Instant first switch to any translation. About 13 MB of memory each.")
                ToggleSwitch { id: preloadToggle
                    value: SettingsService.preloadTranslations
                    onToggled: SettingsService.preloadTranslations = !SettingsService.preloadTranslations }
            }

            // ── TABS ─────────────────────────────────────────────────────
            SettingsSectionHeader { title: qsTr("Tabs") }

            SettingRow {
                title: qsTr("Show Strong's tab")
                description: qsTr("Greek/Hebrew concordance lookup")
                ToggleSwitch {
                    value: SettingsService.showStrongsTab
                    onToggled: SettingsService.showStrongsTab = !SettingsService.showStrongsTab }
            }

            Item { Layout.fillWidth: true; Layout.preferredHeight: Theme.space.xl }
        }
    }

    // ── Removing an added Bible ─────────────────────────────────────────
    // The confirm card's code, and the removal it started. Only that
    // removal's failure shows here, not an import's.
    property string _askedCode: ""
    property int    _removeRequest: -1
    property string removeError: ""

    function askRemove(code, name) {
        if (root._removeRequest !== -1) return
        root._askedCode = code
        root.removeError = ""
        const named = name.replace(/\.+$/, "")
        removeConfirm.title = qsTr("Remove %1?").arg(code)
        removeConfirm.body = (named.length > 0 && named !== code ? named + ". " : "")
            + qsTr("This removes it from every profile, because they all share one Bible library. Schedules keep the verses they already hold. You can add it again from its file.")
        removeConfirm.openConfirm()
    }

    Connections {
        target: BibleImporter
        function onFailed(request, reason) {
            if (request !== root._removeRequest) return
            root.removeError = reason
            root._removeRequest = -1
        }
        function onRemoved(request, code) {
            if (request === root._removeRequest) root._removeRequest = -1
        }
    }

    ConfirmationOverlay {
        id: removeConfirm
        anchors.fill: parent
        confirmLabel: qsTr("Remove")
        onConfirmed: {
            if (root._askedCode.length > 0) root._removeRequest = BibleImporter.remove(root._askedCode)
            root._askedCode = ""
        }
        onCancelled: root._askedCode = ""
    }
}
