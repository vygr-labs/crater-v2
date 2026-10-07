import QtQuick
import QtQuick.Layouts

// Media — global default presentation for projected image / video items.
// Per-item overrides (fit / crop / loop / mute) live on each media item and
// are edited from the Media tab (right-click ▸ Edit…, or ▸ Fit); this pane
// only sets the fallback used when an item's fit is left on "Default".
Item {
    id: root

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

            SettingRow {
                title: qsTr("Default fit")
                description: qsTr("How images and videos frame on the projection output")
                SegmentedControl {
                    width: 280
                    height: 34
                    options: [
                        { value: "contain", label: qsTr("Contain") },
                        { value: "cover",   label: qsTr("Cover") },
                        { value: "stretch", label: qsTr("Stretch") }
                    ]
                    current: SettingsService.mediaDefaultFit
                    onChanged: function(v) { SettingsService.mediaDefaultFit = v }
                }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            // Description of the chosen default — mirrors the edit-modal copy.
            Item { Layout.fillWidth: true; Layout.preferredHeight: 44
                Text {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: SettingsService.mediaDefaultFit === "cover"
                              ? qsTr("Cover: fill the screen. Edges outside the frame are cropped.")
                        : SettingsService.mediaDefaultFit === "stretch"
                              ? qsTr("Stretch: fill exactly. The source aspect ratio is ignored.")
                              : qsTr("Contain: letterbox. The whole frame stays visible.")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                    wrapMode: Text.Wrap
                }
            }

            // ── PLAYBACK ─────────────────────────────────────────────────
            // Same value as the Live pane's transport fader (persisted in
            // SettingsService.mediaVolume, applied by MediaPlaybackService).
            SettingsSectionHeader { title: qsTr("Playback") }

            SettingRow {
                title: qsTr("Video volume")
                description: qsTr("Sound level of videos on the projection output, in percent")
                SimpleSlider {
                    width: 280
                    min: 0
                    max: 100
                    step: 5
                    value: Math.round(SettingsService.mediaVolume * 100)
                    onLive: function(v) { SettingsService.mediaVolume = v / 100 }
                }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            // ── PER-ITEM ─────────────────────────────────────────────────
            SettingsSectionHeader { title: qsTr("Per-item overrides") }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 64
                Text {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Any image or video can override this from the Media tab. Right-click ▸ Edit… to set its fit, crop a region, and (for videos) loop or mute. Items left on “Default” follow the setting above.")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                    wrapMode: Text.Wrap
                }
            }

            Item { Layout.fillWidth: true; Layout.preferredHeight: Theme.space.xl }
        }
    }
}
