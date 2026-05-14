import QtQuick
import Crater

// Themes tab — visual presets for projection text rendering.
// Backed by ThemeService.allThemes (QList<Theme> value-types); each tile
// previews the theme's node graph via ThemePreview.
//
// Tokens shape (v2): see qt/core/src/db/migrations/app/V003__theme_nodes.sql.
Item {
    id: root

    // ── Header row: New / Import buttons ────────────────────────────────
    Row {
        id: header
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: Theme.space.lg
        spacing: Theme.space.sm
        z: 1

        GhostButton {
            text: qsTr("Import theme")
            iconName: "upload"
            onClicked: {
                const path = FileDialogService.chooseOpenFile(
                    qsTr("Import Theme"),
                    [qsTr("Crater Theme (*.craterheme)"), qsTr("All Files (*.*)")])
                if (path && path.length > 0) {
                    const id = ThemeService.importThemeFile(path)
                    if (id === 0) {
                        // Surface the error inline via the toast layer once that lands.
                        console.warn("Import failed:", ThemeService.lastImportError())
                    }
                }
            }
        }
        GhostButton {
            text: qsTr("New theme")
            iconName: "plus"
            onClicked: AppState.openThemeEditor(-1, "song")
        }
    }

    EmptyState {
        anchors.fill: parent
        visible: ThemeService.allThemes.length === 0
        iconName: "palette"
        title: qsTr("No themes yet")
        body: qsTr("Create a custom theme or import one from a file")
    }

    GridView {
        id: grid
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: Theme.space.lg
        anchors.rightMargin: Theme.space.lg
        anchors.bottomMargin: Theme.space.lg
        anchors.topMargin: Theme.space.sm
        visible: ThemeService.allThemes.length > 0
        model: ThemeService.allThemes
        cellWidth: 220
        cellHeight: 148
        clip: true
        cacheBuffer: 400

        delegate: Item {
            id: tileRoot
            width: grid.cellWidth - 10
            height: grid.cellHeight - 10

            Rectangle {
                id: tile
                anchors.fill: parent
                radius: Theme.radius.lg
                color: Theme.color.canvas
                border.color: themeMa.containsMouse ? Theme.color.brand : Theme.color.borderStrong
                border.width: 2
                clip: true

                Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }

                // Live theme preview rendered via the same NodeRenderer the
                // projection window uses — what you see is what you'll get.
                // autoPlayVideos off because dozens of preview tiles each
                // running a video would melt the GPU.
                ThemePreview {
                    anchors.fill: parent
                    anchors.margins: 4
                    theme: modelData
                    autoPlayVideos: false
                }

                // Theme name + kind in the corner — translucent black
                // backdrop so it stays readable over any theme background.
                Rectangle {
                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                    anchors.margins: 8
                    width: nameLabel.implicitWidth + Theme.space.md * 2
                    height: 22
                    radius: 3
                    color: "#000000A0"

                    Text {
                        id: nameLabel
                        anchors.centerIn: parent
                        text: modelData.name + " · " + (modelData.kind || "")
                        color: "#ffffff"
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.smallSize
                        font.weight: Theme.font.weightSemiBold
                    }
                }

                // "Built-in" indicator chip — top right.
                Rectangle {
                    visible: modelData.isBuiltin === true
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 8
                    width: builtinLabel.implicitWidth + Theme.space.sm * 2
                    height: 16
                    radius: 2
                    color: "#000000A0"

                    Text {
                        id: builtinLabel
                        anchors.centerIn: parent
                        text: qsTr("PRESET")
                        color: "#dddddd"
                        font.family: Theme.font.monoFamily
                        font.pixelSize: 9
                        font.weight: Theme.font.weightSemiBold
                        font.letterSpacing: 0.8
                    }
                }

                RightClickArea {
                    id: themeMa
                    anchors.fill: parent
                    onDoubleClicked: AppState.openThemeEditor(modelData.id, modelData.kind)
                    menuItems: [
                        { label: qsTr("Edit"),       iconName: "edit",
                          action: () => AppState.openThemeEditor(modelData.id, modelData.kind) },
                        { label: qsTr("Duplicate"),  iconName: "copy",
                          action: () => ThemeService.duplicateTheme(modelData.id,
                                           qsTr("%1 Copy").arg(modelData.name)) },
                        { label: qsTr("Export…"),    iconName: "download",
                          action: () => {
                              const path = FileDialogService.chooseSaveFile(
                                  qsTr("Export Theme"),
                                  modelData.name + ".craterheme",
                                  [qsTr("Crater Theme (*.craterheme)")])
                              if (path && path.length > 0)
                                  ThemeService.exportTheme(modelData.id, path)
                          } },
                        { label: qsTr("Set as default for %1").arg(modelData.kind),
                          iconName: "star",
                          action: () => ThemeService.setDefaultFor(modelData.kind, modelData.id) },
                        { separator: true },
                        { label: qsTr("Delete"),     iconName: "trash",
                          destructive: true,
                          enabled: !modelData.isBuiltin,
                          action: () => ThemeService.destroy(modelData.id) }
                    ]
                }
            }
        }
    }
}
