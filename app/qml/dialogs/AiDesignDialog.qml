import QtQuick
import QtQuick.Controls.Basic
import Crater

// "Design with AI" — hands the user a self-contained brief to paste into any
// assistant, and takes the reply straight back into the theme editor.
//
// Opened from EditorHeader via:
//   AppState.openModal("aiDesign", {
//       kind, currentTokens, onApply: function(tokens, name, kind) { ... }
//   })
//
// The callback is why this is a modal rather than something the dialog does
// itself: the reply must land in the editor's WORKING copy, not in the
// database. That way the user looks at the result on the canvas, undoes it
// with Ctrl+Z if it is wrong, and only writes a row when they press Save.
// Creating a theme here would put an unreviewed design in the library and
// leave the editor showing the old one.
ModalShell {
    id: root

    dialogWidth:  660
    dialogHeight: 620
    title: qsTr("Design with AI")

    readonly property string _kind: AppState.modalProps.kind || "presentation"
    readonly property var    _currentTokens: AppState.modalProps.currentTokens || ({})

    property string _brief: ""
    property bool   _includeCurrent: false
    property bool   _copied: false

    // Populated only while the prompt view is open. Building it is pure
    // string assembly, but it runs to roughly 12 KB, so there is no reason
    // to rebuild it on every keystroke in the brief field just to keep a
    // hidden preview warm.
    property string _promptText: ""
    property bool   _showPrompt: false

    // Live verdict on whatever is in the paste box, from the same validator
    // Save runs. Showing it before the user commits turns "Load" into a
    // button that cannot fail, rather than one that might reject a reply
    // they have already thrown the chat window away for.
    property var _check: ({ ok: false, error: "" })

    readonly property bool _kindMismatch:
        root._check.ok && !!root._check.kind && root._check.kind !== root._kind

    readonly property int _designCount:
        root._check.ok ? ThemeService.themeLayouts(root._check.tokens).length : 0

    function _buildPrompt() {
        return ThemeService.designPrompt(
            root._kind, root._brief,
            root._includeCurrent ? root._currentTokens : ({}))
    }

    function _copyPrompt() {
        ClipboardService.setText(root._buildPrompt())
        root._copied = true
        copiedTimer.restart()
    }

    function _recheck() {
        const t = pasteArea.text
        if (!t || t.trim().length === 0) {
            root._check = ({ ok: false, error: "" })
            return
        }
        root._check = ThemeService.parseThemeJsonText(t)
    }

    function _apply() {
        if (!root._check.ok) return
        const cb = AppState.modalProps.onApply
        if (cb) cb(root._check.tokens,
                   root._check.name || "",
                   root._check.kind || "")
        AppState.closeModal()
    }

    Timer { id: copiedTimer;    interval: 2000; onTriggered: root._copied = false }
    Timer { id: checkDebounce;  interval: 250;  onTriggered: root._recheck() }

    // ── Prompt view ─────────────────────────────────────────────────────
    // Full-pane read-only look at exactly what Copy puts on the clipboard.
    // Nothing here is editable: the brief field on the main view is the one
    // part the user is meant to change, and letting them edit the schema
    // section would only produce themes the validator rejects.
    Item {
        anchors.fill: parent
        anchors.margins: Theme.space.lg
        visible: root._showPrompt

        Rectangle {
            id: promptBox
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: promptActions.top
            anchors.bottomMargin: Theme.space.md
            color: Theme.color.bgContent
            border.color: Theme.color.borderSubtle
            border.width: 1

            Flickable {
                id: promptScroll
                anchors.fill: parent
                anchors.margins: Theme.space.sm
                clip: true
                contentHeight: promptText.implicitHeight
                contentWidth: width
                interactive: contentHeight > height
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: AppScrollBar {}

                TextEdit {
                    id: promptText
                    width: promptScroll.width - Theme.size.scrollBar
                    readOnly: true
                    selectByMouse: true
                    wrapMode: TextEdit.Wrap
                    text: root._promptText
                    color: Theme.color.textSecondary
                    font.family: Theme.font.monoFamily
                    font.pixelSize: Theme.font.smallSize - 1
                }
            }

        }

        Row {
            id: promptActions
            anchors.bottom: parent.bottom
            anchors.right: parent.right
            spacing: Theme.space.sm

            GhostButton {
                text: qsTr("Back")
                iconName: "chevron-left"
                onClicked: root._showPrompt = false
            }
            PrimaryButton {
                variant: "brand"
                text: root._copied ? qsTr("Copied") : qsTr("Copy prompt")
                iconName: root._copied ? "check" : "copy"
                onClicked: root._copyPrompt()
            }
        }
    }

    // ── Main view ───────────────────────────────────────────────────────
    Item {
        anchors.fill: parent
        anchors.margins: Theme.space.lg
        visible: !root._showPrompt

        Column {
            id: col
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: Theme.space.sm

            // ── Step 1 ──────────────────────────────────────────────────
            Text {
                text: qsTr("1. Describe what you want")
                color: Theme.color.textPrimary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize
                font.weight: Theme.font.weightSemiBold
            }
            Text {
                width: col.width
                text: qsTr("Leave this blank and the AI will design something of its own.")
                color: Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                wrapMode: Text.WordWrap
                bottomPadding: 2
            }

            Rectangle {
                width: col.width
                height: 76
                color: Theme.color.bgContent
                border.color: briefArea.activeFocus
                    ? Theme.color.brand : Theme.color.borderSubtle
                border.width: 1

                // A TextEdit is sized by its CONTENT, and anchors bound the
                // item without bounding what it paints, so a brief longer
                // than three lines would render over the rest of the dialog.
                // The Flickable below is what stops that. Do NOT clip here as
                // well: Item.clip clips an item's own painting too, and this
                // Rectangle's 1px border sits exactly on that boundary, so it
                // loses its left edge to the rounding at a fractional device
                // pixel ratio.
                Flickable {
                    id: briefScroll
                    anchors.fill: parent
                    anchors.margins: Theme.space.sm
                    clip: true
                    contentHeight: briefArea.height
                    contentWidth: width
                    interactive: contentHeight > height
                    boundsBehavior: Flickable.StopAtBounds

                    TextEdit {
                        id: briefArea
                        width: briefScroll.width
                        // Fill the viewport even when empty. A content-sized
                        // TextEdit is one line tall, so everything below that
                        // line belongs to the Flickable and a click there
                        // never moves focus -- the box looks typeable and
                        // silently is not.
                        height: Math.max(implicitHeight, briefScroll.height)
                        color: Theme.color.textPrimary
                        font.family: Theme.font.family
                        font.pixelSize: Theme.font.bodySize
                        selectByMouse: true
                        wrapMode: TextEdit.Wrap
                        onTextChanged: root._brief = text
                    }
                }
                Text {
                    anchors.fill: parent
                    anchors.margins: Theme.space.sm
                    visible: briefArea.text.length === 0
                    text: qsTr("Warm, candle-lit, serif type. Something for a carol service.")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.bodySize
                    wrapMode: Text.WordWrap
                }
            }

            // Start-from toggle. Off by default: the common case is wanting
            // something new, and sending the current design silently would
            // anchor the AI to it without the user ever asking.
            Item {
                width: col.width
                height: 32

                Rectangle {
                    id: startBox
                    width: 18
                    height: 18
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    radius: 3
                    color: root._includeCurrent ? Theme.color.brand : "transparent"
                    border.color: root._includeCurrent
                        ? Theme.color.brand : Theme.color.borderStrong
                    border.width: 1

                    AppIcon {
                        visible: root._includeCurrent
                        anchors.centerIn: parent
                        name: "check"
                        color: "#ffffff"
                        size: 12
                    }
                }
                Text {
                    anchors.left: startBox.right
                    anchors.leftMargin: Theme.space.md
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Send my current design too, and evolve it")
                    color: Theme.color.textSecondary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root._includeCurrent = !root._includeCurrent
                }
            }

            Row {
                spacing: Theme.space.sm
                bottomPadding: Theme.space.sm

                PrimaryButton {
                    variant: "brand"
                    text: root._copied ? qsTr("Copied") : qsTr("Copy prompt")
                    iconName: root._copied ? "check" : "copy"
                    onClicked: root._copyPrompt()
                }
                GhostButton {
                    text: qsTr("View prompt")
                    iconName: "file-text"
                    onClicked: {
                        root._promptText = root._buildPrompt()
                        root._showPrompt = true
                    }
                }
            }

            Rectangle { width: col.width; height: 1; color: Theme.color.borderSubtle }

            // ── Step 2 ──────────────────────────────────────────────────
            Text {
                text: qsTr("2. Paste the reply back")
                color: Theme.color.textPrimary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize
                font.weight: Theme.font.weightSemiBold
                topPadding: Theme.space.sm
            }
            Text {
                width: col.width
                text: qsTr("Paste it into Claude, ChatGPT or any other assistant, then paste "
                           + "what it gives you back here. Code fences and any chatter around "
                           + "the JSON are fine.")
                color: Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                wrapMode: Text.WordWrap
                bottomPadding: 2
            }
        }

        Rectangle {
            id: pasteBox
            anchors.top: col.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: status.top
            anchors.bottomMargin: Theme.space.sm
            color: Theme.color.bgContent
            border.color: pasteArea.activeFocus
                ? Theme.color.brand : Theme.color.borderSubtle
            // No clip here -- see the brief field above. pasteScroll clips
            // the TextEdit, and clipping at this level costs the border.
            border.width: 1

            Flickable {
                id: pasteScroll
                anchors.fill: parent
                anchors.margins: Theme.space.sm
                clip: true
                contentHeight: pasteArea.height
                contentWidth: width
                interactive: contentHeight > height
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: AppScrollBar {}

                TextEdit {
                    id: pasteArea
                    width: pasteScroll.width - Theme.size.scrollBar
                    // See briefArea: without this the box is only clickable
                    // on its first line, and a paste lands wherever focus
                    // actually was.
                    height: Math.max(implicitHeight, pasteScroll.height)
                    color: Theme.color.textPrimary
                    font.family: Theme.font.monoFamily
                    font.pixelSize: Theme.font.smallSize
                    selectByMouse: true
                    wrapMode: TextEdit.Wrap
                    onTextChanged: checkDebounce.restart()
                }
            }

            Text {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.margins: Theme.space.sm
                visible: pasteArea.text.length === 0
                text: qsTr("{ \"name\": ... }")
                color: Theme.color.textTertiary
                font.family: Theme.font.monoFamily
                font.pixelSize: Theme.font.smallSize
            }
        }

        // Verdict line. Occupies its row whether or not it has something to
        // say, so nothing below it moves as the user pastes.
        Row {
            id: status
            anchors.bottom: actions.top
            anchors.bottomMargin: Theme.space.sm
            anchors.left: parent.left
            anchors.right: parent.right
            height: 34
            spacing: Theme.space.xs

            AppIcon {
                anchors.verticalCenter: parent.verticalCenter
                visible: root._check.ok || (root._check.error || "").length > 0
                name: root._check.ok
                    ? (root._kindMismatch ? "alert-triangle" : "check")
                    : "alert-triangle"
                color: root._check.ok
                    ? (root._kindMismatch ? Theme.color.warning : Theme.color.success)
                    : Theme.color.warning
                size: Theme.icon.sm
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: status.width - Theme.icon.sm - Theme.space.xs
                elide: Text.ElideRight
                maximumLineCount: 2
                wrapMode: Text.WordWrap
                text: {
                    if ((root._check.error || "").length > 0) return root._check.error
                    if (!root._check.ok) return ""
                    const label = (root._check.name && root._check.name.length > 0)
                        ? root._check.name : qsTr("Untitled")
                    if (root._kindMismatch) {
                        return qsTr("\"%1\" is a %2 theme, not %3. Loading it will drop "
                                    + "text that this kind cannot show.")
                                 .arg(label).arg(root._check.kind).arg(root._kind)
                    }
                    return root._designCount > 1
                        ? qsTr("\"%1\", %2 designs. Ready to load.")
                            .arg(label).arg(root._designCount)
                        : qsTr("\"%1\". Ready to load.").arg(label)
                }
                color: (root._check.error || "").length > 0
                    ? Theme.color.warning
                    : (root._kindMismatch ? Theme.color.warning : Theme.color.textSecondary)
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
            }
        }

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
                text: qsTr("Load into editor")
                iconName: "sparkles"
                enabled: root._check.ok
                onClicked: root._apply()
            }
        }
    }
}
