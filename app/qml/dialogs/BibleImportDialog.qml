import QtQuick
import QtQuick.Controls.Basic

// Add a Bible from a file: Zefania XML, OpenSong, OSIS, USFM or USX.
//
// Walks the operator through a small state machine bound to the
// BibleImporter singleton, like ImportDialog does for EasyWorship:
//
//   pick      -> choose the file (or a USFM / USX Bible's book files)
//   scanning  -> BibleImporter.analyze() reads it on a worker thread
//   confirm   -> what the file holds; name it and pick its code
//             (a code already in use can be replaced, behind a confirm)
//   importing -> BibleImporter.run() or replace() with a live progress bar
//   done      -> ready, with a shortcut to it  |  error -> why not
//
// Every BibleImporter call returns a request id its signals carry, and this
// dialog only listens to its own: an earlier dialog's late answer, or a
// removal running from Settings, never lands here. It can't be closed while
// importing, by any route (closeLocked holds off even a double Escape).
// Reading can be cancelled: it writes nothing.
//
// Opened via AppState.openModal("bibleImport") from Settings > Scripture.
// modalProps.files, when given, skips the picker.
ModalShell {
    id: root

    dialogWidth: 580
    dialogHeight: 540
    title: qsTr("Add a Bible")

    // ── State machine ───────────────────────────────────────────────────
    property string phase: "pick"   // pick | scanning | confirm | importing | done | error
    property int    request: -1     // the BibleImporter call this dialog waits on
    property var    files: []
    property var    info: ({})
    property string importedCode: ""
    property string retiredCode: ""    // the replaced Bible's new code; empty when adding
    property bool   replacing: false
    property int    importedVerses: 0
    property int    progressPercent: 0
    property string progressStage: ""
    property string errorText: ""
    property string failedIn: ""    // the phase that failed: scanning | importing
    readonly property bool closeLocked: phase === "importing"

    readonly property string codeProblem:
        phase === "confirm" ? BibleImporter.codeProblem(codeField.text) : ""
    readonly property bool canImport:
        codeProblem.length === 0 && nameField.text.trim().length > 0
    // The code is taken by a Bible this one can take over.
    readonly property bool canReplace:
        codeProblem.length > 0 && nameField.text.trim().length > 0
        && BibleImporter.canReplace(codeField.text)

    function count(n) { return Number(n).toLocaleString(Qt.locale(), "f", 0) }
    function list(items) { return (items || []).join(", ") }

    Connections {
        target: BibleImporter
        function onAnalyzed(request, info) {
            if (request !== root.request || root.phase !== "scanning") return
            root.info = info
            nameField.text = info.name || ""
            codeField.text = info.code || ""
            root.phase = "confirm"
            Qt.callLater(nameField.focusInput)
        }
        function onProgress(request, percent, stage) {
            if (request !== root.request) return
            root.progressPercent = percent
            root.progressStage = stage
        }
        function onCompleted(request, code, verses) {
            if (request !== root.request) return
            root.importedCode = code
            root.importedVerses = verses
            root.retiredCode = ""
            root.phase = "done"
        }
        function onReplaced(request, code, retiredCode, verses) {
            if (request !== root.request) return
            root.importedCode = code
            root.importedVerses = verses
            root.retiredCode = retiredCode
            root.phase = "done"
        }
        function onFailed(request, reason) {
            if (request !== root.request) return
            root.errorText = reason
            root.failedIn = root.phase
            root.phase = "error"
        }
    }

    Component.onCompleted: {
        const given = AppState.modalProps.files
        if (given && given.length > 0) scan(given)
    }
    // Closed without importing: what was read for the import goes.
    Component.onDestruction: if (phase !== "done") BibleImporter.discardAnalysis()

    // Escape, the backdrop and the X wait while the Bible is being added:
    // closing then would leave the operator not knowing whether it went in.
    function requestClose() {
        if (root.closeLocked) return
        AppState.closeModal()
    }

    // Ctrl+Enter twice: Add Bible on the confirm step, close otherwise.
    function requestSave() {
        if (root.phase === "confirm") startImport()
        else requestClose()
    }

    function pickFiles() {
        // OpenSong Bibles often have no extension at all, hence All files.
        const chosen = FileDialogService.chooseOpenFiles(
            qsTr("Choose a Bible file, a zip, or all the book files of one Bible"),
            [qsTr("Bible files (*.xml *.xmm *.osis *.zefania *.usfm *.sfm *.usx *.txt *.zip)"),
             qsTr("All files (*)")],
            "bibleImport")
        if (chosen && chosen.length > 0) scan(chosen)
    }

    function scan(chosen) {
        root.files = chosen
        root.phase = "scanning"
        root.request = BibleImporter.analyze(chosen)
    }

    function startImport() {
        if (root.phase !== "confirm" || !root.canImport) return
        root.progressPercent = 0
        root.progressStage = qsTr("Starting...")
        root.replacing = false
        root.phase = "importing"
        root.request = BibleImporter.run(root.files, codeField.text.trim(), nameField.text.trim())
    }

    function askReplace() {
        if (root.phase !== "confirm" || !root.canReplace) return
        const old = BibleImporter.replaceInfo(codeField.text)
        if (!old.code) return
        const incoming = root.info.verses || 0
        replaceConfirm.title = qsTr("Replace %1?").arg(old.code)
        replaceConfirm.body = qsTr("%1 has %2 verses. This file has %3.").arg(old.code)
                                  .arg(root.count(old.verses)).arg(root.count(incoming))
            + (incoming < old.verses
               ? " " + qsTr("A reference to a verse this file doesn't have won't find anything in %1.").arg(old.code)
               : "")
            + "\n\n"
            + qsTr("The old copy stays as %1, hidden, and you can switch back in Settings > Scripture. Schedules keep the verses they already hold.")
                  .arg(old.retiredCode)
        replaceConfirm.openConfirm()
    }

    function startReplace() {
        if (root.phase !== "confirm" || !root.canReplace) return
        root.progressPercent = 0
        root.progressStage = qsTr("Starting...")
        root.replacing = true
        root.phase = "importing"
        root.request = BibleImporter.replace(root.files, codeField.text.trim(), nameField.text.trim())
    }

    function openInScripture() {
        AppState.setLibraryGroup("scripture", root.importedCode.toLowerCase())
        AppState.setActiveTab(AppState.tabKeys.indexOf("scripture"))
        AppState.closeModal()
    }

    function resetToStart() {
        BibleImporter.discardAnalysis()   // and a read still running won't keep its result
        root.phase = "pick"
        root.request = -1
        root.files = []
        root.errorText = ""
    }

    // After a failed import (the library was busy, the code was taken
    // meanwhile) the files, name and code are all still good: back to the
    // confirm step. After a failed read, other files are needed.
    function tryAgain() {
        root.errorText = ""
        root.request = -1
        if (root.failedIn === "importing") root.phase = "confirm"
        else resetToStart()
    }

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
        property alias  text: box.text
        property alias  maximumLength: box.maximumLength
        property string problem: ""
        signal accepted()
        function focusInput() {
            box.forceActiveFocus()
            box.selectAll()
        }
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
                activeFocusOnTab: true
                onAccepted: field.accepted()
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
                            text: qsTr("A USFM or USX Bible comes as one file per book, usually in a zip. Choose the zip, or select all of the book files. Anything that isn't a book is skipped.")
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
                    iconName: "folder"
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

            // Reading writes nothing, so it can be abandoned. Its answer,
            // if it still comes, is for a request no one is waiting on.
            GhostButton {
                anchors.bottom: parent.bottom
                anchors.right: parent.right
                text: qsTr("Cancel")
                onClicked: root.resetToStart()
            }
        }

        // ── Phase: confirm ──────────────────────────────────────────────
        Item {
            anchors.fill: parent
            visible: root.phase === "confirm"

            // Scrolls when a long list of left-out books or skipped files
            // (or a larger UI scale) would run under the buttons.
            Flickable {
                id: confirmFlick
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: confirmButtons.top
                anchors.bottomMargin: Theme.space.md
                contentHeight: confirmCol.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: AppScrollBar {}

                Column {
                    id: confirmCol
                    width: confirmFlick.width
                    spacing: Theme.space.md

                    Heading {
                        text: qsTr("Found %1, %2").arg(
                                  (root.info.books || 0) === 1 ? qsTr("1 book")
                                      : qsTr("%1 books").arg(root.info.books || 0)).arg(
                                  (root.info.verses || 0) === 1 ? qsTr("1 verse")
                                      : qsTr("%1 verses").arg(root.count(root.info.verses || 0)))
                    }
                    Note {
                        text: (root.info.files || 0) > 1
                              ? qsTr("%1, %2 files").arg(root.info.format || "").arg(root.info.files)
                              : qsTr("%1 file").arg(root.info.format || "")
                    }

                    Row {
                        width: parent.width
                        spacing: Theme.space.md
                        Field {
                            id: nameField
                            width: parent.width - codeField.width - parent.spacing
                            label: qsTr("Name")
                            problem: root.phase === "confirm" && nameField.text.trim().length === 0
                                     ? qsTr("Give it a name.") : ""
                            onAccepted: root.startImport()
                        }
                        Field {
                            id: codeField
                            width: 150
                            label: qsTr("Code")
                            maximumLength: 12
                            problem: root.codeProblem
                            onAccepted: root.startImport()
                        }
                    }

                    Note {
                        text: qsTr("The code is what the Scripture tab shows on its card, and what you type after a reference to use it, as in John 3:16 KJV.")
                    }

                    // The file names a code that's taken, and a free one was
                    // suggested. Adding a second copy may not be what's wanted.
                    Row {
                        width: parent.width
                        spacing: Theme.space.md
                        visible: !!root.info.existingCode && root.codeProblem.length === 0
                                 && String(codeField.text).trim().toUpperCase()
                                    !== String(root.info.existingCode).toUpperCase()
                        Note {
                            width: parent.width - replaceInstead.width - parent.spacing
                            anchors.verticalCenter: parent.verticalCenter
                            color: Theme.color.textSecondary
                            text: qsTr("You already have %1, so this would add a second copy.").arg(root.info.existingCode || "")
                        }
                        GhostButton {
                            id: replaceInstead
                            text: qsTr("Replace %1 instead").arg(root.info.existingCode || "")
                            onClicked: codeField.text = root.info.existingCode
                        }
                    }
                    Note {
                        visible: root.canReplace
                        color: Theme.color.textSecondary
                        text: qsTr("You can replace it. This Bible takes over the code, so your default version and typed references keep working, and the old copy is kept in case you want it back.")
                    }

                    Note {
                        visible: (root.info.warnings || []).length > 0
                        color: Theme.color.live
                        text: root.list(root.info.warnings)
                    }
                    Note {
                        visible: (root.info.skippedBooks || []).length > 0
                        color: Theme.color.textSecondary
                        text: qsTr("Left out: %1. Crater doesn't recognise these books.")
                                  .arg(root.list(root.info.skippedBooks))
                    }
                    Note {
                        visible: root.info.booksByPosition === true
                        color: Theme.color.textSecondary
                        text: qsTr("Some book names weren't ones Crater knows, so those books were matched by their place in the file. Check a few references once it's added.")
                    }
                    Note {
                        visible: (root.info.otherFormats || []).length > 0
                        text: qsTr("The zip also has this Bible as %1. Crater read the %2 copy.")
                                  .arg(root.list(root.info.otherFormats)).arg(root.info.format || "")
                    }
                    Note {
                        visible: (root.info.ignoredFiles || []).length > 0
                        text: qsTr("Not Bible files, so skipped: %1").arg(root.list(root.info.ignoredFiles))
                    }
                }
            }

            Row {
                id: confirmButtons
                anchors.bottom: parent.bottom
                anchors.right: parent.right
                spacing: Theme.space.sm

                GhostButton { text: qsTr("Back"); onClicked: root.resetToStart() }
                PrimaryButton {
                    visible: !root.canReplace
                    variant: "brand"
                    inkColor: "#ffffff"
                    iconName: "download"
                    text: qsTr("Add Bible")
                    enabled: root.canImport
                    onClicked: root.startImport()
                }
                PrimaryButton {
                    visible: root.canReplace
                    variant: "brand"
                    inkColor: "#ffffff"
                    iconName: "download"
                    text: qsTr("Replace %1...").arg(codeField.text.trim().toUpperCase())
                    onClicked: root.askReplace()
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
                    text: (root.replacing ? qsTr("Replacing %1...") : qsTr("Adding %1..."))
                              .arg(codeField.text.trim().toUpperCase())
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
                    text: root.retiredCode.length > 0
                          ? qsTr("%1 verses added. The old copy is now %2, hidden. To switch back, go to Settings > Scripture.")
                                .arg(root.count(root.importedVerses)).arg(root.retiredCode)
                          : qsTr("%1 verses added. It's at the end of the translation list in Scripture.")
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
                    text: root.replacing ? qsTr("Couldn't replace this Bible") : qsTr("Couldn't add this Bible")
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
                    text: root.failedIn === "importing" ? qsTr("Try again") : qsTr("Choose other files")
                    onClicked: root.tryAgain()
                }
            }
        }

        ConfirmationOverlay {
            id: replaceConfirm
            anchors.fill: parent
            confirmLabel: qsTr("Replace")
            onConfirmed: root.startReplace()
        }
    }
}
