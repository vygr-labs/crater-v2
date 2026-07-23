import QtQuick
import QtQuick.Layouts

// Song — author/CCLI display, auto-advance, default theme.
Item {
    id: root

    // Local placeholder for the still-Soon auto-advance row (wired next).
    property bool autoAdvance: false

    // Song-kind themes for the Default-theme picker, rebuilt when the theme
    // list or the kv-backed per-kind default changes. The picker is a second
    // entry point to the SAME default ThemesTab's "Set as default" drives, so
    // it reads/writes ThemeService.defaultFor/setDefaultFor("song") — NOT a
    // SettingsService key, which would be a competing source of truth. The
    // default is applied at render time by AppState.resolveItemTheme, so a
    // change re-renders live projected songs immediately.
    property int _themeRevision: 0
    Connections {
        target: ThemeService
        function onAllThemesChanged() { root._themeRevision++ }
        function onDefaultsChanged()  { root._themeRevision++ }
    }
    readonly property var _songThemeOptions: {
        root._themeRevision   // dependency
        const all = ThemeService.allThemes || []
        let out = []
        for (let i = 0; i < all.length; i++) {
            const t = all[i]
            if (t && t.kind === "song") out.push({ label: t.name, value: String(t.id) })
        }
        return out
    }
    readonly property string _songDefaultName: {
        root._themeRevision   // dependency
        const t = ThemeService.defaultFor("song")
        return (t && t.id > 0) ? t.name : ""
    }

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

            // ── DISPLAY ──────────────────────────────────────────────────
            SettingsSectionHeader { title: qsTr("Display"); first: true }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                       text: qsTr("Show author"); color: Theme.color.textPrimary
                       font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize
                       font.weight: Theme.font.weightMedium }
                ToggleSwitch { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    value: SettingsService.showSongAuthor
                    onToggled: SettingsService.showSongAuthor = !SettingsService.showSongAuthor }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("Show CCLI number"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Display copyright tag below song title"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
                }
                ToggleSwitch { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    value: SettingsService.showSongCcli
                    onToggled: SettingsService.showSongCcli = !SettingsService.showSongCcli }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("Default theme"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Used for songs that don't carry their own theme"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
                }
                Combobox {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 200
                    // Search only kicks in for long theme lists; a handful of
                    // themes reads better as a plain list.
                    searchable: root._songThemeOptions.length > 8
                    options: root._songThemeOptions
                    // Combobox shows `value` verbatim and hands the picked
                    // option's `value` to onValueSelected — so display the
                    // theme name, resolve the id string on select.
                    value: root._songDefaultName
                    placeholder: qsTr("Select theme")
                    onValueSelected: function(v) {
                        const id = parseInt(v, 10)
                        ThemeService.setDefaultFor("song", isNaN(id) ? 0 : id)
                    }
                }
            }

            // ── PLAYBACK ─────────────────────────────────────────────────
            SettingsSectionHeader { title: qsTr("Playback") }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("Auto-advance slides"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Move to next slide automatically after a delay"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
                }
                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.space.md

                    Badge {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Soon")
                        background: Theme.color.overlay
                        foreground: Theme.color.textTertiary
                    }
                    ToggleSwitch {
                        anchors.verticalCenter: parent.verticalCenter
                        value: root.autoAdvance
                        opacity: 0.45
                        enabled: false
                        onToggled: { }
                    }
                }
            }

            Item { Layout.fillWidth: true; Layout.preferredHeight: Theme.space.xl }
        }
    }
}
