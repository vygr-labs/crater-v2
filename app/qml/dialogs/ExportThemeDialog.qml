import QtQuick
import Crater

// Export confirmation dialog for .craterheme v2 bundles (ARCHITECTURE.md
// §10.3). Surfaces the bundle plan returned by
// ThemeService.resolveExportPlan() so the operator can see exactly what
// is about to be embedded BEFORE the file is written, and opt individual
// fonts out — most font files are not legally redistributable, and
// silent auto-bundling would put the operator's redistribution
// responsibility on autopilot.
//
// Opened from ThemesTab via:
//   AppState.openModal("exportTheme", {
//       themeId, themeName, themeKind, plan
//   })
ModalShell {
    id: root

    dialogWidth: 560
    dialogHeight: 540
    title: qsTr("Export theme")

    // ── Helpers ─────────────────────────────────────────────────────────
    readonly property var _plan:  AppState.modalProps.plan  || ({})
    readonly property var _media: _plan.media || []
    readonly property var _fonts: (_plan.fonts && _plan.fonts.bundleable) || []
    readonly property var _systemFonts: (_plan.fonts && _plan.fonts.systemOnly) || []
    readonly property string _themeName: AppState.modalProps.themeName || ""
    readonly property int _themeId: AppState.modalProps.themeId || 0

    // Set of excluded font families. Modeled as an object {fam: true} for
    // O(1) toggle. Default = empty = include everything.
    property var _excluded: ({})

    function _isFontIncluded(family) { return !root._excluded[family] }
    function _toggleFont(family) {
        const next = Object.assign({}, root._excluded)
        if (next[family]) delete next[family]
        else next[family] = true
        root._excluded = next
    }
    function _formatBytes(n) {
        if (n < 1024) return n + " B"
        if (n < 1024 * 1024) return (n / 1024).toFixed(1) + " KB"
        if (n < 1024 * 1024 * 1024) return (n / 1024 / 1024).toFixed(1) + " MB"
        return (n / 1024 / 1024 / 1024).toFixed(2) + " GB"
    }
    function _totalIncludedBytes() {
        let total = 0
        for (let i = 0; i < _media.length; ++i) total += _media[i].sizeBytes || 0
        for (let i = 0; i < _fonts.length; ++i) {
            const f = _fonts[i]
            if (root._isFontIncluded(f.family)) total += f.sizeBytes || 0
        }
        return total
    }
    function _excludedList() {
        return Object.keys(root._excluded)
    }

    // ── Content ─────────────────────────────────────────────────────────
    Item {
        anchors.fill: parent
        anchors.margins: Theme.space.lg

        // Header row: theme name + size summary
        Column {
            id: summary
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: Theme.space.xs

            Text {
                text: root._themeName
                color: Theme.color.textPrimary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize + 1
                font.weight: Theme.font.weightSemiBold
            }
            Text {
                text: qsTr("%1 media, %2 bundled font(s), %3 total")
                    .arg(root._media.length)
                    .arg(root._fonts.length)
                    .arg(root._formatBytes(root._totalIncludedBytes()))
                color: Theme.color.textSecondary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
            }
        }

        // License warning band — the load-bearing reason this dialog exists.
        Rectangle {
            id: warning
            anchors.top: summary.bottom
            anchors.topMargin: Theme.space.md
            anchors.left: parent.left
            anchors.right: parent.right
            visible: root._fonts.length > 0
            height: warningContent.implicitHeight + Theme.space.md * 2
            radius: Theme.radius.md
            color: Theme.color.overlay
            border.color: Theme.color.borderStrong
            border.width: 1

            Row {
                id: warningContent
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.space.md
                anchors.rightMargin: Theme.space.md
                spacing: Theme.space.sm

                AppIcon {
                    name: "alert-triangle"
                    color: Theme.color.textSecondary
                    size: Theme.icon.sm
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    width: parent.width - Theme.icon.sm - Theme.space.sm
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Font files may be licensed for use on your machine only. "
                               + "You are responsible for ensuring you have the right to "
                               + "redistribute any fonts you bundle.")
                    color: Theme.color.textSecondary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                    wrapMode: Text.WordWrap
                    lineHeight: 1.35
                }
            }
        }

        // Scrollable list of media + fonts.
        Flickable {
            id: scroll
            anchors.top: warning.visible ? warning.bottom : summary.bottom
            anchors.topMargin: Theme.space.md
            anchors.bottom: actions.top
            anchors.bottomMargin: Theme.space.md
            anchors.left: parent.left
            anchors.right: parent.right
            clip: true
            contentHeight: listCol.implicitHeight
            interactive: contentHeight > height

            Column {
                id: listCol
                width: scroll.width
                spacing: Theme.space.xs

                // ── Media section ────────────────────────────────────────
                Text {
                    visible: root._media.length > 0
                    text: qsTr("MEDIA")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.monoFamily
                    font.pixelSize: 11
                    font.weight: Theme.font.weightSemiBold
                    font.letterSpacing: 0.8
                }
                Repeater {
                    model: root._media
                    delegate: Rectangle {
                        width: parent ? parent.width : 0
                        height: 32
                        color: "transparent"
                        Row {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.space.sm

                            AppIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                name: modelData.type === "video"  ? "film"
                                    : modelData.type === "pdf"    ? "file-text"
                                                                  : "image"
                                color: Theme.color.textSecondary
                                size: Theme.icon.sm
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                width: scroll.width - Theme.icon.sm - 140
                                elide: Text.ElideRight
                                text: modelData.title || ""
                                color: Theme.color.textPrimary
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.bodySize
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: root._formatBytes(modelData.sizeBytes || 0)
                                color: Theme.color.textTertiary
                                font.family: Theme.font.monoFamily
                                font.pixelSize: Theme.font.smallSize
                            }
                        }
                    }
                }

                Item {
                    width: parent.width
                    height: Theme.space.sm
                    visible: root._media.length > 0
                }

                // ── Bundleable fonts ─────────────────────────────────────
                Text {
                    visible: root._fonts.length > 0
                    text: qsTr("FONTS TO BUNDLE")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.monoFamily
                    font.pixelSize: 11
                    font.weight: Theme.font.weightSemiBold
                    font.letterSpacing: 0.8
                }
                Repeater {
                    model: root._fonts
                    delegate: Rectangle {
                        width: parent ? parent.width : 0
                        height: 36
                        color: rowMa.containsMouse ? Theme.color.overlay : "transparent"

                        // Checkbox
                        Rectangle {
                            id: box
                            width: 18
                            height: 18
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            radius: 3
                            color: root._isFontIncluded(modelData.family)
                                ? Theme.color.brand
                                : "transparent"
                            border.color: root._isFontIncluded(modelData.family)
                                ? Theme.color.brand
                                : Theme.color.borderStrong
                            border.width: 1

                            AppIcon {
                                visible: root._isFontIncluded(modelData.family)
                                anchors.centerIn: parent
                                name: "check"
                                color: "#ffffff"   // check on the deep-teal box
                                size: 12
                            }
                        }

                        Text {
                            anchors.left: box.right
                            anchors.leftMargin: Theme.space.md
                            anchors.verticalCenter: parent.verticalCenter
                            width: scroll.width - 200
                            elide: Text.ElideRight
                            text: modelData.family
                            color: Theme.color.textPrimary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.bodySize
                        }
                        Text {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: root._formatBytes(modelData.sizeBytes || 0)
                            color: Theme.color.textTertiary
                            font.family: Theme.font.monoFamily
                            font.pixelSize: Theme.font.smallSize
                        }

                        MouseArea {
                            id: rowMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root._toggleFont(modelData.family)
                        }
                    }
                }

                Item {
                    width: parent.width
                    height: Theme.space.sm
                    visible: root._fonts.length > 0
                }

                // ── System-only fonts (informational) ────────────────────
                Text {
                    visible: root._systemFonts.length > 0
                    text: qsTr("SYSTEM FONTS (NOT BUNDLED)")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.monoFamily
                    font.pixelSize: 11
                    font.weight: Theme.font.weightSemiBold
                    font.letterSpacing: 0.8
                }
                // Annotation that answers the "why isn't my font here?"
                // question in-context, so the operator doesn't have to
                // hunt for the reason. Most system fonts (Calibri, Arial,
                // Helvetica, Apple SF Pro, etc.) are licensed for the
                // installed machine only — silently shipping them in a
                // theme export is the case ARCHITECTURE.md §10.3 was
                // designed to prevent.
                Text {
                    visible: root._systemFonts.length > 0
                    width: parent.width
                    text: qsTr("Most system fonts are licensed for this machine only and "
                               + "can't be redistributed. To bundle a font, install a "
                               + "redistributable file (e.g., from Google Fonts) via the "
                               + "Themes tab's Import font button.")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize - 1
                    wrapMode: Text.WordWrap
                    topPadding: 2
                    bottomPadding: 4
                    lineHeight: 1.35
                }
                Text {
                    visible: root._systemFonts.length > 0
                    width: parent.width
                    text: root._systemFonts.join(", ")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                    wrapMode: Text.WordWrap
                }
                Text {
                    visible: root._systemFonts.length > 0
                    width: parent.width
                    text: qsTr("These families must be installed on the importing machine for "
                               + "the theme to render correctly.")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize - 1
                    wrapMode: Text.WordWrap
                    topPadding: 2
                }
            }
        }

        // ── Action row ──────────────────────────────────────────────────
        Row {
            id: actions
            anchors.bottom: parent.bottom
            anchors.right: parent.right
            spacing: Theme.space.sm

            GhostButton {
                text: qsTr("Cancel")
                onClicked: AppState.closeModal()
            }
            PrimaryButton {
                variant: "brand"
                text: qsTr("Export…")
                iconName: "download"
                onClicked: {
                    const path = FileDialogService.chooseSaveFile(
                        qsTr("Export Theme"),
                        root._themeName + ".craterheme",
                        [qsTr("Crater Theme (*.craterheme)")])
                    if (!path || path.length === 0) return

                    const ok = ThemeService.exportTheme(
                        root._themeId, path, root._excludedList())
                    AppState.closeModal()
                    if (!ok) {
                        // Bubble the error back via ThemesTab — it owns the
                        // banner surface. We stash the message on AppState so
                        // the tab can pick it up on next focus.
                        AppState.lastThemeExportError =
                            ThemeService.lastExportError()
                                || qsTr("Export failed")
                    }
                }
            }
        }
    }
}
