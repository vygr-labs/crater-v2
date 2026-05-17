import QtQuick

// Base modal frame — backdrop, centered card, optional title bar with close X.
// All dialog files compose ModalShell + their own content inside.
//
// Open/close lifecycle is owned by AppState + ModalLayer's Loader. ModalShell
// only handles the *visual* of being open: fade-in on instantiation, and
// translating backdrop / X clicks into AppState.closeModal() calls.
Item {
    id: root

    // Visual sizing
    property int    dialogWidth:  500
    property int    dialogHeight: 360

    // Chrome
    property string title: ""
    property bool   showHeader: true
    property bool   showCloseButton: true
    property bool   dimBackdrop: true

    // Default slot — children of <ModalShell> end up inside contentArea.
    default property alias contentChildren: contentArea.data

    anchors.fill: parent

    // Subtle fade-in on first show. The closing fade is deferred until we
    // have a way to delay AppState.closeModal — for now exit is instant,
    // which matches the keyboard-driven flow.
    opacity: 0
    Component.onCompleted: opacity = 1
    Behavior on opacity {
        NumberAnimation { duration: Theme.motion.normal; easing.type: Easing.OutCubic }
    }

    // Backdrop — dim + click-outside-to-close
    Rectangle {
        anchors.fill: parent
        color: root.dimBackdrop ? "#000000" : "transparent"
        opacity: root.dimBackdrop ? 0.45 : 0.0

        MouseArea {
            anchors.fill: parent
            onClicked: AppState.closeModal()
        }
    }

    // Card
    Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.min(root.dialogWidth, root.width - 48)
        height: Math.min(root.dialogHeight, root.height - 48)
        radius: Theme.radius.lg
        color: Theme.color.elevated
        border.color: Theme.color.borderStrong
        border.width: 1
        antialiasing: true

        // Absorb every input event that lands on a "blank" region of the
        // card — header padding, gaps between rows, preview-pane background,
        // etc. Without this, those events propagate down to the backdrop's
        // MouseArea (which calls closeModal) and onward through the modal
        // entirely to items in the operator console behind.
        //
        // CRUCIAL: `acceptedButtons: Qt.NoButton` does NOT block events —
        // it explicitly rejects them, telling Qt to walk down the z-order to
        // the next receiver. Accepting all buttons + handling onWheel with
        // an empty `accepted = true` is what actually absorbs the events.
        // Hover is enabled so the cursor doesn't ghost-react to controls
        // we're visually obscuring.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            hoverEnabled: true
            onPressed:       function(m) { m.accepted = true }
            onClicked:       function(m) { m.accepted = true }
            onDoubleClicked: function(m) { m.accepted = true }
            onWheel:         function(w) { w.accepted = true }
        }

        // ── Title bar ───────────────────────────────────────────────────
        Item {
            id: header
            visible: root.showHeader
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: 48

            Text {
                anchors.left: parent.left
                anchors.leftMargin: Theme.space.lg
                anchors.verticalCenter: parent.verticalCenter
                text: root.title
                color: Theme.color.textPrimary
                font.family: Theme.font.family
                font.pixelSize: Theme.font.bodySize + 3
                font.weight: Theme.font.weightSemiBold
            }

            IconButton {
                visible: root.showCloseButton
                anchors.right: parent.right
                anchors.rightMargin: Theme.space.md
                anchors.verticalCenter: parent.verticalCenter
                iconName: "x"
                iconSize: Theme.icon.md
                onClicked: AppState.closeModal()
            }

            Rectangle {
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                height: 1
                color: Theme.color.borderSubtle
            }
        }

        // ── Content slot ────────────────────────────────────────────────
        Item {
            id: contentArea
            anchors.top: root.showHeader ? header.bottom : parent.top
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            clip: true
        }
    }
}
