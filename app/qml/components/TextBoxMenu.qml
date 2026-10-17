import QtQuick
import Crater

// Cut / Copy / Paste / Select all on a right-click in any text box.
//
// TextContextMenu (C++) spots the right-click and hands over the box with
// the selection it had at that moment. Every action puts that selection back
// first, so the menu works on what the operator had selected.
//
// Sits in Main.qml above ModalLayer rather than going through
// AppState.openModal("contextMenu"): that slot holds one modal at a time,
// and a text box inside the song editor would close the editor to show it.
PopoverMenu {
    id: root

    property var _target: null
    property int _start: 0
    property int _end: 0

    menuWidth: 200

    Connections {
        target: TextContextMenu
        function onRequested(item, x, y, selectionStart, selectionEnd) {
            root._target = item
            root._start  = selectionStart
            root._end    = selectionEnd
            root.model   = root._items()
            root.openAt(x, y)
        }
    }

    // Takes the box rather than reading _target: MenuRow closes the menu
    // before it runs the action.
    function _restoreSelection(t, start, end) {
        t.forceActiveFocus()
        t.select(start, end)
    }

    function _items() {
        const t        = _target
        const start    = _start
        const end      = _end
        const hasSel   = end > start
        const editable = !t.readOnly
        return [
            { label: qsTr("Cut"),  kbd: "Ctrl+X", enabled: hasSel && editable,
              action: function() { root._restoreSelection(t, start, end); t.cut() } },
            { label: qsTr("Copy"), kbd: "Ctrl+C", enabled: hasSel,
              action: function() { root._restoreSelection(t, start, end); t.copy() } },
            { label: qsTr("Paste"), kbd: "Ctrl+V", enabled: editable && t.canPaste,
              action: function() {
                  root._restoreSelection(t, start, end)
                  // The lyric editors are rich text. Their own Ctrl+V goes
                  // through pasteFiltered so a web page's colours and fonts
                  // stay out of the song, and so does this one.
                  if (t.textFormat === TextEdit.RichText) RichTextHelper.pasteFiltered(t, true)
                  else t.paste()
              } },
            { separator: true },
            { label: qsTr("Select all"), kbd: "Ctrl+A", enabled: t.length > 0,
              action: function() { t.forceActiveFocus(); t.selectAll() } }
        ]
    }

    onActiveChanged: AppState.textMenuOpen = active

    // Escape closes just the menu. Main.qml's Escape and the theme editor's
    // stand down while it is open (AppState.textMenuOpen).
    Shortcut {
        sequence: "Escape"
        enabled: root.active
        onActivated: root.close()
    }
}
