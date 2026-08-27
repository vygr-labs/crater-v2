import QtQuick
import QtQuick.Controls.Basic
import Crater

// Horizontal strip of a presentation theme's LAYOUTS, each rendered as a
// live thumbnail of that actual design.
//
// Thumbnails rather than a dropdown of names, because that is the entire
// point of a template: an operator building a deck mid-week picks "the one
// with the big centred heading", not the word "Section divider". Each cell
// mounts ThemePreview with a layoutId, which routes through the same
// ThemedNodeGraph the projector uses, so what you click is what goes out.
//
//   LayoutStrip {
//       theme:    someTheme          // crater::Theme value
//       layoutId: slide.layout       // "" = the theme's default
//       onLayoutPicked: function(id) { ... }
//   }
//
// A slide whose stored layout id is absent from the current theme still
// shows its stored id as a trailing "missing" cell rather than silently
// snapping the selection onto the fallback — see _missingId. Losing that
// distinction would let an operator "fix" a theme swap by clicking around
// and overwrite ids that would have come back on their own.
Item {
    id: root

    // ── Inputs ──────────────────────────────────────────────────────────
    property var    theme                 // crater::Theme value, or null
    property string layoutId: ""          // "" = theme default

    signal layoutPicked(string id)

    implicitHeight: 96

    readonly property var _tokens:  theme && theme.tokens ? theme.tokens : ({})
    readonly property var _layouts: ThemeService.themeLayouts(_tokens)

    // The stored id when the current theme has no such design. Empty
    // otherwise, including when layoutId is "" (that means "default", which
    // every theme satisfies by definition).
    readonly property string _missingId:
        (layoutId.length > 0 && !ThemeService.hasLayout(_tokens, layoutId))
            ? layoutId : ""

    // The id the strip should highlight. An empty layoutId highlights
    // whichever design the theme flags default, so the selection always
    // points at the cell that will actually render.
    readonly property string _selectedId: {
        if (_missingId.length > 0) return _missingId
        if (layoutId.length > 0)   return layoutId
        for (let i = 0; i < _layouts.length; i++) {
            if (_layouts[i]["default"]) return _layouts[i].id
        }
        return _layouts.length > 0 ? _layouts[0].id : ""
    }

    // Real designs, plus a trailing placeholder cell for a missing one.
    readonly property var _cells: {
        let out = []
        for (let i = 0; i < _layouts.length; i++) {
            out.push({ id: _layouts[i].id, name: _layouts[i].name, missing: false })
        }
        if (_missingId.length > 0)
            out.push({ id: _missingId,
                       name: ThemeService.defaultLayoutName(_missingId),
                       missing: true })
        return out
    }

    ListView {
        id: list
        anchors.fill: parent
        orientation: ListView.Horizontal
        // Bind to length, not to the array: reassigning the model rebuilds
        // every delegate, and a strip that rebuilds on each keystroke loses
        // its scroll position while the operator is typing beside it.
        model: root._cells.length
        spacing: Theme.space.sm
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.horizontal: AppScrollBar { }

        delegate: Item {
            id: cell
            width: 128
            height: list.height

            readonly property var  _cell:   root._cells[index] || ({})
            readonly property bool _isSel:  _cell.id === root._selectedId

            Rectangle {
                anchors.fill: parent
                anchors.bottomMargin: 18       // room for the caption below
                color: Theme.color.canvas
                border.width: cell._isSel ? 2 : 1
                border.color: cell._cell.missing ? Theme.color.warning
                            : cell._isSel        ? Theme.color.brand
                            : cellMa.containsMouse ? Theme.color.borderStrong
                                                   : Theme.color.borderSubtle
                clip: true

                // A missing design has nothing to draw, so the cell says so
                // instead of rendering the fallback and implying the slide
                // still has its own look.
                ThemePreview {
                    anchors.fill: parent
                    anchors.margins: 2
                    visible: !cell._cell.missing
                    theme: root.theme
                    layoutId: cell._cell.id
                    // Thumbnails never animate: a strip of seven live mesh
                    // gradients is real frame budget spent on a picker.
                    autoPlayVideos: false
                }

                Text {
                    anchors.centerIn: parent
                    visible: cell._cell.missing
                    width: parent.width - Theme.space.md
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    text: qsTr("Not in this theme")
                    color: Theme.color.textTertiary
                    font.family: Theme.font.family
                    font.pixelSize: Theme.font.smallSize
                }
            }

            Text {
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                maximumLineCount: 1
                text: cell._cell.name || ""
                color: cell._isSel ? Theme.color.textPrimary : Theme.color.textTertiary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.smallSize
                font.weight: cell._isSel ? Theme.font.weightSemiBold
                                         : Theme.font.weightRegular
            }

            MouseArea {
                id: cellMa
                anchors.fill: parent
                hoverEnabled: true
                enabled: root.enabled && !cell._cell.missing
                cursorShape: Qt.PointingHandCursor
                onClicked: root.layoutPicked(cell._cell.id)
            }
        }
    }
}
