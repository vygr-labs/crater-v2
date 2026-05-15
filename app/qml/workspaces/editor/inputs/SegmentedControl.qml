import QtQuick
import Crater

// Single-select button group. Each option = { value: ..., label?, iconName? }.
//   SegmentedControl {
//       options: [{ value: "left",   iconName: "align-left"   },
//                 { value: "center", iconName: "align-center" },
//                 { value: "right",  iconName: "align-right"  }]
//       current: node.style.textAlign
//       onChanged: workspace.setNodeStyle(...)
//   }
Item {
    id: root
    property var options: []          // [{ value, label?, iconName? }]
    property var current: undefined

    signal changed(var v)

    implicitWidth: parent ? parent.width : 200
    implicitHeight: 28

    Rectangle {
        anchors.fill: parent
        radius: Theme.radius.sm
        color: Theme.color.canvas
        border.color: Theme.color.borderStrong
        border.width: 1

        Row {
            anchors.fill: parent
            anchors.margins: 1

            Repeater {
                model: root.options
                delegate: Rectangle {
                    width: parent.width / Math.max(1, root.options.length) - 1
                    height: parent.height
                    radius: Theme.radius.sm - 1
                    color: root.current === modelData.value ? Theme.color.brandSubtle
                         : btnMa.containsMouse              ? Theme.color.overlay
                                                             : "transparent"
                    border.color: root.current === modelData.value ? Theme.color.brand : "transparent"
                    border.width: 1

                    Behavior on color { ColorAnimation { duration: Theme.motion.instant } }

                    Row {
                        anchors.centerIn: parent
                        spacing: 4
                        AppIcon {
                            visible: !!modelData.iconName
                            name: modelData.iconName || ""
                            color: root.current === modelData.value ? Theme.color.brand : Theme.color.textSecondary
                            size: Theme.icon.sm
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                            visible: !!modelData.label
                            text: modelData.label || ""
                            color: root.current === modelData.value ? Theme.color.textPrimary : Theme.color.textSecondary
                            font.family: Theme.font.family
                            font.pixelSize: Theme.font.smallSize
                            font.weight: Theme.font.weightMedium
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    MouseArea {
                        id: btnMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.changed(modelData.value)
                    }
                }
            }
        }
    }
}
