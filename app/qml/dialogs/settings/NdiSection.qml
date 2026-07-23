import QtQuick
import QtQuick.Layouts

// NDI — Network Device Interface broadcast output.
// Wired to NdiService: dynamic loading at startup, real send pipeline.
// Quality + audio knobs stay Soon for v1 — quality is fixed at the
// projection window's native resolution and BGRA / 29.97 fps; audio
// is a Phase-3 follow-up (see NdiService.h header comment).
Item {
    id: root

    property string quality:      "Native"
    property bool   includeAudio: false

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

            // ── Status banner ────────────────────────────────────────────
            // Three states drive the banner colour:
            //   • not available (runtime missing) → live-red wash
            //   • available but not sending       → subtle brand wash
            //   • sending                         → bright brand
            // Caption text comes verbatim from NdiService.diagnostic so we
            // never invent a status string that diverges from runtime state.
            // Tally pills (PGM / PVW) sit on the right edge while broadcasting
            // and light up when receivers signal program / preview state.
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 40
                radius: 0
                color: !NdiService.available    ? Theme.color.liveSubtle
                     : NdiService.sending       ? Theme.color.brand
                                                : Theme.color.brandSubtle
                border.color: !NdiService.available ? Theme.color.live
                            : NdiService.sending    ? Theme.color.brand
                                                    : Theme.color.brand
                border.width: 1

                // Left cluster — icon + diagnostic prose.
                Row {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.right: tallyCluster.left
                    anchors.leftMargin: Theme.space.md
                    anchors.rightMargin: Theme.space.sm
                    spacing: Theme.space.sm

                    AppIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: !NdiService.available ? "alert-triangle"
                            : NdiService.sending    ? "radio"
                                                    : "info"
                        // When sending, the band fills with the deep brand teal,
                        // so the ink must be contrast-aware (white on a deep fill,
                        // brandInk only on a bright one) — same rule as PrimaryButton.
                        color: !NdiService.available ? Theme.color.live
                             : NdiService.sending    ? (Theme.color.brand.hslLightness > 0.45 ? Theme.color.brandInk : "#ffffff")
                                                     : Theme.color.brand
                        size: Theme.icon.sm
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: NdiService.diagnostic
                        color: NdiService.sending ? (Theme.color.brand.hslLightness > 0.45 ? Theme.color.brandInk : "#ffffff")
                                                  : Theme.color.textPrimary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                        font.weight: NdiService.sending ? Theme.font.weightMedium
                                                        : Theme.font.weightRegular
                        elide: Text.ElideRight
                        width: Math.max(0, parent.width - parent.spacing - Theme.icon.sm)
                    }
                }

                // Right cluster — tally pills. PGM = program (on-air, live red);
                // PVW = preview (champagne). Visible only while broadcasting.
                // When the corresponding tally bit is true the pill fills;
                // otherwise it sits as a hollow chip so the operator can see
                // where the indicator WOULD light up.
                Row {
                    id: tallyCluster
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.rightMargin: Theme.space.md
                    spacing: Theme.space.xs
                    visible: NdiService.sending

                    Rectangle {
                        width: pgmText.implicitWidth + Theme.space.sm * 2
                        height: 20
                        radius: 0
                        color: NdiService.onProgram ? Theme.color.live : "transparent"
                        border.color: NdiService.onProgram ? Theme.color.live
                                                           : Theme.color.borderSubtle
                        border.width: 1

                        Text {
                            id: pgmText
                            anchors.centerIn: parent
                            text: qsTr("PGM")
                            color: NdiService.onProgram ? "#ffffff" : Theme.color.textTertiary
                            font.family: Theme.font.monoFamily
                            font.pixelSize: 10
                            font.weight: Theme.font.weightSemiBold
                            font.letterSpacing: 0.8
                        }
                    }

                    Rectangle {
                        width: pvwText.implicitWidth + Theme.space.sm * 2
                        height: 20
                        radius: 0
                        color: NdiService.onPreview ? Theme.color.preview : "transparent"
                        border.color: NdiService.onPreview ? Theme.color.preview
                                                           : Theme.color.borderSubtle
                        border.width: 1

                        Text {
                            id: pvwText
                            anchors.centerIn: parent
                            text: qsTr("PVW")
                            color: NdiService.onPreview ? Theme.color.previewSubtle
                                                        : Theme.color.textTertiary
                            font.family: Theme.font.monoFamily
                            font.pixelSize: 10
                            font.weight: Theme.font.weightSemiBold
                            font.letterSpacing: 0.8
                        }
                    }
                }
            }

            // ── BROADCAST ────────────────────────────────────────────────
            SettingsSectionHeader { title: qsTr("Broadcast") }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("Enable NDI output"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Broadcast projection as an NDI source on the local network"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
                }
                ToggleSwitch {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    value: NdiService.sending
                    enabled: NdiService.available
                    opacity: NdiService.available ? 1.0 : 0.45
                    onToggled: {
                        if (NdiService.sending) NdiService.stop()
                        else                    NdiService.start()
                    }
                }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                       text: qsTr("Stream name"); color: Theme.color.textPrimary
                       font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize
                       font.weight: Theme.font.weightMedium }
                Rectangle {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 220; height: 30
                    radius: 0
                    color: Theme.color.canvas
                    border.color: streamInput.activeFocus ? Theme.color.brand : Theme.color.borderStrong
                    border.width: 1
                    opacity: NdiService.available ? 1.0 : 0.45

                    TextInput {
                        id: streamInput
                        anchors.fill: parent
                        anchors.leftMargin: Theme.space.md
                        anchors.rightMargin: Theme.space.md
                        verticalAlignment: TextInput.AlignVCenter
                        // One-way bind on focus so the operator's edit
                        // doesn't fight a model write mid-keystroke.
                        // onEditingFinished pushes the final value.
                        text: NdiService.streamName
                        color: Theme.color.textPrimary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                        enabled: NdiService.available
                        selectByMouse: true
                        onEditingFinished: {
                            if (text !== NdiService.streamName) {
                                NdiService.streamName = text
                            }
                        }
                    }
                }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("Quality"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Resolution + format of the broadcast stream"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
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
                    SelectChip {
                        anchors.verticalCenter: parent.verticalCenter
                        label: qsTr("Native BGRA")
                        opacity: 0.45
                        enabled: false
                        radius: 0
                    }
                }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.color.borderSubtle }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                    Text { text: qsTr("Include audio"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium }
                    Text { text: qsTr("Tap the projection's audio output and broadcast it"); color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize }
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
                        value: root.includeAudio
                        opacity: 0.45
                        enabled: false
                        onToggled: { }
                    }
                }
            }

            // ── RENDERING ────────────────────────────────────────────────
            // Single vs dual scene-graph pipeline. Single (default) is the
            // lower-cost path: NDI grabs from the projection window's
            // render and mirrors whatever the operator is projecting. Dual
            // spins up a dedicated NdiCanvas with its own ProjectionScene
            // so NDI can render a different theme — costs one extra
            // scene-graph evaluation per frame while broadcasting, which
            // is negligible for text+image themes and notable for video
            // backgrounds (decode runs twice).
            //
            // Dual mode also collapses the projection window's "stay
            // alive offscreen during NDI broadcast" trick: NdiCanvas owns
            // the always-alive role, projection can fully Hide whenever
            // the operator closes it.
            SettingsSectionHeader { title: qsTr("Rendering") }

            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column {
                    anchors.left: parent.left
                    anchors.right: dualToggle.left
                    anchors.rightMargin: Theme.space.md
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    ElidedText { text: qsTr("Dual output mode"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium
                                 width: parent.width }
                    ElidedText { text: qsTr("Render NDI with its own theme assignment. Costs slightly more GPU while broadcasting.")
                                 color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize
                                 width: parent.width }
                }
                ToggleSwitch {
                    id: dualToggle
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    value: SettingsService.outputMode === "dual"
                    onToggled: SettingsService.outputMode =
                        (SettingsService.outputMode === "dual" ? "single" : "dual")
                }
            }

            // Headless NDI renderer — the production-default path. Renders the
            // NDI scene directly into a GPU texture (QQuickRenderControl + QRhi)
            // and async-reads back to NDI at 60 Hz adaptive. Flipping this off
            // falls back to the legacy `grabToImage` path on the NdiCanvas Item;
            // intended only if a particular GPU misbehaves with QRhi readback.
            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column {
                    anchors.left: parent.left
                    anchors.right: headlessToggle.left
                    anchors.rightMargin: Theme.space.md
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    ElidedText { text: qsTr("Headless renderer"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium
                                 width: parent.width }
                    ElidedText { text: qsTr("Capture frames via GPU texture readback. Smoother and lower-CPU than the legacy path.")
                                 color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize
                                 width: parent.width }
                }
                ToggleSwitch {
                    id: headlessToggle
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    value: SettingsService.useHeadlessNdi
                    onToggled: SettingsService.useHeadlessNdi = !SettingsService.useHeadlessNdi
                }
            }

            // On-demand rendering — renders an NDI frame only when the scene
            // actually changes (text advance, transition), idling between
            // updates and re-sending the last frame at a low keepalive rate,
            // capped at 30 Hz. Large CPU saver for mostly-static broadcasts
            // (e.g. a dual-output lower-third) on weak hardware. Headless path
            // only — the legacy grabToImage fallback ignores it — so it's
            // disabled when the headless renderer is off. Applies on the next
            // broadcast start, matching the headless toggle's lifecycle.
            Item { Layout.fillWidth: true; Layout.preferredHeight: 56
                Column {
                    anchors.left: parent.left
                    anchors.right: onDemandToggle.left
                    anchors.rightMargin: Theme.space.md
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    ElidedText { text: qsTr("On-demand rendering (low CPU)"); color: Theme.color.textPrimary; font.family: Theme.font.family; font.pixelSize: Theme.font.bodySize; font.weight: Theme.font.weightMedium
                                 width: parent.width }
                    ElidedText { text: qsTr("Only render when the scene changes; idle between updates. Caps at 30 Hz. Best for static lower-thirds. Applies on next broadcast start.")
                                 color: Theme.color.textTertiary; font.family: Theme.font.family; font.pixelSize: Theme.font.smallSize
                                 width: parent.width }
                }
                ToggleSwitch {
                    id: onDemandToggle
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    enabled: SettingsService.useHeadlessNdi
                    opacity: SettingsService.useHeadlessNdi ? 1.0 : 0.45
                    value: SettingsService.ndiOnDemand
                    onToggled: SettingsService.ndiOnDemand = !SettingsService.ndiOnDemand
                }
            }

            Item { Layout.fillWidth: true; Layout.preferredHeight: Theme.space.xl }
        }
    }
}
