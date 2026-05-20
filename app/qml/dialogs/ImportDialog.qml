import QtQuick

// EasyWorship song-library import dialog.
//
// Walks the operator through a small state machine, bound to the
// EasyWorshipImporter singleton:
//
//   pick      -> choose Songs.db + SongWords.db via the native file picker
//   scanning  -> EasyWorshipImporter.analyze() runs on a worker thread
//   confirm   -> show the song count + duplicate count; pick a duplicate policy
//   importing -> EasyWorshipImporter.run() with a live progress bar
//   done      -> import summary    |    error -> failure reason
//
// Opened via AppState.openModal("import"); ModalLayer hosts the Loader.
ModalShell {
    id: root

    dialogWidth: 560
    dialogHeight: 460
    title: qsTr("Import Songs from EasyWorship")

    // ── State machine ───────────────────────────────────────────────────
    property string phase: "pick"   // pick | scanning | confirm | importing | done | error
    property var    dbFiles: []
    property int    totalSongs: 0
    property int    duplicateCount: 0
    property bool   skipDuplicates: true
    property int    importedCount: 0
    property int    skippedCount: 0
    property int    progressPercent: 0
    property string progressStage: ""
    property string errorText: ""

    // How many songs an import would actually add, given the current policy.
    readonly property int newSongCount:
        root.skipDuplicates ? (root.totalSongs - root.duplicateCount) : root.totalSongs

    // EasyWorshipImporter delivers every result asynchronously via signals —
    // analyze()/run() return immediately and do their work on a worker thread.
    Connections {
        target: EasyWorshipImporter
        function onAnalyzed(songCount, duplicates) {
            root.totalSongs = songCount
            root.duplicateCount = duplicates
            root.skipDuplicates = duplicates > 0   // default to skipping when overlap exists
            root.phase = "confirm"
        }
        function onProgress(percent, stage) {
            root.progressPercent = percent
            root.progressStage = stage
        }
        function onCompleted(imported, skipped) {
            root.importedCount = imported
            root.skippedCount = skipped
            root.phase = "done"
        }
        function onFailed(reason) {
            root.errorText = reason
            root.phase = "error"
        }
    }

    function pickFiles() {
        var files = FileDialogService.chooseOpenFiles(
            qsTr("Select EasyWorship Songs.db and SongWords.db"),
            [qsTr("EasyWorship database (*.db)"), qsTr("All files (*)")])
        if (!files || files.length === 0)
            return                                  // operator cancelled the picker
        root.dbFiles = files
        root.phase = "scanning"
        EasyWorshipImporter.analyze(files)
    }

    function startImport() {
        root.progressPercent = 0
        root.progressStage = qsTr("Starting...")
        root.phase = "importing"
        EasyWorshipImporter.run(root.dbFiles, root.skipDuplicates)
    }

    function resetToStart() {
        root.phase = "pick"
        root.dbFiles = []
        root.errorText = ""
    }

    // ── Content ─────────────────────────────────────────────────────────
    Item {
        anchors.fill: parent
        anchors.margins: Theme.space.lg

        // ── Phase: pick ─────────────────────────────────────────────────
        Item {
            anchors.fill: parent
            visible: root.phase === "pick"

            Column {
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                spacing: Theme.space.md

                AppIcon {
                    name: "download"
                    color: Theme.color.brand
                    size: 40
                }
                Text {
                    width: parent.width
                    text: qsTr("Bring your songs across from EasyWorship")
                    color: Theme.color.textTitle
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize + 3
                    font.weight: Theme.font.weightSemiBold
                    wrapMode: Text.WordWrap
                }
                Text {
                    width: parent.width
                    text: qsTr("Crater imports song libraries from EasyWorship 6 and 7. Those versions keep songs in a Data folder as two files. Choose both Songs.db and SongWords.db to continue.")
                    color: Theme.color.textSecondary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize
                    wrapMode: Text.WordWrap
                    lineHeight: 1.4
                }
                Rectangle {
                    width: parent.width
                    implicitHeight: hintCol.implicitHeight + Theme.space.md * 2
                    color: Theme.color.bgContent
                    border.color: Theme.color.borderSubtle
                    border.width: 1
                    radius: 0

                    Column {
                        id: hintCol
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.margins: Theme.space.md
                        spacing: Theme.space.sm

                        // EasyWorship installs into the *Public* Documents
                        // folder — a shared location separate from each
                        // user's personal Documents — so spell that out.
                        Text {
                            width: parent.width
                            text: qsTr("Usually found in the Public Documents folder (shared by all users, not your personal Documents):")
                            color: Theme.color.textTertiary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.smallSize
                            wrapMode: Text.WordWrap
                            lineHeight: 1.4
                        }
                        Text {
                            width: parent.width
                            text: "C:\\Users\\Public\\Documents\\Softouch\\EasyWorship\\Default\\Databases\\Data"
                            color: Theme.color.textSecondary
                            font.family: Theme.font.monoFamily
                            font.pixelSize: Theme.font.smallSize
                            wrapMode: Text.WrapAnywhere
                            lineHeight: 1.4
                        }
                        Text {
                            width: parent.width
                            text: qsTr("Tip: paste this path into the file picker's address bar to jump straight there.")
                            color: Theme.color.textTertiary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.smallSize
                            wrapMode: Text.WordWrap
                            lineHeight: 1.4
                        }
                    }
                }
            }

            Row {
                anchors.bottom: parent.bottom
                anchors.right: parent.right
                spacing: Theme.space.sm

                GhostButton {
                    text: qsTr("Cancel")
                    onClicked: AppState.closeModal()
                }
                PrimaryButton {
                    variant: "brand"
                    inkColor: "#ffffff"
                    iconName: "download"
                    text: qsTr("Choose files...")
                    onClicked: root.pickFiles()
                }
            }
        }

        // ── Phase: scanning ─────────────────────────────────────────────
        Item {
            anchors.fill: parent
            visible: root.phase === "scanning"

            Text {
                anchors.centerIn: parent
                text: qsTr("Scanning your EasyWorship library...")
                color: Theme.color.textSecondary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize
            }
        }

        // ── Phase: confirm ──────────────────────────────────────────────
        Item {
            anchors.fill: parent
            visible: root.phase === "confirm"

            Column {
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                spacing: Theme.space.md

                Text {
                    width: parent.width
                    text: root.totalSongs === 1
                          ? qsTr("Found 1 song in your EasyWorship library.")
                          : qsTr("Found %1 songs in your EasyWorship library.").arg(root.totalSongs)
                    color: Theme.color.textTitle
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize + 3
                    font.weight: Theme.font.weightSemiBold
                    wrapMode: Text.WordWrap
                }

                // Duplicate-policy panel — shown only when overlap exists.
                Rectangle {
                    width: parent.width
                    visible: root.duplicateCount > 0
                    implicitHeight: dupCol.implicitHeight + Theme.space.md * 2
                    color: Theme.color.bgContent
                    border.color: Theme.color.borderSubtle
                    border.width: 1
                    radius: Theme.radius.md

                    Column {
                        id: dupCol
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.margins: Theme.space.md
                        spacing: Theme.space.md

                        Text {
                            width: parent.width
                            text: root.duplicateCount === 1
                                  ? qsTr("1 of these songs has the same title and author as a song already in your library.")
                                  : qsTr("%1 of these songs have the same title and author as songs already in your library.").arg(root.duplicateCount)
                            color: Theme.color.textSecondary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.bodySize
                            wrapMode: Text.WordWrap
                            lineHeight: 1.4
                        }

                        Row {
                            spacing: Theme.space.md

                            ToggleSwitch {
                                id: skipToggle
                                anchors.verticalCenter: parent.verticalCenter
                                value: root.skipDuplicates
                                onToggled: root.skipDuplicates = !root.skipDuplicates
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.skipDuplicates
                                      ? qsTr("Skip duplicates")
                                      : qsTr("Import duplicates anyway")
                                color: Theme.color.textPrimary
                                font.family: Theme.font.family
                                font.pixelSize: Theme.font.bodySize
                                font.weight: Theme.font.weightMedium
                            }
                        }
                    }
                }

                Text {
                    width: parent.width
                    text: root.newSongCount === 1
                          ? qsTr("1 song will be imported.")
                          : qsTr("%1 songs will be imported.").arg(root.newSongCount)
                    color: Theme.color.textSecondary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize
                    wrapMode: Text.WordWrap
                }
            }

            Row {
                anchors.bottom: parent.bottom
                anchors.right: parent.right
                spacing: Theme.space.sm

                GhostButton {
                    text: qsTr("Back")
                    onClicked: root.resetToStart()
                }
                PrimaryButton {
                    variant: "brand"
                    inkColor: "#ffffff"
                    iconName: "download"
                    text: qsTr("Import")
                    enabled: root.newSongCount > 0
                    onClicked: root.startImport()
                }
            }
        }

        // ── Phase: importing ────────────────────────────────────────────
        Item {
            anchors.fill: parent
            visible: root.phase === "importing"

            Column {
                anchors.centerIn: parent
                width: parent.width
                spacing: Theme.space.md

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: qsTr("Importing songs...")
                    color: Theme.color.textTitle
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize + 3
                    font.weight: Theme.font.weightSemiBold
                }

                // Progress track + fill. Squared corners to match app chrome.
                Rectangle {
                    width: parent.width
                    height: 10
                    radius: 0
                    color: Theme.color.bgContent
                    border.color: Theme.color.borderSubtle
                    border.width: 1

                    Rectangle {
                        height: parent.height
                        width: parent.width
                              * Math.max(0, Math.min(100, root.progressPercent)) / 100
                        color: Theme.color.brand
                        Behavior on width { NumberAnimation { duration: Theme.motion.instant } }
                    }
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: root.progressPercent + "%   ·   " + root.progressStage
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                }
            }
        }

        // ── Phase: done ─────────────────────────────────────────────────
        Item {
            anchors.fill: parent
            visible: root.phase === "done"

            Column {
                anchors.centerIn: parent
                width: parent.width
                spacing: Theme.space.md

                AppIcon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    name: "check"
                    color: Theme.color.goLive
                    size: 40
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: qsTr("Import complete")
                    color: Theme.color.textTitle
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize + 3
                    font.weight: Theme.font.weightSemiBold
                }
                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: {
                        var msg = root.importedCount === 1
                            ? qsTr("1 song added to your library.")
                            : qsTr("%1 songs added to your library.").arg(root.importedCount)
                        if (root.skippedCount > 0) {
                            msg += "  "
                            msg += root.skippedCount === 1
                                ? qsTr("1 duplicate was skipped.")
                                : qsTr("%1 duplicates were skipped.").arg(root.skippedCount)
                        }
                        return msg
                    }
                    color: Theme.color.textSecondary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize
                    wrapMode: Text.WordWrap
                    lineHeight: 1.4
                }
            }

            PrimaryButton {
                anchors.bottom: parent.bottom
                anchors.right: parent.right
                variant: "brand"
                inkColor: "#ffffff"
                text: qsTr("Done")
                onClicked: AppState.closeModal()
            }
        }

        // ── Phase: error ────────────────────────────────────────────────
        Item {
            anchors.fill: parent
            visible: root.phase === "error"

            Column {
                anchors.centerIn: parent
                width: parent.width
                spacing: Theme.space.md

                AppIcon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    name: "alert-triangle"
                    color: Theme.color.live
                    size: 40
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: qsTr("Import failed")
                    color: Theme.color.textTitle
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize + 3
                    font.weight: Theme.font.weightSemiBold
                }
                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: root.errorText
                    color: Theme.color.textSecondary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize
                    wrapMode: Text.WordWrap
                    lineHeight: 1.4
                }
            }

            Row {
                anchors.bottom: parent.bottom
                anchors.right: parent.right
                spacing: Theme.space.sm

                GhostButton {
                    text: qsTr("Close")
                    onClicked: AppState.closeModal()
                }
                PrimaryButton {
                    variant: "brand"
                    inkColor: "#ffffff"
                    text: qsTr("Try again")
                    onClicked: root.resetToStart()
                }
            }
        }
    }
}
