import QtQuick
import QtQuick.Layouts

// Appearance — theme, font size, motion preferences, and UI language.
// Wired rows read/write SettingsService directly (no local mirror). The
// Theme picker writes SettingsService.themeMode (an id in Theme.themes, or
// "auto"); Theme.qml swaps the active palette live off that value. The
// Language picker drives TranslationService — it installs the chosen
// crater_<code>.qm catalog and retranslates the whole console live, no restart.
Item {
    id: root

    // Theme options split into a compact default set (Dark / Light / Midnight
    // + Auto — a single row) and an on-demand "More" set (everything else).
    // Keeping the extras behind a disclosure stops the tile grid from pushing
    // the rest of the Appearance page below the fold. ids are matched against
    // the live Theme.themes registry so this stays correct as the registry
    // grows or is reordered.
    readonly property var coreThemeIds: ["dark", "light", "midnight"]

    readonly property var coreThemeOptions: {
        var arr = []
        for (var i = 0; i < Theme.themes.length; i++)
            if (coreThemeIds.indexOf(Theme.themes[i].id) !== -1)
                arr.push({ id: Theme.themes[i].id, name: Theme.themes[i].name, auto: false })
        arr.push({ id: "auto", name: qsTr("Auto"), auto: true })
        return arr
    }

    readonly property var moreThemeOptions: {
        var arr = []
        for (var i = 0; i < Theme.themes.length; i++)
            if (coreThemeIds.indexOf(Theme.themes[i].id) === -1)
                arr.push({ id: Theme.themes[i].id, name: Theme.themes[i].name, auto: false })
        return arr
    }

    // Collapsed by default; the disclosure is a plain sticky toggle. The
    // active theme may live in the "More" set — it still carries its selected
    // check once the section is expanded.
    property bool showMore: false

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

            // ── THEME ────────────────────────────────────────────────────
            SettingsSectionHeader { title: qsTr("Theme"); first: true }

            // Theme picker — one swatch per registered palette + Auto. Each
            // swatch previews that palette's own colors (via Theme.paletteFor,
            // not the active Theme.color) so you see what you're switching to.
            // Clicking writes SettingsService.themeMode; Theme.qml re-points
            // Theme.color at the chosen palette and the whole console recolors
            // live. Operator console only — projected slides use their own
            // .craterheme themes and are unaffected.
            ColumnLayout {
                Layout.fillWidth: true
                Layout.topMargin: Theme.space.lg
                Layout.bottomMargin: Theme.space.lg
                spacing: Theme.space.md

                Column {
                    spacing: 2
                    Text { text: qsTr("Theme"); color: Theme.color.textPrimary
                           font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize
                           font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Color scheme of the operator console (does not affect projected output)")
                           color: Theme.color.textTertiary; font.family: Theme.font.family
                           font.pixelSize: Theme.font.smallSize }
                }

                // Core palettes — always shown (six built-ins + Auto).
                Flow {
                    Layout.fillWidth: true
                    spacing: Theme.space.md
                    Repeater { model: root.coreThemeOptions; delegate: swatchDelegate }
                }

                // Disclosure — reveals the Tier 2/3 palettes on demand so the
                // default view stays two rows tall and the settings below it
                // remain visible without scrolling.
                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 28
                    Row {
                        id: moreToggle
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 4
                        AppIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: root.showMore ? "chevron-down" : "chevron-right"
                            size: Theme.icon.sm
                            color: moreMa.containsMouse ? Theme.color.textPrimary : Theme.color.textSecondary
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.showMore ? qsTr("Fewer themes")
                                                : qsTr("More themes (%1)").arg(root.moreThemeOptions.length)
                            color: moreMa.containsMouse ? Theme.color.textPrimary : Theme.color.textSecondary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.smallSize
                            font.weight: Theme.font.weightMedium
                        }
                    }
                    MouseArea {
                        id: moreMa
                        anchors.left: moreToggle.left
                        anchors.verticalCenter: moreToggle.verticalCenter
                        width: moreToggle.width + Theme.space.sm
                        height: parent.height
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.showMore = !root.showMore
                    }
                }

                // Tier 2/3 palettes — collapsed by default; a Layout skips it
                // entirely while hidden, so no empty gap remains.
                Flow {
                    Layout.fillWidth: true
                    spacing: Theme.space.md
                    visible: root.showMore
                    Repeater { model: root.moreThemeOptions; delegate: swatchDelegate }
                }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 56

                Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                       text: qsTr("Font size"); color: Theme.color.textPrimary
                       font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize
                       font.weight: Theme.font.weightMedium }

                SegmentedControl {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 140; height: 30
                    radius: 0
                    current: SettingsService.fontSize
                    options: [
                        { value: "small",  label: qsTr("S") },
                        { value: "medium", label: qsTr("M") },
                        { value: "large",  label: qsTr("L") }
                    ]
                    onChanged: function(v) { SettingsService.fontSize = v }
                }
            }

            // ── PREFERENCES ──────────────────────────────────────────────
            SettingsSectionHeader { title: qsTr("Preferences") }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("Show CCLI badges"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Display copyright info next to songs"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
                }
                ToggleSwitch { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    value: SettingsService.showCcli
                    onToggled: SettingsService.showCcli = !SettingsService.showCcli }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("Reduce motion"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Disable hover and transition animations"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
                }
                ToggleSwitch { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    value: SettingsService.reduceMotion
                    onToggled: SettingsService.reduceMotion = !SettingsService.reduceMotion }
            }

            // ── LOCALE ───────────────────────────────────────────────────
            SettingsSectionHeader { title: qsTr("Locale") }

            // Language picker — swaps the console UI language LIVE, no restart.
            // TranslationService.availableLanguages lists English, every bundled
            // translated catalog, and any crater_<code>.qm dropped into the user
            // translations folder. Picking a row writes the choice through
            // SettingsService.language; TranslationService reinstalls the
            // QTranslator and retranslates every qsTr binding on the spot. The
            // native + English label ("Español (Spanish)") keeps rows findable by
            // typing either name in the dropdown's search field.
            Item {
                id: langRow
                Layout.fillWidth: true
                Layout.preferredHeight: 56

                readonly property var langs: TranslationService.availableLanguages
                readonly property string currentCode: TranslationService.currentLanguage

                function labelForCode(code) {
                    for (var i = 0; i < langs.length; i++)
                        if (langs[i].code === code) return langs[i].label
                    return code
                }
                function codeForLabel(label) {
                    for (var i = 0; i < langs.length; i++)
                        if (langs[i].label === label) return langs[i].code
                    return "en"
                }

                Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                       text: qsTr("Language"); color: Theme.color.textPrimary
                       font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize
                       font.weight: Theme.font.weightMedium }

                Combobox {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 240
                    searchable: true
                    placeholder: qsTr("Select language…")
                    options: langRow.langs.map(function(l) { return l.label })
                    value: langRow.labelForCode(langRow.currentCode)
                    onValueSelected: function(label) {
                        TranslationService.setLanguage(langRow.codeForLabel(label))
                    }
                }
            }

            // Honest note: everything past English is machine-assisted, so
            // operators expect the occasional rough edge and know English is
            // authoritative. Untranslated strings fall back to English.
            Text {
                Layout.fillWidth: true
                Layout.topMargin: Theme.space.xs
                text: qsTr("Interface translations are AI- and community-assisted; English is the source language. Missing text falls back to English.")
                color: Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                wrapMode: Text.WordWrap
            }

            Item { Layout.fillWidth: true; Layout.preferredHeight: Theme.space.xl }
        }
    }

    // Reusable theme-swatch delegate, shared by the core and "More" Flows.
    // Previews modelData's own palette (Theme.paletteFor, not the active
    // Theme.color) so each tile shows what you'd switch to. Click writes
    // SettingsService.themeMode and the whole console recolors live.
    Component {
        id: swatchDelegate
        Column {
            id: sw
            required property var modelData
            readonly property bool selected: SettingsService.themeMode === modelData.id
            readonly property QtObject pal: Theme.paletteFor(modelData.id)
            width: 104
            spacing: Theme.space.xs

            // Preview card
            Rectangle {
                width: parent.width; height: 64
                radius: Theme.radius.sm
                clip: true
                color: modelData.auto ? "transparent" : sw.pal.canvas
                border.width: sw.selected ? 2 : 1
                border.color: sw.selected ? Theme.color.brand : Theme.color.borderSubtle

                Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }

                // Auto: split light | dark to signal "follows OS"
                Row {
                    visible: modelData.auto
                    anchors.fill: parent
                    anchors.margins: 1
                    Rectangle { width: parent.width / 2; height: parent.height
                                color: Theme.paletteFor("light").canvas }
                    Rectangle { width: parent.width / 2; height: parent.height
                                color: Theme.paletteFor("dark").canvas }
                }

                // Concrete theme: faux panel + brand dot + text lines
                Column {
                    visible: !modelData.auto
                    anchors.fill: parent
                    anchors.margins: 8
                    spacing: 5

                    Rectangle {
                        width: parent.width; height: 16; radius: 3
                        color: sw.pal.elevated
                        border.width: 1; border.color: sw.pal.borderSubtle
                        Row {
                            anchors.left: parent.left; anchors.leftMargin: 4
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 3
                            Rectangle { width: 6; height: 6; radius: 3; color: sw.pal.brand
                                        anchors.verticalCenter: parent.verticalCenter }
                            Rectangle { width: 30; height: 4; radius: 2; color: sw.pal.textSecondary
                                        anchors.verticalCenter: parent.verticalCenter }
                        }
                    }
                    Rectangle { width: parent.width * 0.85; height: 4; radius: 2; color: sw.pal.textPrimary }
                    Rectangle { width: parent.width * 0.6;  height: 4; radius: 2; color: sw.pal.textTertiary }
                }

                // Auto glyph badge
                AppIcon {
                    visible: modelData.auto
                    anchors.centerIn: parent
                    name: "monitor"
                    size: Theme.icon.md
                    color: Theme.color.textSecondary
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: SettingsService.themeMode = sw.modelData.id
                }
            }

            // Label + selected check
            Row {
                spacing: 4
                AppIcon {
                    visible: sw.selected
                    anchors.verticalCenter: parent.verticalCenter
                    name: "check"; size: Theme.icon.xs; color: Theme.color.brand
                }
                Text {
                    text: sw.modelData.name
                    color: sw.selected ? Theme.color.textPrimary : Theme.color.textSecondary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                    font.weight: sw.selected ? Theme.font.weightSemiBold : Theme.font.weightRegular
                }
            }
        }
    }
}
