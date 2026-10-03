import QtQuick

// Base modal frame — backdrop, centered card, optional title bar with close X.
// All dialog files compose ModalShell + their own content inside.
//
// Open/close lifecycle is owned by AppState + ModalLayer's Loader. ModalShell
// only handles the *visual* of being open: fade-in on instantiation, and
// translating backdrop / X clicks into AppState.requestCloseModal() calls,
// which let a dialog with unsaved edits object.
//
// Every dialog registers itself as AppState.modalCloseOwner on creation. A
// dialog opts into the shared close gestures by defining, on its root:
//   function requestClose()  ask before unsaved edits are dropped
//   function requestSave()   run its Save button's own save (with its
//                            validation) for the Ctrl+Enter double tap
// Neither is required. See AppState's "Double-tap dialog gestures".
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

    // Open/close animation control. `show` is normally true; a driver (e.g.
    // ModalLayer, for the command palette) can bind it to the "should be open"
    // state and wait for closed() before tearing the Loader down, so the exit
    // animation gets to play. Modals that don't drive `show` simply animate in
    // on creation and are destroyed instantly on close, exactly as before —
    // `show` stays true for their whole (short) life.
    property bool show: true
    signal closed()

    // Default slot — children of <ModalShell> end up inside contentArea.
    default property alias contentChildren: contentArea.data

    anchors.fill: parent

    // Drives the scale + fade. Starts hidden/down, is raised on completion
    // (entry) and lowered when `show` clears (exit). A close-timer fires
    // closed() once the exit animation has run its Theme.motion.normal course
    // — this is the "way to delay AppState.closeModal" the old note wanted.
    property bool _shown: false
    Component.onCompleted: {
        _shown = true
        AppState.modalCloseOwner = root
    }
    onShowChanged: {
        _shown = show
        if (!show) closeTimer.restart()
        else       closeTimer.stop()
    }
    Timer {
        id: closeTimer
        interval: Theme.motion.normal
        onTriggered: if (!root.show) root.closed()
    }

    // Backdrop — dim + click-outside-to-close
    Rectangle {
        anchors.fill: parent
        color: root.dimBackdrop ? "#000000" : "transparent"
        opacity: root._shown ? (root.dimBackdrop ? 0.45 : 0.0) : 0.0
        Behavior on opacity {
            NumberAnimation { duration: Theme.motion.normal; easing.type: Easing.OutCubic }
        }

        MouseArea {
            anchors.fill: parent
            onClicked: AppState.requestCloseModal()
        }
    }

    // Room the docked live controls panel needs on the right (see
    // AppState.liveDockReservedWidth / LiveControlsDock.qml). The card
    // centres in what is left, so the panel sits beside the dialog rather
    // than on it. The reservation is dropped when honouring it would shrink
    // the card below 80% of its design width (never asking for less than
    // 640px): a cramped editor is worse than a panel the operator can fold
    // to a thin tab or drag aside.
    readonly property int _dockReserve: {
        const want = AppState.liveDockReservedWidth
        if (want <= 0) return 0
        const minCard = Math.min(root.dialogWidth, Math.max(640, root.dialogWidth * 0.8))
        return (root.width - want - 48 >= minCard) ? want : 0
    }

    // Eased copy of the reservation, so folding or docking the panel glides
    // the card over while a window resize still tracks instantly.
    property real _dockReserveEased: _dockReserve
    Behavior on _dockReserveEased {
        NumberAnimation { duration: Theme.motion.normal; easing.type: Easing.OutCubic }
    }

    Item {
        id: cardArea
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        width: root.width - root._dockReserveEased
    }

    // Card
    Rectangle {
        id: card
        anchors.centerIn: cardArea
        width: Math.min(root.dialogWidth, cardArea.width - 48)
        height: Math.min(root.dialogHeight, root.height - 48)
        // Squared corners — the modal frame intentionally drops Theme.radius.lg
        // so its chrome reads as a flat, data-dense surface rather than a
        // friendly card. All dialogs inherit this look.
        radius: 0
        color: Theme.color.elevated
        border.color: Theme.color.borderStrong
        border.width: 1
        antialiasing: true

        // Rise-and-settle: fades in while scaling 0.96 -> 1.0 so the modal
        // reads as "coming forward" rather than blinking into place, and
        // reverses on close. transformOrigin Center keeps it pinned under
        // anchors.centerIn while it scales.
        transformOrigin: Item.Center
        opacity: root._shown ? 1.0 : 0.0
        scale:   root._shown ? 1.0 : 0.96
        Behavior on opacity {
            NumberAnimation { duration: Theme.motion.normal; easing.type: Easing.OutCubic }
        }
        Behavior on scale {
            NumberAnimation { duration: Theme.motion.normal; easing.type: Easing.OutCubic }
        }

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
            height: Theme.d(48)

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
                onClicked: AppState.requestCloseModal()
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
