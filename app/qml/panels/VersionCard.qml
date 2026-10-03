import QtQuick

// One Bible-version card in the scripture sidebar's version grid.
//
// Translations are selected one at a time and their codes are short
// ("KJV", "NASB2020"), so the scripture tab shows them as a compact card
// grid instead of the full-width LibraryRow every other library tab uses
// — that fits several versions per row where the rows showed one.
//
// Presentation only: click and double-click are surfaced as signals and
// wired by LibrarySidebar's `scripture` branch (single click selects the
// version; double-click also pushes the focused verse Live in it). This
// mirrors how LibraryRow stays presentational and lets the sidebar own
// the AppState calls.
//
// Reordering is the same split. The card reports a drag (in scene
// coordinates) and a right-click, and the sidebar works out where the card
// lands and saves the order. `dropSide` is set back by the sidebar to draw
// the insertion bar on the card being dropped onto.
Item {
    id: root

    // Translation code, e.g. "KJV" — the visible label, and what the
    // sidebar's double-click handler passes to requestPushLiveInTranslation.
    property string label: ""
    // True when this is the currently selected translation.
    property bool   active: false
    // -1: insertion bar on the left edge, 1: on the right, 0: none.
    property int    dropSide: 0
    readonly property bool dragging: ma.dragging

    signal clicked()
    signal doubleClicked()
    signal contextMenuRequested(real x, real y)
    signal dragMoved(real sceneX, real sceneY)
    signal dragEnded(real sceneX, real sceneY)

    opacity: dragging ? 0.4 : 1.0

    // Intrinsic size — the grid sets an explicit width (cell width) and
    // height, so these are just sane fallbacks.
    implicitWidth: 80
    implicitHeight: Theme.d(36)

    Rectangle {
        id: surface
        anchors.fill: parent
        // Square corners — the app's dense surfaces (verse rows, version
        // badges, sidebar rows) are all sharp-cornered; a rounded card
        // read as foreign chrome.
        radius: 0

        // Walk the app's surface depth ladder rather than sitting on the
        // bright `raised` chip color used before:
        //   rest   — `elevated`, the standard panel surface, one subtle
        //            step above the `bgSidebar` behind the grid
        //   hover  — `raised`, a clear step up
        //   active — the app-wide selected wash `brandSubtle`
        color: root.active      ? Theme.color.brandSubtle
             : ma.containsMouse ? Theme.color.raised
                                : Theme.color.elevated
        // The border shows only on the active card (brand cyan) — matches
        // the app's "border == focus/selection" usage. Rest and hover
        // borders are painted the fill color, so they read as no border.
        border.width: 1
        border.color: root.active      ? Theme.color.brand
                    : ma.containsMouse ? Theme.color.raised
                                       : Theme.color.elevated

        Behavior on color        { ColorAnimation { duration: Theme.motion.instant } }
        Behavior on border.color { ColorAnimation { duration: Theme.motion.instant } }

        Text {
            anchors.fill: parent
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
            text: root.label
            // Active uses `brandHover` — the bright mark cyan — not `brand`
            // (the deep cyan), which would be cyan-on-cyan against the
            // `brandSubtle` wash and fail contrast.
            color: root.active      ? Theme.color.brandHover
                 : ma.containsMouse ? Theme.color.textPrimary
                                    : Theme.color.textSecondary
            font.family: Theme.font.family
            // smallSize, like every Theme.font.* token, scales with the
            // Appearance > Font size setting (Theme.uiScale, which is bound
            // to SettingsService.fontScale). One tier below bodySize to
            // suit the compact card.
            font.pixelSize: Theme.font.smallSize
            font.weight: Theme.font.weightMedium
            font.capitalization: Font.AllUppercase

            Behavior on color { ColorAnimation { duration: Theme.motion.instant } }
        }
    }

    // Where the dragged card will land, drawn on the card it is over.
    Rectangle {
        visible: root.dropSide !== 0
        width: 2
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.left: root.dropSide < 0 ? parent.left : undefined
        anchors.right: root.dropSide > 0 ? parent.right : undefined
        anchors.leftMargin: -Theme.space.xs / 2 - 1
        anchors.rightMargin: -Theme.space.xs / 2 - 1
        color: Theme.color.brandHover
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor
        // Keep the drag when the pointer leaves the card or the sidebar's
        // ScrollView would like to flick.
        preventStealing: true

        property bool  dragging: false
        property point _press: Qt.point(0, 0)

        onPressed: function(mouse) {
            _press = Qt.point(mouse.x, mouse.y)
            dragging = false
            if (mouse.button === Qt.RightButton)
                root.contextMenuRequested(mouse.x, mouse.y)
        }
        onPositionChanged: function(mouse) {
            if (!(pressedButtons & Qt.LeftButton)) return
            if (!dragging
                && Math.abs(mouse.x - _press.x) + Math.abs(mouse.y - _press.y) > 8)
                dragging = true
            if (dragging) {
                const p = mapToItem(null, mouse.x, mouse.y)
                root.dragMoved(p.x, p.y)
            }
        }
        onReleased: function(mouse) {
            if (!dragging) return
            const p = mapToItem(null, mouse.x, mouse.y)
            dragging = false
            root.dragEnded(p.x, p.y)
            // A drag is not a click: swallow the click that follows.
            _press = Qt.point(-1e6, -1e6)
        }
        onCanceled: {
            if (!dragging) return
            dragging = false
            root.dragEnded(-1, -1)
        }
        onClicked: function(mouse) {
            if (mouse.button !== Qt.LeftButton || _press.x < -1e5) return
            root.clicked()
        }
        onDoubleClicked: function(mouse) {
            if (mouse.button === Qt.LeftButton) root.doubleClicked()
        }
    }
}
