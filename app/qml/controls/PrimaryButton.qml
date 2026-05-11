import QtQuick

// Filled accent button. Variants:
//   "brand"       — gold (default, e.g. "Add your first song")
//   "live"        — green (e.g. "Go Live")
//   "destructive" — red  (e.g. confirm-delete in dialogs)
Rectangle {
    id: root

    property string variant: "brand"
    property string iconName: ""
    property string text: ""

    // `enabled` is inherited from Item — setting it false on the caller side
    // propagates to the MouseArea (no click) and we use it for visual styling.

    signal clicked()

    // Variant palette — chosen so the same control composes for all 3 use cases
    // without consumers needing to know about Theme.color keys.
    readonly property color _base:
        variant === "live"        ? Theme.color.goLive
      : variant === "destructive" ? Theme.color.live
                                  : Theme.color.brand
    readonly property color _hover:
        variant === "live"        ? Theme.color.goLiveHover
      : variant === "destructive" ? Qt.lighter(Theme.color.live, 1.12)
                                  : Theme.color.brandHover
    readonly property color _pressed:
        variant === "live"        ? Theme.color.goLivePressed
      : variant === "destructive" ? Qt.darker(Theme.color.live, 1.12)
                                  : Theme.color.brandPressed
    readonly property color _ink:
        variant === "live"        ? Theme.color.goLiveInk
      : variant === "destructive" ? "#ffffff"
                                  : Theme.color.brandInk

    implicitHeight: 36
    implicitWidth: contentRow.implicitWidth + Theme.space.xl * 2

    radius: Theme.radius.md
    color: !root.enabled    ? Qt.darker(_base, 1.6)
         : ma.pressed       ? _pressed
         : ma.containsMouse ? _hover
                            : _base
    opacity: root.enabled ? 1.0 : 0.55

    Behavior on color   { ColorAnimation  { duration: Theme.motion.instant } }
    Behavior on opacity { NumberAnimation { duration: Theme.motion.instant } }

    Row {
        id: contentRow
        anchors.centerIn: parent
        spacing: Theme.space.sm

        AppIcon {
            visible: root.iconName.length > 0
            anchors.verticalCenter: parent.verticalCenter
            name: root.iconName
            color: root._ink
            size: 13
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.text
            color: root._ink
            font.family: Theme.font.family
            font.pixelSize: Theme.font.bodySize
            font.weight: Theme.font.weightSemiBold
            font.letterSpacing: 0.3
        }
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: root.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: root.clicked()
    }
}
