import QtQuick
import Crater

// Collapsible section in the properties panel. Click the header to toggle.
// Default `expanded: true` so the operator sees content right away; sections
// remember their state during the editor session via the QML object holding
// state. Body content is `default property` to keep call sites tidy:
//
//   AccordionSection {
//       title: "Transform"
//       Column { ... }
//   }
Item {
    id: section
    property string title: ""
    property bool   expanded: true
    default property alias content: bodyHost.data

    implicitWidth: parent ? parent.width : 320
    implicitHeight: header.height + (expanded ? bodyHost.implicitHeight + 8 : 0)

    // Header
    Rectangle {
        id: header
        height: 32
        anchors.left: parent.left
        anchors.right: parent.right
        color: hdrMa.containsMouse ? Theme.color.overlay : "transparent"

        Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

        AppIcon {
            id: caret
            name: section.expanded ? "chevron-down" : "chevron-right"
            color: Theme.color.textSecondary
            size: 12
            anchors.left: parent.left
            anchors.leftMargin: Theme.space.md
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            anchors.left: caret.right
            anchors.leftMargin: Theme.space.sm
            anchors.verticalCenter: parent.verticalCenter
            text: section.title.toUpperCase()
            color: Theme.color.textSecondary
            font.family: Theme.font.family
            font.pixelSize: Theme.font.microSize
            font.weight: Theme.font.weightSemiBold
            font.letterSpacing: 1.2
        }

        MouseArea {
            id: hdrMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: section.expanded = !section.expanded
        }
    }

    // Body — a plain Item won't size itself to its children, so we bind
    // implicitHeight to childrenRect.height. That makes the section's own
    // implicitHeight propagate correctly into the parent Column; without
    // it, sections collapse to header-height and their bodies overlap the
    // sibling below.
    Item {
        id: bodyHost
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: 4
        visible: section.expanded
        implicitHeight: childrenRect.height
    }
}
