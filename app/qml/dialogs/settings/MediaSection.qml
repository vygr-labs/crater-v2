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

            Item { Layout.fillWidth: true; Layout.preferredHeight: 68
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("Default fit"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("How images and videos frame on the projection output"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
                }
                SegmentedControl {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
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
                              ? qsTr("Cover — fill the screen; edges outside the frame are cropped.")
                        : SettingsService.mediaDefaultFit === "stretch"
                              ? qsTr("Stretch — fill exactly; the source aspect ratio is ignored.")
                              : qsTr("Contain — letterbox; the whole frame stays visible.")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                    wrapMode: Text.Wrap
                }
            }

            // ── PER-ITEM ─────────────────────────────────────────────────
            SettingsSectionHeader { title: qsTr("Per-item overrides") }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 64
                Text {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Any image or video can override this from the Media tab — right-click ▸ Edit… to set its fit, crop a region, and (for videos) loop or mute. Items left on “Default” follow the setting above.")
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
