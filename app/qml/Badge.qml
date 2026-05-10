import QtQuick

Rectangle {
    id: root

    property string text: ""
    property color background: Theme.color.overlay
    property color foreground: Theme.color.textSecondary
    property bool pulse: false

    implicitHeight: 20
    implicitWidth: label.implicitWidth + Theme.space.md * 2
    radius: Theme.radius.pill
    color: root.background
    border.width: 0
    antialiasing: true

    SequentialAnimation on opacity {
        running: root.pulse
        loops: Animation.Infinite
        NumberAnimation { from: 1.0; to: 0.55; duration: 800; easing.type: Easing.InOutQuad }
        NumberAnimation { from: 0.55; to: 1.0; duration: 800; easing.type: Easing.InOutQuad }
    }

    Text {
        id: label
        anchors.centerIn: parent
        text: root.text.toUpperCase()
        color: root.foreground
        font.family: Theme.font.family
        font.pixelSize: Theme.font.microSize
        font.weight: Theme.font.weightSemiBold
        font.letterSpacing: 0.8
    }
}
