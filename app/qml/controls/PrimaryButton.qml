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

    // Opt-in override for the label/icon colour. Defaults to the variant's
    // ink, so existing call sites are unaffected; consumers that need a
    // specific contrast (e.g. white on the teal brand fill) can set it.
    property color inkColor: _ink

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
    // Brand-variant ink auto-adapts to the *resolved* fill luminance: the
    // deep teal `brand` rest fill (and the light theme's deeper hover/press)
    // take a white ink, while the dark theme's bright `brandHover` fill on
    // hover keeps the dark `brandInk` — the polarity `brandInk` is designed
    // for elsewhere. Reading `root.color` tracks the animated fill, so
    // contrast holds through the hover transition too. Previously the deep
    // `brand` fill always got dark `brandInk` (~2.8:1 — the "dark text on
    // dark cyan" the light-mode buttons showed); white on it is ~5.3:1.
    readonly property color _ink:
        variant === "live"        ? Theme.color.goLiveInk
      : variant === "destructive" ? "#ffffff"
      : (root.color.hslLightness > 0.45 ? Theme.color.brandInk : "#ffffff")

    implicitHeight: 36
    implicitWidth: contentRow.implicitWidth + Theme.space.xl * 2

    // Squared by design — matches the rest of the dialog/console chrome.
    // Was Theme.radius.md (6) when the design leaned softer; we've shifted
    // toward flat, architectural button shapes app-wide.
    radius: 0
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
            color: root.inkColor
            size: Theme.icon.sm
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.text
            color: root.inkColor
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
