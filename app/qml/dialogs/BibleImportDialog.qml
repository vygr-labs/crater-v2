import QtQuick

// Add a Bible from a file: Zefania XML, OpenSong, OSIS, USFM or USX.
//
// Walks the operator through a small state machine bound to the
// BibleImporter singleton, like ImportDialog does for EasyWorship:
//
//   pick      -> choose the file (or a USFM / USX Bible's book files)
//   scanning  -> BibleImporter.analyze() reads it on a worker thread
//   confirm   -> what the file holds; name it and pick its code
//   importing -> BibleImporter.run() with a live progress bar
//   done      -> ready, with a shortcut to it  |  error -> why not
//
// Opened via AppState.openModal("bibleImport") from Settings > Scripture.
// modalProps.files, when given, skips the picker.
ModalShell {
    id: root

    dialogWidth: 580
    dialogHeight: 520
    title: qsTr("Add a Bible")

    // ── State machine ───────────────────────────────────────────────────
    property string phase: "pick"   // pick | scanning | confirm | importing | done | error
    property var    files: []
    property var    info: ({})
    property string importedCode: ""
    property int    importedVerses: 0
    property int    progressPercent: 0
    property string progressStage: ""
    property string errorText: ""

    readonly property string codeProblem:
        phase === "confirm" ? BibleImporter.codeProblem(codeField.text) : ""
    readonly property bool canImport:
        codeProblem.length === 0 && nameField.text.trim().length > 0

    function count(n) { return Number(n).toLocaleString(Qt.locale(), "f", 0) }

    Connections {
        target: BibleImporter
        function onAnalyzed(info) {
            if (root.phase !== "scanning") return
            root.info = info
            nameField.text = info.name || ""
            codeField.text = info.code || ""
            root.phase = "confirm"
        }
        function onProgress(percent, stage) {
            root.progressPercent = percent
            root.progressStage = stage
        }
        function onCompleted(code, verses) {
            root.importedCode = code
            root.importedVerses = verses
            root.phase = "done"
        }
        function onFailed(reason) {
            if (root.phase !== "scanning" && root.phase !== "importing") return
            root.errorText = reason
            root.phase = "error"
        }
    }

    Component.onCompleted: {
        const given = AppState.modalProps.files
        if (given && given.length > 0) scan(given)
    }

    function pickFiles() {
        // OpenSong Bibles often have no extension at all, hence All files.
        const chosen = FileDialogService.chooseOpenFiles(
            qsTr("Choose a Bible file, or all the book files of one Bible"),
            [qsTr("Bible files (*.xml *.xmm *.osis *.zefania *.usfm *.sfm *.usx *.txt)"),
             qsTr("All files (*)")],
            "bibleImport")
        if (chosen && chosen.length > 0) scan(chosen)
    }

    function scan(chosen) {
        root.files = chosen
        root.phase = "scanning"
        BibleImporter.analyze(chosen)
    }

    function startImport() {
        if (!root.canImport) return
        root.progressPercent = 0
        root.progressStage = qsTr("Starting...")
        root.phase = "importing"
        BibleImporter.run(root.files, codeField.text.trim(), nameField.text.trim())
    }

    function openInScripture() {
        AppState.setLibraryGroup("scripture", root.importedCode.toLowerCase())
        AppState.setActiveTab(AppState.tabKeys.indexOf("scripture"))
        AppState.closeModal()
    }

    function resetToStart() {
        root.phase = "pick"
        root.files = []
        root.errorText = ""
    }

    // Ctrl+Enter twice (AppState.saveAndCloseModal) imports from the
    // confirm step, the same as its Import button.
    function requestSave() { if (root.phase === "confirm") startImport() }

    component Body: Text {
        width: parent ? parent.width : 0
        color: Theme.color.textSecondary
        font.family: Theme.font.family
        font.pixelSize: Theme.font.bodySize
        wrapMode: Text.WordWrap
        lineHeight: 1.4
    }
    component Heading: Text {
        width: parent ? parent.width : 0
        color: Theme.color.textTitle
        font.family: Theme.font.family
        font.pixelSize: Theme.font.bodySize + 3
        font.weight: Theme.font.weightSemiBold
        wrapMode: Text.WordWrap
    }
    component Note: Text {
        width: parent ? parent.width : 0
        color: Theme.color.textTertiary
        font.family: Theme.font.family
        font.pixelSize: Theme.font.smallSize
        wrapMode: Text.WordWrap
        lineHeight: 1.4
    }
    // One labelled text box, the same look as NamingDialog's.
    component Field: Column {
        id: field
        property string label: ""
        property alias text: box.text
        property string problem: ""
        spacing: Theme.space.xs
        Text {
            text: field.label
            color: Theme.color.textSecondary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.smallSize
            font.weight: Theme.font.weightMedium
        }
        Rectangle {
            width: field.width
            height: 36
            radius: 0
            color: Theme.color.canvas
            border.color: field.problem.length > 0 ? Theme.color.live
                        : box.activeFocus ? Theme.color.brand : Theme.color.borderStrong
            border.width: 1
            Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }
            TextInput {
                id: box
                anchors.fill: parent
                anchors.leftMargin: Theme.space.md
                anchors.rightMargin: Theme.space.md
                verticalAlignment: TextInput.AlignVCenter
                clip: true
                color: Theme.color.textPrimary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize
                selectByMouse: true
                onAccepted: root.startImport()
                HoverHandler { cursorShape: Qt.IBeamCursor }
            }
        }
        Text {
            visible: field.problem.length > 0
            width: field.width
            text: field.problem
            color: Theme.color.live
            font.family: Theme.font.family
            font.pixelSize: Theme.font.smallSize
            wrapMode: Text.WordWrap
        }
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

                AppIcon { name: "book-open"; color: Theme.color.brand; size: 40 }
                Heading { text: qsTr("Add a Bible from a file") }
                Body {
                    text: qsTr("Crater reads Zefania XML, OpenSong, OSIS, USFM and USX Bibles. The new translation is added to the library every profile shares.")
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

                        Note {
                            text: qsTr("A USFM or USX Bible comes as one file per book, usually in a zip. Unzip it, open the folder and select all of its files. Anything that isn't a book is passed over.")
                        }
                        Note {
                            text: qsTr("Many modern translations are copyrighted. Only add one your church is allowed to use.")
                        }
                    }
                }
            }

            Row {
                anchors.bottom: parent.bottom
                anchors.right: parent.right
                spacing: Theme.space.sm

                GhostButton { text: qsTr("Cancel"); onClicked: AppState.closeModal() }
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
                text: qsTr("Reading the Bible...")
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

                Heading {
                    text: (root.info.books || 0) === 1
                          ? qsTr("Found 1 book, %1 verses").arg(root.count(root.info.verses || 0))
                          : qsTr("Found %1 books, %2 verses").arg(root.info.books || 0)
                                                             .arg(root.count(root.info.verses || 0))
                }
                Note {
                    text: qsTr("%1 file").arg(root.info.format || "")
                          + (root.files.length > 1 ? "  ·  " + qsTr("%1 files chosen").arg(root.files.length) : "")
                }

                Row {
                    width: parent.width
                    spacing: Theme.space.md
                    Field {
                        id: nameField
                        width: parent.width - codeField.width - parent.spacing
                        label: qsTr("Name")
                        problem: nameField.text.trim().length === 0 ? qsTr("Give it a name.") : ""
                    }
                    Field {
                        id: codeField
                        width: 150
                        label: qsTr("Code")
                        problem: root.codeProblem
                    }
                }

                Note {
                    text: qsTr("The code is what the Scripture tab shows on its card, and what you type after a reference to use it, as in John 3:16 KJV.")
                }

                Note {
                    visible: (root.info.skippedBooks || []).length > 0
                    color: Theme.color.textSecondary
                    text: qsTr("Left out: %1. Crater's Bibles share the 66 books of the Protestant canon, so books outside it aren't added.")
                              .arg((root.info.skippedBooks || []).join(", "))
                }
                Note {
                    visible: root.info.booksByPosition === true
                    color: Theme.color.textSecondary
                    text: qsTr("Some book names weren't ones Crater knows, so those books were matched by their place in the file. Check a few references once it's added.")
                }
                Note {
                    visible: (root.info.ignoredFiles || []).length > 0
                    text: qsTr("Not Bible files, passed over: %1").arg((root.info.ignoredFiles || []).join(", "))
                }
            }

            Row {
                anchors.bottom: parent.bottom
                anchors.right: parent.right
                spacing: Theme.space.sm

                GhostButton { text: qsTr("Back"); onClicked: root.resetToStart() }
                PrimaryButton {
                    variant: "brand"
                    inkColor: "#ffffff"
                    iconName: "download"
                    text: qsTr("Add Bible")
                    enabled: root.canImport
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
                    text: qsTr("Adding %1...").arg(codeField.text.trim().toUpperCase())
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
                Heading {
                    horizontalAlignment: Text.AlignHCenter
                    text: qsTr("%1 is ready").arg(root.importedCode)
                }
                Body {
                    horizontalAlignment: Text.AlignHCenter
                    text: qsTr("%1 verses added. It's at the end of the translation list in Scripture.")
                              .arg(root.count(root.importedVerses))
                }
            }

            Row {
                anchors.bottom: parent.bottom
                anchors.right: parent.right
                spacing: Theme.space.sm

                GhostButton { text: qsTr("Open in Scripture"); onClicked: root.openInScripture() }
                PrimaryButton {
                    variant: "brand"
                    inkColor: "#ffffff"
                    text: qsTr("Done")
                    onClicked: AppState.closeModal()
                }
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
                Heading {
                    horizontalAlignment: Text.AlignHCenter
                    text: qsTr("Couldn't add this Bible")
                }
                Body {
                    horizontalAlignment: Text.AlignHCenter
                    text: root.errorText
                }
            }

            Row {
                anchors.bottom: parent.bottom
                anchors.right: parent.right
                spacing: Theme.space.sm

                GhostButton { text: qsTr("Close"); onClicked: AppState.closeModal() }
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
