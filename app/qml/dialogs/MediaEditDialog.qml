import QtQuick
import Crater

// "Edit media" modal — per-item image / video display options (MediaService
// V009). Bound to modalProps:
//   mediaId: the media row to edit.
//
// Controls:
//   • Crop — CroppableMediaPreview seeded with the item's saved crop. Drag to
//     frame a sub-region (arrows nudge, Esc resets). Video crops against its
//     first-frame poster; the rect applies to the live clip at render.
//   • Fit  — Default (follow the global default) / Contain / Cover / Stretch.
//   • Video only — Loop and Mute toggles.
//
// Save writes the whole set in one MediaService.setDisplayOptions() row update;
// the live projection picks the new framing up on the next go-live (edit-then-
// commit, per ARCHITECTURE.md §3), and the Preview/tile refresh immediately via
// the allMediaChanged re-emit.
ModalShell {
    id: root

    dialogWidth: 780
    dialogHeight: 660
    title: qsTr("Edit media")

    // Resolved once — the modal IS the editor, so the row can't change out
    // from under us while it's open.
    readonly property var  media: MediaService.byId(AppState.modalProps.mediaId || 0)
    readonly property bool _valid:  !!media && (media.id || 0) > 0
    readonly property bool _isVideo: _valid && media.type === "video"

    // Schedule-shape item the cropper understands (kind / mediaPath / mediaId).
    readonly property var _cropItem: _valid
        ? ({ kind: media.type, mediaPath: media.path,
             mediaId: media.id, pageCount: media.pageCount })
        : null

    // Editable working copy — committed only on Save.
    property string fitMode:   _valid ? media.fitMode   : "default"
    property bool   loopVideo: _valid ? media.loopVideo : true
    property bool   muteAudio: _valid ? media.muted     : false

    Item {
        anchors.fill: parent
        anchors.margins: Theme.space.lg

        // ── Footer (declared first so controls can anchor above it) ──────
        Row {
            id: footer
            anchors.bottom: parent.bottom
            anchors.right: parent.right
            spacing: Theme.space.sm

            GhostButton {
                text: qsTr("Cancel")
                onClicked: AppState.closeModal()
            }
            PrimaryButton {
                variant: "brand"
                text: qsTr("Save")
                enabled: root._valid
                onClicked: root._save()
            }
        }

        // ── Controls strip ───────────────────────────────────────────────
        Column {
            id: controls
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: footer.top
            anchors.bottomMargin: Theme.space.lg
            spacing: Theme.space.md

            // Fit mode
            Item {
                width: parent.width
                height: 40
                Text {
                    id: fitLabel
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Fit")
                    color: Theme.color.textPrimary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize
                    font.weight: Theme.font.weightMedium
                }
                SegmentedControl {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 360
                    options: [
                        { value: "default", label: qsTr("Default") },
                        { value: "contain", label: qsTr("Contain") },
                        { value: "cover",   label: qsTr("Cover") },
                        { value: "stretch", label: qsTr("Stretch") }
                    ]
                    current: root.fitMode
                    onChanged: function(v) { root.fitMode = v }
                }
            }

            // Fit description — reflects the chosen mode.
            Text {
                width: parent.width
                text: root.fitMode === "cover"   ? qsTr("Fill the screen; edges outside the frame are cropped.")
                    : root.fitMode === "stretch" ? qsTr("Stretch to fill; the source aspect ratio is ignored.")
                    : root.fitMode === "contain" ? qsTr("Letterbox; the whole frame stays visible.")
                    : qsTr("Follow the app-wide default (Settings ▸ Media).")
                color: Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                wrapMode: Text.Wrap
            }

            // Video-only: loop + mute
            Item {
                width: parent.width
                height: 32
                visible: root._isVideo
                Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Loop video")
                    color: Theme.color.textPrimary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize
                    font.weight: Theme.font.weightMedium
                }
                ToggleSwitch {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    value: root.loopVideo
                    onToggled: root.loopVideo = !root.loopVideo
                }
            }
            Item {
                width: parent.width
                height: 32
                visible: root._isVideo
                Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Mute audio")
                    color: Theme.color.textPrimary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize
                    font.weight: Theme.font.weightMedium
                }
                ToggleSwitch {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    value: root.muteAudio
                    onToggled: root.muteAudio = !root.muteAudio
                }
            }

            // Crop hint + reset
            Item {
                width: parent.width
                height: 20
                Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: root._isVideo
                          ? qsTr("Drag on the poster to crop · Esc resets")
                          : qsTr("Drag to crop · arrows nudge · Esc resets")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                }
                Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Reset crop")
                    color: resetMa.containsMouse ? Theme.color.brand : Theme.color.textSecondary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                    font.weight: Theme.font.weightMedium
                    MouseArea {
                        id: resetMa
                        anchors.fill: parent
                        anchors.margins: -6
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: cropper.resetCrop()
                    }
                }
            }
        }

        // ── Crop surface (fills remaining space above the controls) ──────
        Rectangle {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: controls.top
            anchors.bottomMargin: Theme.space.md
            color: "#000000"
            border.color: Theme.color.borderStrong
            border.width: 1
            clip: true

            CroppableMediaPreview {
                id: cropper
                anchors.fill: parent
                anchors.margins: 1
                item: root._cropItem
                pageIndex: 0
                // Video/image are single-frame here — lock the crop to the
                // 16:9 projection canvas by default so the framing matches the
                // output; Shift-drag still frees the aspect.
                aspectLockEnabled: true
                aspectLockW: 16
                aspectLockH: 9
                initialCrop: root._valid ? root.media.cropRect : Qt.rect(0, 0, 1, 1)
            }

            // Empty-state when the row didn't resolve.
            Text {
                anchors.centerIn: parent
                visible: !root._valid
                text: qsTr("Media not found")
                color: Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize
            }
        }
    }

    function _save() {
        if (!_valid) { AppState.closeModal(); return }
        MediaService.setDisplayOptions(media.id, fitMode, cropper.cropRect,
                                       loopVideo, muteAudio)
        AppState.closeModal()
    }
}
