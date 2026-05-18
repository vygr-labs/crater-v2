import QtQuick
import Crater

// Small formatting toolbar that drives a WYSIWYG TextEdit. Sits inside
// LyricSectionEditor above its lyric textarea, visible only when the
// textarea has focus.
//
// Buttons:
//   B / I / U      — toggle bold / italic / underline on the selection
//   color swatches — set foreground color on the selection (7 named
//                    palette entries, mapped to theme-aware hex values)
//
// State tracking: the toolbar re-reads the cursor format on every cursor /
// selection change so its highlight states match what the user would see
// if they typed at that position. Polling is intentionally cheap — each
// call into RichTextHelper is a single QTextCursor::charFormat() lookup.
//
// Focus contract: the toolbar's MouseAreas don't grab focus on click
// (MouseArea default), so clicking a button doesn't dismiss the toolbar
// or move focus away from `target`. Required for the "toolbar only
// visible when target has focus" pattern to work without flicker.
Row {
    id: root

    // The TextEdit (or any QQuickItem exposing `textDocument` /
    // `selectionStart` / `selectionEnd`) that this toolbar drives.
    // May be null when no lyric editor has focus — buttons gracefully
    // no-op in that case (the enabled binding below also dims them
    // visually).
    property var target

    height: 28
    spacing: 2

    // Dim the buttons when there's nothing to drive — gives the operator
    // a visual signal that "you need to click into a lyric box first."
    // Doesn't disable the row itself, so the toolbar still reserves
    // layout space and doesn't reflow on focus changes.
    opacity: target ? 1.0 : 0.45
    Behavior on opacity { NumberAnimation { duration: Theme.motion.instant } }

    // ── Internal state mirrors of the target's cursor format ───────────
    // These are refreshed via _refreshState() on every cursor / selection
    // change. Bound directly into the button visuals so the toolbar
    // reflects what the operator would type at the current position.
    property bool _isBold: false
    property bool _isItalic: false
    property bool _isUnderline: false
    property string _currentColor: ""

    function _refreshState() {
        if (!target) {
            _isBold = false
            _isItalic = false
            _isUnderline = false
            _currentColor = ""
            return
        }
        _isBold      = RichTextHelper.isBold(target)
        _isItalic    = RichTextHelper.isItalic(target)
        _isUnderline = RichTextHelper.isUnderline(target)
        _currentColor = RichTextHelper.currentColor(target)
    }

    // When the target switches (e.g. operator clicks into a different
    // section's lyric editor), re-read the new target's format state so
    // the button highlights reflect the new editor's cursor immediately.
    onTargetChanged: _refreshState()

    // Watch for cursor / selection changes on the target so the toolbar
    // reflects the format at the new position. Three separate handlers
    // because QQuickTextEdit fires distinct signals for each.
    Connections {
        target: root.target
        function onCursorPositionChanged() { root._refreshState() }
        function onSelectionStartChanged() { root._refreshState() }
        function onSelectionEndChanged()   { root._refreshState() }
    }

    // ─── B / I / U buttons ──────────────────────────────────────────────
    // Each button is a small square with a single letter, highlighted
    // when the format is active at the cursor. Click toggles the format
    // on the current selection (or arms it for the next typed char if
    // there's no selection).
    component MarkButton: Rectangle {
        id: btn

        property string label: ""
        property bool   active: false
        // True when this button should render the label as italic / underline /
        // bold for visual identity — independent of `active` (which controls
        // background).
        property bool   labelBold: false
        property bool   labelItalic: false
        property bool   labelUnderline: false

        signal clicked()

        width: 28
        height: 28
        radius: 0
        color: btn.active        ? Theme.color.brandSubtle
             : ma.containsMouse  ? Theme.color.overlay
                                  : "transparent"
        border.color: btn.active ? Theme.color.brand : "transparent"
        border.width: 1

        Behavior on color        { ColorAnimation { duration: Theme.motion.instant } }
        Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }

        Text {
            anchors.centerIn: parent
            text: btn.label
            color: btn.active ? Theme.color.brand : Theme.color.textPrimary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.bodySize
            font.weight: btn.labelBold ? Theme.font.weightBold : Theme.font.weightMedium
            font.italic: btn.labelItalic
            font.underline: btn.labelUnderline
        }

        MouseArea {
            id: ma
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            // `acceptedButtons: Qt.LeftButton` AND no `focus: true` means
            // clicks don't steal focus from the target — toolbar stays up.
            onClicked: btn.clicked()
        }
    }

    MarkButton {
        label: "B"
        labelBold: true
        active: root._isBold
        onClicked: {
            RichTextHelper.toggleBold(root.target)
            root._refreshState()
        }
    }
    MarkButton {
        label: "I"
        labelItalic: true
        active: root._isItalic
        onClicked: {
            RichTextHelper.toggleItalic(root.target)
            root._refreshState()
        }
    }
    MarkButton {
        label: "U"
        labelUnderline: true
        active: root._isUnderline
        onClicked: {
            RichTextHelper.toggleUnderline(root.target)
            root._refreshState()
        }
    }

    // ─── Small separator ────────────────────────────────────────────────
    Rectangle {
        width: 1
        height: parent.height - 8
        anchors.verticalCenter: parent.verticalCenter
        color: Theme.color.borderSubtle
    }

    // ─── Color swatches ─────────────────────────────────────────────────
    // Seven named palette entries rendered as filled circles. Clicking a
    // swatch applies that color to the selection. The swatch that matches
    // the current color (if any) is ringed for "this is what's active".
    Repeater {
        model: LyricsService.namedColors()
        delegate: Rectangle {
            required property string modelData

            width: 28
            height: 28
            color: "transparent"

            readonly property string _hex:
                LyricsService.resolveColor(modelData)
            readonly property bool _selected:
                _hex.length > 0 && _hex === root._currentColor.toLowerCase()

            // Swatch circle. Slightly smaller than the cell so neighbors
            // don't touch.
            Rectangle {
                anchors.centerIn: parent
                width: 18
                height: 18
                radius: width / 2
                color: parent._hex
                border.color: parent._selected ? Theme.color.textPrimary
                                                : Qt.darker(parent._hex, 1.4)
                border.width: parent._selected ? 2 : 1

                Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }
                Behavior on border.width { NumberAnimation { duration: Theme.motion.instant } }
            }

            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    RichTextHelper.setSelectionColor(root.target, modelData)
                    root._refreshState()
                }
            }
        }
    }
}
