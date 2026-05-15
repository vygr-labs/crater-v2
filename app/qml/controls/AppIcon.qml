import QtQuick

// Icon glyph from the bundled Lucide font.
// Usage: AppIcon { name: "settings"; size: Theme.icon.lg; color: Theme.color.textSecondary }
//
// The font is registered as family "lucide" in main.cpp via
// QFontDatabase::addApplicationFont(":/fonts/lucide.ttf").
Item {
    id: root

    property string name: ""
    property color  color: Theme.color.textSecondary
    property real   size: Theme.icon.lg

    implicitWidth: size
    implicitHeight: size

    Text {
        anchors.centerIn: parent
        text: LucideIcons.get(root.name)
        color: root.color
        font.family: LucideIcons.fontFamily
        font.pixelSize: root.size
        // NativeRendering is sharper for icon fonts at small sizes on Windows.
        renderType: Text.NativeRendering
        antialiasing: true
    }
}
